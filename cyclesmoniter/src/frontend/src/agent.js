import { Actor, HttpAgent } from "@dfinity/agent";
import idlFactory from "../../../../.dfx/local/canisters/initializer/initializer.did.js";
import canisterIds from "../../../../../.dfx/local/canister_ids.json";

const canisterId =
  import.meta.env.VITE_INITIALIZER_CANISTER_ID ||
  (import.meta.env.MODE === "production"
    ? canisterIds.ic.initializer[0]
    : canisterIds.local.initializer[0]);

export async function getActor(identity) {
  const agent = new HttpAgent({ identity });
  if (import.meta.env.DEV) await agent.fetchRootKey(); // local replica
  return Actor.createActor(idlFactory, { agent, canisterId });
}
