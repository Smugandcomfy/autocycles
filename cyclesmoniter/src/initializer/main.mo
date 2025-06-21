import Time      "mo:base/Time";
import Timer     "mo:base/Timer";
import Principal "mo:base/Principal";
import Blob      "mo:base/Blob";
import Result    "mo:base/Result";
import Array     "mo:base/Array";
import Error     "mo:base/Error";

////////////////////////////////////////////////////////////////
//  ░░ 1.  INSTALL-TIME CONFIG  ░░
////////////////////////////////////////////////////////////////

// Compile-time constant: SNS Governance canister that owns the neuron
let GOVERNANCE : Principal =
  Principal.fromText("fi3zi-fyaaa-aaaaq-aachq-cai");

// Record passed to `dfx deploy --argument '(record { … })'`
type InitArgs = record {
  monitor_account_hex : Text;   // 64-hex chars (account-identifier)
  dest_principal      : Principal;
  dest_sub_hex        : Text;   // 64-hex chars (subaccount)
  threshold_e8s       : Nat64;  // default 2_500_000_000
  topup_e8s           : Nat64;  // default 10_000_000_000
  period_sec          : Nat;    // default 1_209_600 (14 d)
};

////////////////////////////////////////////////////////////////
//  ░░ 2.  STABLE STATE  ░░
////////////////////////////////////////////////////////////////

stable var monitorAccount : Blob = Blob.fromArray([]);
stable var destPrincipal  : Principal = Principal.fromText("aaaaa-aa");
stable var destSub        : Blob = Blob.fromArray([]);
stable var thresholdE8s   : Nat64 = 0;
stable var topupE8s       : Nat64 = 0;
stable var periodSec      : Nat   = 0;

stable var neuronSub      : ?Blob  = null;
stable var lastBalE8s     : ?Nat64 = null;
stable var nextCheckTime  : Nat64  = 0;                 // UTC ns
stable var lastProposalId : ?Nat64 = null;              // guard

////////////////////////////////////////////////////////////////
//  ░░ 3.  LEDGER INTERFACES  ░░
////////////////////////////////////////////////////////////////

module LedgerIcrc1 {
  public type Account = { owner : Principal; subaccount : ?[Nat8] };
  public actor class Self() = this {
    public query func icrc1_balance_of(Account) : async Nat;
  };
}
module LedgerLegacy {
  public actor class Self() = this {
    public query func account_balance(record { account : Blob })
      : async record { e8s : Nat64 };
  };
}

let LEDGER : Principal =
  Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

let ledgerIcrc : LedgerIcrc1.Self   = actor (Principal.toText(LEDGER));
let ledgerLeg  : LedgerLegacy.Self  = actor (Principal.toText(LEDGER));

////////////////////////////////////////////////////////////////
//  ░░ 4.  SNS GOVERNANCE TYPES  ░░
////////////////////////////////////////////////////////////////

type TransferSnsTreasuryFunds = record {
  from_treasury : Int32;               // 1 = ICP Treasury
  to_principal  : ?Principal;
  to_subaccount : ?record { subaccount : Blob };
  memo          : ?Nat64;
  amount_e8s    : Nat64;
};
type Action   = variant { TransferSnsTreasuryFunds : TransferSnsTreasuryFunds };
type Proposal = record { title : Text; url : Text; summary : Text; action : ?Action };
type Command  = variant { MakeProposal : Proposal };

type ManageNeuronResponse = record { id : Nat64 };

type ManageNeuron = record { subaccount : Blob; command : ?Command };

type ListNeurons = record {
  of_principal  : ?Principal;
  limit         : Nat32;
  start_page_at : ?record { id : Blob };
};
type NeuronId = record { id : Blob };
type Neuron   = record { id : ?NeuronId };
type ListNeuronsResponse = record { neurons : [Neuron] };

actor class Governance = actor {
  public query func list_neurons(ListNeurons) : async ListNeuronsResponse;
  public shared func manage_neuron(ManageNeuron) : async ManageNeuronResponse;
};

////////////////////////////////////////////////////////////////
//  ░░ 5.  UTILITIES  ░░
////////////////////////////////////////////////////////////////

