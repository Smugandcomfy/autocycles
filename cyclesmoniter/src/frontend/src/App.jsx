import React, { useEffect, useState } from "react";
import { getActor } from "./agent";

export default function App() {
  const [actor, setActor] = useState(null);
  const [bal, setBal] = useState(null);
  const [next, setNext] = useState(null);
  const [busy, setBusy] = useState(false);

  // bootstrap
  useEffect(() => {
    (async () => {
      const a = await getActor();
      setActor(a);
      refresh(a);
    })();
  }, []);

  async function refresh(a = actor) {
    if (!a) return;
    const [b, n] = await Promise.all([
      a.last_balance_e8s(),
      a.next_check_utc_ns()
    ]);
    setBal(b ?? null);
    setNext(new Date(Number(n) / 1e6));
  }

  async function runNow() {
    setBusy(true);
    try {
      const res = await actor.run_topup();
      if ("err" in res) alert("Error: " + res.err);
      else alert("Top-up proposal submitted ✅");
    } finally {
      await refresh();
      setBusy(false);
    }
  }

  const fmt = (e8s) =>
    e8s == null ? "…" : (Number(e8s) / 1e8).toLocaleString() + " ICP";

  return (
    <main>
      <h1>ICP Top-up Scheduler</h1>
      <p>
        <strong>Last recorded balance:</strong> {fmt(bal)}
      </p>
      <p>
        <strong>Next automatic check:</strong>{" "}
        {next ? next.toUTCString() : "…"}
      </p>
      <button onClick={runNow} disabled={!actor || busy}>
        {busy ? "Submitting…" : "Run check & top-up now"}
      </button>
    </main>
  );
}
