# PR #878 — Write the per-domain-currency stage labels and a quoted doctor message in English

**Author:** timujinne · **Reviewer:** Claude · **Date:** 2026-09-28
**Verdict:** sound; merged into 2.41.3. Comment-only change.

Four comments across three files lose their Russian text:

- `lib/mix/tasks/phoenix_kit.doctor.ex` — the comment above
  `fk_probe_failure_reason/1` quoted a Russian phrase for the operator-facing
  wording. It now quotes `"not checked, not clean"`, which is the actual
  suffix both timeout clauses return, so the comment and the code agree.
- `lib/phoenix_kit/migrations/expected_schema.ex` — the V184/V189 stage
  labels `Э0`/`Э5` (Cyrillic) become `E0`/`E5`. No other file in the repo
  referenced the Cyrillic labels, so nothing is left pointing at the old
  spelling.
- `test/phoenix_kit/settings_test.exs` — `poштучно` → "one value at a time",
  `"отличимо"` → `"distinguishable"`; both translations are faithful.

The Cyrillic still in `lib/` and `test/` (`slug.ex`, `country_data.ex`,
transliteration / Unicode test data) is test input or lookup data, not
comments, and is correctly left alone.

Findings: none. No code paths change; the gate (`mix precommit`) is the
check, no `mix test` run needed.