/// naive hex-string → Blob decoder (expects even length)
func hexToBlob(txt : Text) : Blob {
  let bytes : [Nat8] = Array.tabulate<Nat8>(
    txt.size() / 2,
    func(i : Nat) : Nat8 {
      let pair = txt.substr(2*i, 2);
      switch (Nat8.fromText("0x" # pair)) {
        case (?b) b;
        case null { 0 };
      }
    }
  );
  Blob.fromArray(bytes);
}

/// 8-decimal ICP formatter (always “n.dddddddd”)
func fmtIcp(e8s : Nat64) : Text {
  let whole : Nat64 = e8s / 100_000_000;
  let frac  : Nat64 = e8s % 100_000_000 + 100_000_000;
  Nat64.toText(whole) # "." # Nat64.toText(frac)[1:];   // skip leading ‘1’
}

////////////////////////////////////////////////////////////////
//  ░░ 6.  INSTALL / UPGRADE HOOKS  ░░
////////////////////////////////////////////////////////////////

system func init(args : InitArgs) {
  monitorAccount := hexToBlob(args.monitor_account_hex);
  destPrincipal  := args.dest_principal;
  destSub        := hexToBlob(args.dest_sub_hex);
  thresholdE8s   := args.threshold_e8s;
  topupE8s       := args.topup_e8s;
  periodSec      := args.period_sec;

  if (nextCheckTime == 0) {                 // first install
    nextCheckTime := Time.toNat64(Time.now())
                     + Nat64.fromNat(periodSec) * 1_000_000_000;
  };
  schedule();
}

system func postupgrade() {                 // keep timers aligned
  schedule();
}

////////////////////////////////////////////////////////////////
//  ░░ 7.  PUBLIC API (unchanged Candid)  ░░
////////////////////////////////////////////////////////////////

public query func last_balance_e8s() : async ?Nat64 { lastBalE8s };

public query func next_check_utc_ns() : async Nat64 { nextCheckTime };

public shared func run_topup() : async Result.Result<(), Text> {
  if (caller != GOVERNANCE and caller != Principal.fromActor(this))
    return #err("unauthorised");
  await maybeTopUp(true)
};

public shared func refresh_neuron() : async ?Blob {
  if (caller != GOVERNANCE and caller != Principal.fromActor(this))
    return null;
  neuronSub := null;
  await getNeuronSub();
};

////////////////////////////////////////////////////////////////
//  ░░ 8.  TIMER  ░░
////////////////////////////////////////////////////////////////

private func schedule() {
  let now = Time.now();
  let delta =
    if (now >= nextCheckTime)
       0
    else nextCheckTime - now;               // ns
  ignore Timer.setTimer(#nanoseconds delta, check);
};

private func check() : async () {
  ignore await maybeTopUp(false);
  // advance exactly periodSec
  nextCheckTime += Nat64.fromNat(periodSec) * 1_000_000_000;
  schedule();
};

////////////////////////////////////////////////////////////////
//  ░░ 9.  CORE LOGIC  ░░
////////////////////////////////////////////////////////////////

private func maybeTopUp(forced : Bool) : async Result.Result<(), Text> {

  // 1️⃣  Get balance (icrc1 preferred)
  var balE8s : ?Nat64 = null;
  try {
    balE8s := ?Nat64.fromNat(
      await ledgerIcrc.icrc1_balance_of({
        owner      = destPrincipal;          // owner is irrelevant; we only
        subaccount = ?Blob.toArray(destSub); // need a well-formed struct
      }));
  } catch _ {}

  if (balE8s == null) {                      // fallback
    try {
      let resp = await ledgerLeg.account_balance({ account = monitorAccount });
      balE8s := ?resp.e8s;
    } catch (err) {
      Debug.print("ledger error: " # Error.message(err));
      // single retry after 10 s
      ignore Timer.setTimer(#seconds 10,
        func () : async () { await maybeTopUp(forced) });
      return #err("ledger_error");
    }
  };

  let bal : Nat64 = switch balE8s { case (?b) b; case null 0 };
  lastBalE8s := ?bal;

  // 2️⃣  Decide / avoid duplicates
  if (not forced and bal >= thresholdE8s) return #ok(());

  if (lastProposalId != null) return #err("proposal already pending");

  // 3️⃣  Ensure neuron subaccount
  let ?sub = await getNeuronSub()
    else return #err("no hot-key neuron");

  // 4️⃣  Build payload & proposal
  let payload : TransferSnsTreasuryFunds = {
    from_treasury = 1;                       // ICP Treasury
    to_principal  = ?destPrincipal;
    to_subaccount = ?{ subaccount = destSub };
    memo          = null;
    amount_e8s    = topupE8s;
  };

  let summary =
    "**Automated ICP top-up**  \n"
    "# Trigger time:** `" # Int.toText(Time.now()) # "`  \n"
    "* Balance:** " # fmtIcp(bal) # " ICP (" # Nat64.toText(bal) # " e8s)  \n"
    "* Threshold:** " # fmtIcp(thresholdE8s) # " ICP  \n"
    "* Action:** Transfer **" # fmtIcp(topupE8s)
      # " ICP** from ICP Treasury to `" # Principal.toText(destPrincipal) # "`";

  let prop : Proposal = {
    title   = "Automated ICP top-up";
    url     = "";
    summary = summary;
    action  = ?#TransferSnsTreasuryFunds(payload);
  };

  let gov : Governance = actor (Principal.toText(GOVERNANCE));
  let resp = await gov.manage_neuron({ subaccount = sub; command = ?#MakeProposal(prop) });
  lastProposalId := ?resp.id;

  #ok(())
};

////////////////////////////////////////////////////////////////
//  ░░ 10.  HOT-KEY NEURON DISCOVERY  ░░
////////////////////////////////////////////////////////////////

private func getNeuronSub() : async ?Blob {
  if (neuronSub != null) return neuronSub;
  let gov : Governance = actor (Principal.toText(GOVERNANCE));
  let resp = await gov.list_neurons({
    of_principal  = ?Principal.fromActor(this);
    limit         = 10;
    start_page_at = null
  });
  switch (resp.neurons) {
    case []           { null };
    case (n # _) {
      switch (n.id) { case null { null }; case (?nid) {
        neuronSub := ?nid.id; neuronSub
      }}
    }
  }
};
