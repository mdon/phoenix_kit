# PostgresPreflight — why it exists and how it works

`PhoenixKit.TestSupport.PostgresPreflight` is the shared connection check every
package's `test_helper.exs` runs before starting its repo. It ships in `lib/`
deliberately: the sibling packages depend on core through Hex, where a
`test/support` directory is unreachable (the precedent is
`Ecto.Adapters.SQL.Sandbox`). Never call it from application code.

It exists because a wrong `PGUSER` did not look like a wrong `PGUSER`. The
suites run through the SQL sandbox, so a rejected login was queued and retried
and surfaced minutes later as a **pool checkout timeout** that reads like a
flaky test — nine repos had documented that as a landmine. It replaced a
`psql -lqt` listing, which asked the wrong question entirely: that ran as the
shell's user over a unix socket and said nothing about whether the CONFIGURED
role could connect over TCP.

Two things about the implementation are load-bearing and easy to undo by
accident:

- It probes with **`Postgrex.Protocol.connect/1`**, not `Postgrex.start_link/1`.
  `start_link/1` returns `{:ok, pid}` even for a bad role, a missing database
  and a closed port — `sync_connect: true` does not change that — and the
  failure then happens inside the connection process. Verified against a live
  server. `Protocol.connect/1` is undocumented, so the call is guarded and any
  surprise degrades to "no opinion" rather than to a broken run.
- It **whitelists** connection keys off the repo config. Passing the config
  through would carry `pool: Ecto.Adapters.SQL.Sandbox` and rebuild the very
  pool whose timeout is being diagnosed.

`check/1` never raises (most suites degrade to unit-only); `check!/1` is for a
suite with no unit-only mode. It is a **connection** preflight, not a
"database ready" check — it says nothing about migrations, privileges or
sandbox ownership, and must not grow into a second copy of repo startup.
