# PR #795 — V188 unique indexes, a shared test-helper DB preflight, and a docs cleanup

**Merge:** `c20aaf31` (merges `abc124cc` into `main`, author mdon, merged by fotkin)
**Files:** `AGENTS.md`, `guides/phk-publishing-format.md`, `lib/phoenix_kit/migrations/expected_schema.ex`,
`lib/phoenix_kit/migrations/postgres.ex`, `lib/phoenix_kit/migrations/postgres/v188.ex`,
`lib/phoenix_kit/test_support/postgres_preflight.ex`, `test/integration/postgres_preflight_test.exs`,
`test/integration/user_connections_uniqueness_test.exs`, `test/test_helper.exs`, two unrelated
`CLAUDE_REVIEW.md` files (personal-path redaction only).

## Summary

Three unrelated changes bundled in one PR:

1. **V188** — creates the three unique indexes (`phoenix_kit_user_follows_unique_idx`,
   `phoenix_kit_user_blocks_unique_idx`,
   `phoenix_kit_user_connections_requester_recipient_uidx`) that
   `phoenix_kit_user_connections`' schemas have always named in `unique_constraint/3` but which
   never existed, after de-duplicating any rows the race already produced.
2. **`PhoenixKit.TestSupport.PostgresPreflight`** — a shared, classified PostgreSQL connection
   check for `test_helper.exs`, replacing a `psql -lqt` listing that answered the wrong question
   (shell-user/socket reachability, not configured-role/TCP reachability) and let a bad `PGUSER`
   surface minutes later as a pool-checkout-timeout that read like flakiness.
3. Doc cleanup — `mix prerelease` documented as the publish gate in `AGENTS.md`, and personal
   email/paths scrubbed from a guide and two older review docs.

## Verification

**V188 correctness.** Walked the `dedupe_directed/4` and `dedupe_connection_pairs/1` self-join
`DELETE`s by hand against 2- and 3-row duplicate groups (directed and undirected, mixed
pending/accepted status) — both correctly retain exactly one row per group under the documented
tie-break (accepted-over-pending, then smallest/oldest uuid). The `expected_schema.ex` entries for
the three new indexes match the shape of existing index entries (`check: {:catalog, ...}`,
`revisions` tuple, `chain_hash` restamped) and the moduledoc's dated note follows the existing
convention for hand-declared objects.

**The moduledoc's claims about the race are outside this repo** — `phoenix_kit_user_connections`
was extracted to a sibling package (`/workspace/phoenix_kit_user_connections`) and only depends on
core, not the reverse — so a subagent verified them there against real code rather than assuming:

- `unique_constraint/3` names in `follow.ex`, `block.ex`, `connection.ex` match the three index
  names exactly.
- `request_connection/2` is a genuine check-then-act: `connected?/2` and two un-transactioned,
  unlocked reads of `get_pending_request_between/2` run before the eventual insert — nothing but
  a DB constraint could have closed the race, and none existed pre-V188.
- `get_accepted_connection/2` uses `repo().one()` with no `limit(1)` — two accepted rows for the
  same pair would raise `Ecto.MultipleResultsError`, exactly as the moduledoc warns.
- `remove_connection/2` looks up and deletes only the accepted row by primary key; a duplicate
  pending row for the same pair is untouched — the "ghost row" claim is accurate.
- The two-user-clicking-connect-simultaneously race is reproducible from the code as described.

Every claim in the V188 moduledoc checked out. `test/integration/user_connections_uniqueness_test.exs`
pins the behavior (constraint names, undirected duplicate rejection in both insert orders, directed
tables staying insertable in both directions) rather than just the catalog shape, which is the
right level given `HandDeclaredManifestTest` already covers the shape.

**`PostgresPreflight`.** Matches the description already in this repo's `AGENTS.md`/`CLAUDE.md` —
`Postgrex.Protocol.connect/1` over `start_link/1` (verified reasoning: `start_link/1` returns
`{:ok, pid}` for a bad role/missing DB/closed port and the real failure surfaces async inside the
connection process), connection-key whitelist so a sandboxed repo's `:pool`/timeouts aren't dragged
into the probe, `check/1` degrading to `:ok`/no-opinion on any surprise so a diagnostic that can't
diagnose never blocks a run that used to work. `postgres_preflight_test.exs` asserts against a real
server (auth rejection, missing DB, unreachable port, password never echoed, sandbox opts stripped)
and times the auth-rejection path (`< 1s`) to prove it actually replaces the multi-second pool
timeout it was built to avoid.

**Gate:** `mix precommit` — clean (compile with warnings-as-errors, `deps.unlock --check-unused`,
`quality.ci` incl. dialyzer, JS tests: 95/95 pass). `mix test` — run separately per AGENTS.md
("nothing runs the Elixir suite automatically"); see chat for the result.

## Findings

None. No bugs, no drift between the manifest and the migration, no untested branch. The
directed-vs-undirected index distinction is correctly reasoned and correctly tested; the dedupe
tie-break (accepted beats pending) is the only choice that doesn't silently disconnect users who
are actually connected.

## Verdict

**Approve, no changes required.**
