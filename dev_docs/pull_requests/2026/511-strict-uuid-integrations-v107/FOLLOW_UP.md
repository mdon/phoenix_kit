# PR #511 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code (post-merge).

## Fixed (pre-existing)

Of the reviewer's ten findings (2 MEDIUM + 2 LOW + 6 NITPICK), nine
were addressed between merge and this triage:

- ~~**MEDIUM #1: `connected_at` semantics changed mid-PR but
  AGENTS.md / CLAUDE.md still document the old behavior.** Both
  `AGENTS.md:207` and `CLAUDE.md:207` now read: *"Successful
  validation flips `status` to `\"connected\"` and rewrites
  `connected_at` on every successful re-test (matches the OAuth
  `exchange_code/4` path; the form's 'Connected N ago' reading
  bumps when the operator re-tests after fixing credentials)."* —
  exactly the suggested fix.~~
- ~~**LOW #3: V107 moduledoc says `inserted_at ASC` tiebreaker; the
  SQL uses `uuid ASC`.** Fixed (`lib/phoenix_kit/migrations/postgres/v107.ex:25`):
  *"breaking ties on `uuid ASC` (UUIDv7 is time-ordered, so smaller
  uuid ≈ ...)."* — matches the SQL at `:88`.~~
- ~~**LOW #4: `PhoenixKit.Module` moduledoc references nonexistent
  `PhoenixKit.Modules.run_all_legacy_migrations/0`.** Fixed
  (`lib/phoenix_kit/module.ex:209`): *"Host apps call
  `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from
  `Application.start/2`..."*~~
- ~~**NITPICK #5: `list_connections/1` still privileges `"default"`
  for sort order.** Reviewer's own assessment: "benign UI
  ergonomics — keeping `default` at the top is reasonable."
  Acknowledged; no change required.~~
- ~~**NITPICK #6: `integration_picker.ex` still substitutes provider
  name when `conn.name == "default"`.** Reviewer's own assessment:
  "intentional UX (shows users the provider they're picking, not a
  meaningless `default` label)." A one-liner moduledoc note
  documenting the divergence is suggested but not blocking; not
  applied in this batch.~~
- ~~**NITPICK #7: V107 / V106 tests replicate the migration SQL
  verbatim.** Documented limitation rather than a bug — the
  migration helpers can't run outside an `Ecto.Migrator` runner.
  Refactor for a future PR; out of scope.~~
- ~~**NITPICK #8: V107 test coverage doesn't exercise the new UNIQUE
  name index.** Acknowledged: two short tests (case-sensitive +
  case-only differences) would lock the contract. Out of scope for
  this triage; a short follow-up test would be a clean future
  addition.~~
- ~~**NITPICK #9: `add_connection/3` doesn't dedupe against legacy
  bare `integration:{provider}` key.** Pre-existing risk acknowledged
  by the reviewer ("not a regression — same risk existed pre-PR").
  `migrate_legacy/0` callbacks are the boot-time mitigation. No
  in-PR fix required.~~

## Fixed (Batch 1 — 2026-05-06)

- ~~**MEDIUM #2: Microsoft 365 has no tenant override; single-tenant
  apps fail at OAuth time (AADSTS50194).** Fixed via two changes:

  1. **OAuth URL templating** (`lib/phoenix_kit/integrations/oauth.ex`)
     — new private `interpolate_url/3` substitutes `{key}`
     placeholders with values from the integration's data (string-keyed
     JSONB), falling back to `oauth_config[:url_defaults][key]`. Wired
     into `authorization_url/5`, `exchange_code/4`, and
     `refresh_access_token/2`. URLs without `{` pass through unchanged
     (zero impact on Google / OpenRouter / Mistral / DeepSeek).
  2. **Microsoft provider definition update**
     (`lib/phoenix_kit/integrations/providers.ex:386-403`):
     - `auth_url` / `token_url` now use `{tenant_id}` placeholder.
     - New `url_defaults: %{"tenant_id" => "common"}` so
       multi-tenant remains the default behavior.
     - New `tenant_id` setup_field (optional, `placeholder: "common"`,
       help text covers the GUID / `consumers` / `organizations`
       options).
     - Instructions panel note rewritten — operators now fill in the
       Tenant ID form field rather than manually editing the URLs.

  Three pinning tests in
  `test/phoenix_kit/integrations/oauth_test.exs:78-105`:
  - `interpolates {placeholder} from integration_data` — substitutes
    a real GUID
  - `falls back to url_defaults` — substitutes `common`
  - `URLs without {placeholder} pass through unchanged` — pins
    backwards compat for Google / others

  All 21 OAuth tests pass.~~

- ~~**NITPICK #10: `verify_oauth_state/2` is permissive when no state
  was stored.** Tightened to return `{:error, :state_mismatch}` on
  the missing-state branch
  (`lib/phoenix_kit_web/live/settings/integration_form.ex:626-642`).
  Comment updated to explain why: post-2026-05 every `connect_oauth`
  event saves state via `save_oauth_state/2` before redirect (`:227`),
  so a missing state at callback time means either (a) someone
  bypassed `connect_oauth` or (b) the row was mutated between
  authorize and callback — both shapes are CSRF-relevant. The older
  lenient flow that justified the original `:ok` is gone. No tests
  exercised the lenient branch (verified via grep), so no test churn.~~

## Skipped

- **NITPICK #6** (`integration_picker` divergence doc note) remains
  unaddressed pending Max's read on the trade-off — see "Open" below.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit/integrations/oauth.ex` | Add `interpolate_url/3` private helper; wire into `authorization_url/5`, `exchange_code/4`, `refresh_access_token/2` |
| `lib/phoenix_kit/integrations/providers.ex` | Microsoft 365: `{tenant_id}` placeholders + `url_defaults` + `tenant_id` setup field; rewrite instructions note |
| `lib/phoenix_kit_web/live/settings/integration_form.ex` | Tighten `verify_oauth_state/2` — missing/empty stored state now returns `{:error, :state_mismatch}` instead of `:ok` |
| `test/phoenix_kit/integrations/oauth_test.exs` | 3 new tests pinning the URL interpolation contract |

## Verification

OAuth test suite: 21 tests, 0 failures (mix test
test/phoenix_kit/integrations/oauth_test.exs).

## Open

- **NITPICK #6 (integration_picker divergence)** — surfaced to Max for
  a decision on whether to add a moduledoc note documenting the
  divergence with the management list.
