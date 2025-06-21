# ICP Top-up Scheduler (SNS)

This canister watches an ICP‐ledger account and, whenever the balance falls
below a threshold, automatically submits a **`TransferSnsTreasuryFunds`**
proposal that moves a fixed amount of ICP from the SNS **ICP Treasury** to a
destination wallet.

* Polls once every *N* seconds (default **14 days**).  
* Submits a top-up proposal only when *balance < threshold*.  
* All parameters (wallets, amounts, cadence) are supplied **at install time**—
  no recompilation needed for tweaks.

---

## 1 Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| **DFX SDK** | 0.17+ | `dfx --version` |
| **Node JS** | 18 LTS or newer | builds the UI |
| **npm / pnpm** | any | README uses `npm` |

---
#Build the UI (only when text/CSS changes)

```bash
cd src/frontend
npm install          # first time only
npm run build        # outputs dist/ for the asset canister
cd ../..


# launch local replica & deploy
dfx start --background
dfx deploy

# initialize arguments
dfx deploy --network ic --argument '(
  record {
    monitor_account_hex = "a46e89a0d1be88d5e3b8a753914b6341a37be2360c7b8b23e00f55c798b248c0";
    dest_principal      = principal "v6hxe-jaaaa-aaaap-aawpq-cai";
    dest_sub_hex        = "ca7f35a3560a2705a4f0b4b6313d3652e87ca6febfe7e6ee5eac47016581e619";
    threshold_e8s       = 2_500_000_000;
    topup_e8s           = 10_000_000_000;
    period_sec          = 1_209_600;        # 14 days in seconds
  }
)'

#upgrade intall-time param
dfx canister install initializer \
     --mode upgrade \
     --argument '(
       record {
         monitor_account_hex = "a46e89a0d1be88d5e3b8a753914b6341a37be2360c7b8b23e00f55c798b248c0";
         dest_principal      = principal "v6hxe-jaaaa-aaaap-aawpq-cai";
         dest_sub_hex        = "ca7f35a3560a2705a4f0b4b6313d3652e87ca6febfe7e6ee5eac47016581e619";
         threshold_e8s       = 3_000_000_000;   # 30 ICP
         topup_e8s           = 10_000_000_000;
         period_sec          = 1_209_600;
       }
     )' \
     --network ic

#candid 1 time parameter update
record {
  monitor_account_hex : text;     // 64-hex ICP account-identifier
  dest_principal      : principal;
  dest_sub_hex        : text;     // 64-hex subaccount
  threshold_e8s       : nat64;    // e.g. 2_500_000_000  (25 ICP)
  topup_e8s           : nat64;    // e.g. 10_000_000_000 (100 ICP)
  period_sec          : nat;      // e.g. 1_209_600      (14 days)
}

