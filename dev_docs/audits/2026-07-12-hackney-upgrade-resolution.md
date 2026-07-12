# hackney/httpoison upgrade — resolution

**Date:** 2026-07-12 · **Author:** Claude · **Trigger:** follow-up to
`2026-07-07-hackney-cve-2026-advisories-audit.md`, which accepted the hackney
1.25.0 CVE batch because the upgrade path was blocked. This doc records how
that block was cleared and what changed.

## Recap: why we were stuck

The 2026-07-07 audit found the chain:

```
ueberauth_apple 0.6.1 (latest, 2023) → httpoison "~> 1.0 or ~> 2.0"  (< 3.0.0)
httpoison 2.3.0                      → hackney  "~> 1.21"            (< 2.0.0)
```

with no fixed hackney 1.x available (fix only in 4.0.1+), and concluded
`override: true` "cannot help — httpoison 2.x calls hackney's 1.x API, which
changed in 4.x, so an override would break at runtime."

## What actually happened since

1. **`ueberauth_apple` was removed as a dependency**, along with Apple
   Sign-In as a feature (unmaintained since 2023, decided not worth blocking
   a security upgrade on — see the CHANGELOG entry for this release). This
   removes the `httpoison < 3.0` constraint entirely.
2. **`ex_aws` (core) had already relaxed its own hackney requirement** —
   2.7.0 (before our stale 2.6.1 lock) declares `{:hackney, "~> 4.0",
   optional: true}` and added `req` as an alternative HTTP client.
3. That left exactly one remaining stale pin: **`ex_aws_sqs`** (latest
   3.4.0, released January 2023) still declares `{:hackney, "~> 1.9",
   optional: true}`. Checked its source (`deps/ex_aws_sqs/lib/`) — **zero
   direct references to hackney**. The pin is vestigial, only listed for
   its own `:test` env (`extra_applications(:test) -> [:logger, :hackney]`).
   All real HTTP goes through `ex_aws` core, which already moved on.

With `ueberauth_apple` gone, the only thing left forcing hackney below 4.0
was `ex_aws_sqs`'s dead pin — safe to override.

## What was verified before overriding

- **hackney 4.0.0 release notes** state explicitly: "The user-facing
  `hackney:request/5` API is unchanged." The major bump is because HTTP/2
  and HTTP/3 were delegated to new libraries (`h2`, `quic`) and the built-in
  metrics subsystem (`hackney_metrics_*`) was replaced by a middleware
  chain — not a request-API break.
- Grepped every real hackney consumer in the tree for internal-module usage:
  - `ex_aws`'s hackney adapter (`ex_aws/lib/ex_aws/request/hackney.ex`)
    calls only `:hackney.request/5` — stable, unaffected.
  - `tesla`'s hackney adapter and `swoosh`'s hackney client — no
    internal-module calls; both already declare hackney-4.x-compatible
    ranges (`tesla`: `~> 1.21 or >= 4.0.2`; `swoosh`: `>= 1.9.0 and <
    5.0.0`).
  - `httpoison` 2.x was the one exception — it calls `:hackney_headers` and
    `:hackney_connection` internals that hackney 4.x removed (confirmed by
    actually overriding hackney alone first: `mix compile` produced real
    `undefined or private` warnings on those two calls). This is exactly
    why httpoison needed its own major bump — **`httpoison 3.0.0` requires
    `hackney ~> 4.0`** and is the safe pairing.

## What changed in `mix.exs`

```elixir
{:hackney, "~> 4.0", override: true},
{:httpoison, "~> 3.0", override: true},
```

Both `override: true` because `ex_aws_sqs` (hackney) and — historically,
before its removal — `ueberauth_apple` (httpoison) declared narrower ranges
that Hex's solver would otherwise honor.

## Verification

- `mix compile --warnings-as-errors --all-warnings` — zero warnings (the
  httpoison-internals warnings from testing hackney-alone are gone once
  httpoison is also on 3.0.0).
- `mix deps.audit` — **zero vulnerabilities** (down from 4, including the 1
  HIGH).
- Full `mix precommit` (format + credo --strict + dialyzer) — passes clean,
  same dialyzer baseline (185/185 skips) as before this change.
- `mix deps.unlock --check-unused` — clean after pruning `metrics` (hackney
  4.x's replaced metrics subsystem) and `unicode_util_compat` (dropped by
  idna 7.x) from the lockfile, plus `jose` (only needed by
  `ueberauth_apple`).

Version deltas: `hackney` 1.25.0 → 4.5.2, `httpoison` 2.3.0 → 3.0.0, `ex_aws`
2.6.1 → 2.7.0, `idna` 6.1.1 → 7.1.0, `certifi` 2.15.0 → 2.17.0. New
transitive deps: `h2`, `quic`, `webtransport` (hackney's now-split-out
HTTP/2/HTTP/3 stacks).

## Residual risk

- `ex_aws_sqs` is itself unmaintained (2023) — unrelated to this hackney
  question, but worth having on the radar for a future AWS API drift.
- Apple Sign-In is gone until a maintained fork replaces `ueberauth_apple`.
  See the CHANGELOG for the removal note and compatibility guarantees for
  already-linked accounts.
