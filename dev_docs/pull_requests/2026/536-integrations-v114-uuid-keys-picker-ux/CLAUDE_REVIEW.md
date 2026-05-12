# PR #536 Review — Integrations V114: uuid-only storage keys + picker UX + form fixes

**Status:** Merged. Review for post-merge follow-up.
**Scope:** V114 migration, `Integrations` context refactor, IntegrationPicker rewrite, integration_form fixes, C12 sweep (`phx-disable-with`, narrowed rescue, doc note), Permissions `"db"` core-map pin, V113-fixture fallout.

Overall this is a high-quality refactor — the storage shift is well-motivated (uuid as the sole row identity lifts artificial name constraints), the migration is round-trip tested, and the picker rewrite ships with real component coverage. Issues below are mostly polish; nothing here is a release blocker.

---

## BUG — MEDIUM

### #1 OAuth state save/cleanup goes through `save_setup/3`, emitting phantom activity + broadcast

`lib/phoenix_kit_web/live/settings/integration_form.ex:589-619`

`save_oauth_state/2` and `verify_oauth_state/2` use `Integrations.save_setup(uuid, ...)` to persist/clear the CSRF state token. But `save_setup/3` is the public credential-write path — it broadcasts `:integration_setup_saved` (`integrations.ex:339`) **and** writes an `"integration.setup_saved"` Activity row (`integrations.ex:341-348`). The result: every OAuth dance currently produces two spurious "setup saved" activity entries (one at authorize-start, one after callback) and two listing-LV reload broadcasts that the operator didn't trigger.

It also collides with the activity-log convention in `AGENTS.md` (`action = resource.verb`): nothing was "saved" from the operator's perspective.

**Why this is more than cosmetic:** the Activity feed is consumed by audit / notifications, and `notifications.ex` fans out to `target_uuid` users. The current shape pollutes audit history with internal mechanics.

**Fix shape:** introduce a private `Integrations.put_internal_field(uuid, key, value)` (no encryption of credential fields → still safe; no broadcast; no activity log), or — simpler — keep the OAuth state in `Plug.Conn.put_session/3` instead of the JSONB body. Session-scoped storage is also the textbook home for a CSRF token. Storing it next to `client_secret` in encrypted JSONB works but couples a short-lived browser flow value to long-lived credential state.

This was pre-existing pattern in this LV, but V114's tighter activity-logging discipline (explicit `(provider, name)` in `log_activity`) made the noise more visible. Worth lifting.

---

## BUG — LOW

### #2 V114 moduledoc still talks about "V113"

`lib/phoenix_kit/migrations/postgres/v114.ex`

Three stale references from the pre-rebase numbering survived the rename:

- Line 21: `"V113 lifts both by collapsing the storage key…"` — should be **V114**.
- Line 41: `"Stamp the table comment with '113'"` — but the actual code at line 63 stamps `'114'`. The narrative description is wrong; the code is right.
- (Bonus, not strictly wrong but confusing) Line 7 says "Before V113" which is technically true historically but mixes with the above to read as if V113 is this migration.

Same pattern in two test files — they use the phrase "post-V113 invariant" / "post-V113" when documenting the behavior change introduced by **this** migration (V114):

- `test/integration/integrations_test.exs:81, 252, 366` — "post-V113 regression" / "post-V113 invariant"
- `lib/phoenix_kit_web/components/core/integration_picker.ex:252` — "post-V113"

None of these affect runtime — they're docstring drift caught by the rebase rename. Worth a sweep.

### #3 `validate_credentials/2` rescue not narrowed (matches `validate_connection/2`'s pre-fix shape)

`lib/phoenix_kit/integrations/integrations.ex:911-918`

The PR narrowed `validate_connection/2`'s `rescue e ->` (line 864) to `[DBConnection.OwnershipError, Postgrex.Error, Req.TransportError]` so that genuine logic bugs (`KeyError`, `ArgumentError`, `MatchError`) bubble up to the supervisor instead of being swallowed under a generic "validation failed" message. Good change.

But the **dry-run sibling**, `validate_credentials/2` (used by the form's `_intent=test` path), still has the broad `rescue e ->` it had before. Both call the same `do_validate/2` codepath — same exception surface — so the same narrowing reasoning applies. As written, a `KeyError` inside `do_validate` will surface in the form path but crash in the save path. Asymmetric error handling for the same logic.

**Fix:** mirror the narrowed rescue list:

```elixir
rescue
  e in [DBConnection.OwnershipError, Postgrex.Error, Req.TransportError] ->
    Logger.error("[Integrations] validate_credentials error for #{provider_key}: #{Exception.message(e)}")
    {:error, gettext("Validation failed unexpectedly")}
end
```

### #4 Permissions `"db"` core-map fallback inverts external-module precedence

`lib/phoenix_kit/users/permissions.ex:335-373`

The pin (`@core_labels`, `@core_icons`, `@core_descriptions` get a `"db"` entry) keeps the test suite green when `phoenix_kit_db` isn't loaded. Per the commit message that's the immediate goal, and the inline comment justifies it.

But `module_label/1` does `Map.get_lazy(@core_labels, key, fn -> ModuleRegistry.permission_labels()[key] || ... end)` — **core wins over the registry**. If `phoenix_kit_db` ever evolves its label to `"Database"` or `"DB Explorer"`, core's hardcoded `"DB"` shadows it. The extracted module loses authority over its own metadata.

This is a regression vs the extensibility model the rest of the file follows (custom keys fall through to the registry; only `"db"` shortcuts it). The fix is to flip the order — registry first, core-map as fallback. That preserves the green-test outcome (core stays "DB" when `phoenix_kit_db` isn't loaded) and restores external-module authority when it is.

**Alternative:** make the `"db"` entries conditional on `Code.ensure_loaded?(PhoenixKitDb)` returning false — explicit fallback rather than override.

**Best:** treat `"db"` as a feature module like every other extracted module — i.e. don't ship a core-map override at all, and instead fix the test that asserts `"DB"` to either load the external module or assert against `Permissions.module_label("db")` only in environments where the module is registered. The PR description acknowledges this is "the post-rebase baseline green" trade-off, which is fine for landing, but worth treating as a TODO to clean up.

---

## IMPROVEMENT — MEDIUM

### #5 `find_uuid_by_provider_name/1` first-match semantics is now load-bearing for legacy callers

`lib/phoenix_kit/integrations/integrations.ex:177-204`

Post-V114, names aren't unique per provider — `find_uuid_by_provider_name("openrouter:work")` returns whichever of N duplicate "work" rows sorts first (`list_connections` sorts by `String.downcase(name)`, with no secondary tiebreaker). For the migration sweep use case (`migrate_legacy/0` callbacks promoting `provider:name` strings to uuid references) this is silent ambiguity: which duplicate gets pinned depends on insertion-order-determined uuid sort.

The docstring acknowledges this ("Does NOT auto-pick an arbitrary connection when multiple match — that's not the caller's intent here") but the code does exactly that for the duplicate case. The comment matches intent; the implementation matches the legacy-shim contract. Worth either:

1. Making the function `{:error, :ambiguous}` when N>1 matches, forcing legacy migrations to disambiguate (could break in-flight migrations);
2. Tightening the docstring to "first-match by case-insensitive name sort, no secondary tiebreaker" so consumers know what to expect;
3. Adding a deterministic secondary sort key (e.g. `:date_added`) so the picked uuid is stable across processes.

Option 2 is the lowest-risk; option 3 is the cleanest if anyone cares about reproducibility.

### #6 V114 `up` SQL has no guard against malformed legacy keys

`lib/phoenix_kit/migrations/postgres/v114.ex:88-107`

For a row keyed literally `"integration:"` (no provider, no name — degenerate but possible from an aborted insert), `substring(key from 13)` returns `""`, `split_part("", ':', 1)` returns `""`. The `NULLIF(..., '')` on provider falls through to NULL because there's no further fallback — the row ends up with `value_json -> 'provider' = null`, which then makes the row invisible to `list_connections/1` (the `?->>'provider' = ?` predicate skips it).

The legacy "default" fallback applies only to `name`, not `provider`. A row at `"integration:"` becomes orphaned post-migration — still in the table, but `module = 'integrations'` and provider = null means the row pollutes counts without being addressable.

**Probability:** very low in practice (would require a manually-corrupted insert). But cheap to handle: add a `WHERE substring(key from 13) <> ''` to the up rewrite, or `COALESCE(NULLIF(..., ''), 'unknown')` so the row at least has a discoverable shape.

### #7 V114 down test only covers 2-row collisions; 3+ row case unchecked

`test/phoenix_kit/migrations/v114_test.exs:252-289`

The down-collision suffix logic uses `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY date_added NULLS LAST, uuid)`. With ≥3 rows sharing `(provider, name)`, rn=1 keeps the plain key and rn=2..N get `-<uuid prefix>` suffixes. The test covers the 2-row case (one plain, one suffixed) but not 3+.

For a one-shot migration this matters less than it would for a CRUD path — but if down ever runs in anger on real data, the 3-row case is plausible (operator added 3 connections all named "work" pre-V114, then rolled back). An assertion that all N rows produce N distinct keys, with exactly one plain and N-1 suffixed, would close the gap. Small additional test.

### #8 `validate_connection/2` rescue mentions `record_validation` callees, but the function doesn't call them

`lib/phoenix_kit/integrations/integrations.ex:864-886`

The narrow rescue's docstring (line 870-878) says the `Postgrex.Error` arm handles "DB outage / table-missing mid-flight during the `record_validation` write that `validate_connection` itself doesn't perform but called helpers (log_activity, `Providers.get` if backed by DB later) might". But within this function's body, only `Providers.get/1` (in-memory registry, doesn't hit DB) and `log_activity/6` (Postgrex via Activity.log) are called — `record_validation/2` isn't on this path; the LV calls it separately at `integration_form.ex:334`.

The reasoning is sound for `log_activity`, but mentioning `record_validation` is misleading — a future reader following the call chain won't find it. Tighten the comment to "`log_activity` hits the DB and can raise `Postgrex.Error` if the activity table is missing or unreachable."

### #9 `<form phx-submit="save_form">` doesn't include CSRF token

`lib/phoenix_kit_web/live/settings/integration_form.html.heex:165`

LiveView's WebSocket channel handles CSRF at connect time, so for live-mode submits this is fine. But if the LV ever falls back to a dead-render submit (degraded WebSocket), Phoenix's CSRF protection on the controller will reject the form. The convention in PhoenixKit is to use `<.form>` (which adds the hidden CSRF input automatically) rather than raw `<form>`. Not a security hole given the LV-only flow, but consistency with the rest of the codebase would help — and would surface the issue if someone ever refactors this to a controller-backed flow.

Also relevant: the form lacks a `for=@form` binding, so HTML5 validation errors don't surface through LiveView's error rendering pipeline. The "Connection Name" field uses `required` (line 206), but failed validation is a browser popup rather than a styled inline error matching the rest of the form components per `AGENTS.md` ("Core Form Components" section). Migrating to `<.input>` / `<.input field={...} />` would also enable `phx-feedback-for` for the post-save error states the LV already routes through `@error`.

---

## IMPROVEMENT — LOW

### #10 `IntegrationPicker.filter_by_search/2` rebuilds `provider_def` per row

`lib/phoenix_kit_web/components/core/integration_picker.ex:413-430`

Within the search-filter callback, every connection invokes `provider_def(conn)` which calls `Providers.get/1`. The same call happens again on render at `:149`. For O(N) connections this is 2N registry hits per render — fine when N=10, less fine if someone wires this into a long picker (e.g. an org with 200 integrations).

`Providers.get/1` is a fast `Map.get` over `Providers.all/0` (which itself walks the registry), but the rebuild is wasted work. A one-pass `Map.new(connections, &{&1.uuid, provider_def(&1)})` before the search filter would amortise.

Not urgent — the auto-show threshold for search is `> 6`, and even at 50 connections this is sub-millisecond. Worth a note for future scaling.

### #11 `connection_subtitle/1` variable shadowing in `filter_by_search/3`

`lib/phoenix_kit_web/components/core/integration_picker.ex:417-425`

```elixir
name = String.downcase(conn.name || "")
...
provider_display =
  case provider_def(conn) do
    %{name: name} when is_binary(name) -> String.downcase(name)
    _ -> ""
  end
```

The inner `name` in the pattern match shadows the outer `name = String.downcase(conn.name || "")`. The match-and-use works correctly (each `name` is locally scoped), but Credo's default warning-on-shadowing would flag this. Rename to `provider_name` inside the case clause.

### #12 `Phoenix.HTML.html_escape` value coercion drops non-string values

`lib/phoenix_kit_web/live/settings/integration_form.ex:656`

```elixir
escaped = Phoenix.HTML.html_escape(value || "") |> Phoenix.HTML.safe_to_string()
```

If `vars[key]` is an integer or atom (e.g. an operator-supplied port number that lands in instruction text), `html_escape` returns the value unchanged when not a string, then `safe_to_string` would crash. Currently safe because `vars` is always `%{"redirect_uri" => @redirect_uri || ""}` — string only. Tightening to `to_string(value || "")` before escape would close the door on a future caller passing a non-binary.

### #13 `mask_credential/1` uses deprecated negative-range syntax

`lib/phoenix_kit_web/components/core/integration_picker.ex:406`

```elixir
String.slice(value, -4..-1)
```

Works fine in current Elixir but emits a step warning in 1.16+ on default settings (`step: 1` required for ranges with negative bounds in some cases). Safer/clearer: `String.slice(value, -4..-1//1)` or `binary_part(value, byte_size(value) - 4, 4)`. Cosmetic.

### #14 OAuth `Connect Account` button has no `phx-disable-with`

`lib/phoenix_kit_web/live/settings/integration_form.html.heex:362-369`

The C12 sweep added `phx-disable-with` to Save / Test / Disconnect / Delete. The OAuth "Connect Account" button (`phx-click="connect_oauth"`) didn't get one. While the click does `redirect(socket, external: url)` so a double-click results in two `save_oauth_state/2` writes (each generates a new state token, and only the last one survives — so it's not catastrophic), it's still inconsistent with the rest of the sweep. Add `phx-disable-with={gettext("Redirecting…")}` for parity.

### #15 `<.input>` core components not used in integration_form

`lib/phoenix_kit_web/live/settings/integration_form.html.heex:195-249`

The form uses raw `<input type="text">` blocks. `AGENTS.md` (Core Form Components section) is explicit: "Use over raw `<input>`/`<select>`/`<textarea>` in new code." This LV pre-dates the convention so it's an existing-debt situation, not a regression — but the PR touched the template (removed the name-rules hint, added `phx-disable-with`) so it's a natural opportunity to migrate at least the touched fields. Tracker: the existing `dev_docs/pull_requests/2026/...` TODO in `AGENTS.md` under "Component test coverage" mentions `<.input>` test coverage but not its rollout to this form. Worth folding into that cleanup.

---

## NITPICK

### #16 Test docstring uses past version label

`test/phoenix_kit/migrations/v114_test.exs:1` — moduledoc reads fine, but several inline test comments (`"post-V113 regression"`, `"post-V113 invariant"`) carry the old number. See #2 above.

### #17 `disconnect/2` drops `external_account_id` for OAuth on disconnect

`lib/phoenix_kit/integrations/integrations.ex:477-481`

```elixir
data
|> Map.take(["provider", "auth_type", "name", "client_id", "client_secret"])
|> Map.put("status", "disconnected")
```

`external_account_id` (the userinfo email) is dropped on disconnect. This is asserted-as-expected in the test at `test/integration/integrations_test.exs:181`, so it's deliberate. But it means re-connecting a previously-known account shows no "you previously connected as user@example.com" hint — the operator has to remember which account they linked. Minor UX loss; preserving the field across disconnect (in a `last_connected_account` metadata slot) would be friendlier.

### #18 `list_integrations/0` Enum.flat_map order is map-key dependent

`lib/phoenix_kit/integrations/integrations.ex:553-560`

```elixir
load_all_connections(provider_keys)
|> Enum.flat_map(fn {_provider, connections} -> ... end)
```

`load_all_connections/1` returns a `Map.new(...)`, so iteration is key-sorted. The output isn't in `Providers.all/0` order (which the input list was). For UI callers that list registered providers and want a known order, this surprises. The current callers don't care (UI lists are sorted client-side by daisyUI grid order), but documenting the order — or returning a keyword list to preserve input order — would help future callers.

### #19 `searchable` attr typed as `:any`

`lib/phoenix_kit_web/components/core/integration_picker.ex:88`

```elixir
attr :searchable, :any, default: nil
```

Used to allow `nil | true | false` (nil triggers the >6 auto-show). Phoenix's attr type system supports `:boolean` only (no `:boolean_or_nil`). Workaround would be a separate `:auto_searchable` attr or a sentinel symbol. Not worth the API churn — current shape works — but a docstring note that nil = auto-detect would help.

### #20 V114 test runs SQL verbatim, drift risk

`test/phoenix_kit/migrations/v114_test.exs:64-113`

`run_up!` / `run_down!` copy the SQL from `v114.ex`. If anyone tweaks the migration (e.g. to fix #6), the test stays green against the old SQL. The moduledoc explains why (`Ecto.Migrator` runner constraint), but a `@external_resource "../lib/phoenix_kit/migrations/postgres/v114.ex"` annotation would at least trigger recompilation when the SQL changes; a fixture extraction (read SQL from a `.sql` file shared by lib and test) would prevent drift entirely. Optional.

---

## Strengths

A few things this PR got really right and shouldn't be lost in the issue list:

- **Round-trip tests for the migration**: V114 has 9 tests covering up + down + idempotence + collision + V0-shape edge case. The "V0 keyless `integration:google` → name=default" SQL bug caught by `split_part(... from 13), ':', 2` is exactly the kind of edge case a less-thorough test pass misses.
- **Storage-shape invariants test block** (`integrations_test.exs:1004-1051`) pins the architectural promises: `key = uuid`, `module = "integrations"`, JSONB-only provider/name. These will fail loudly if anyone reintroduces the old shape by accident — defensive against regression.
- **IntegrationPicker coverage** (33 tests): subtitle priority, masked-credential edge cases (short keys, three field types), every status branch, every click-action shape. Sets a good bar for future core-component PRs.
- **Form-clear preservation on error** (`integration_form.ex:165-178`): the failure case where `:empty_name` wipes the typed `api_key` was a real UX papercut — preserving `:new_name` + `:form_values` on every error branch (including the "future unknown" `{:error, reason}` arm) is the right defensive shape.
- **Activity-log rewrite to take explicit `(provider, name)`**: avoiding `uuid` strings leaking into `metadata.connection` was a subtle catch. The audit feed stays human-readable.
- **The `authenticated_request/4` security note** (`integrations.ex:511-526`): the doc spelling out "Bearer token attached to every request, callers must pin URLs to a domain allowlist" is the kind of guardrail that prevents the next callsite from being a SSRF vector. Doc-only fix that does real work.

---

## Suggested follow-up scope

Tier 1 (worth fixing before next release):
- **#1** OAuth state save phantom activity log + broadcast
- **#3** `validate_credentials/2` rescue narrowing (parity with #2 of PR)

Tier 2 (worth folding into the next sweep):
- **#2** V114 docstring `V113`→`V114` rename across moduledoc + tests + picker comment
- **#6** V114 up empty-`integration:` key guard
- **#4** Permissions `"db"` precedence inversion
- **#9 / #15** Form `<.input>` migration + CSRF
- **#14** OAuth Connect button `phx-disable-with`

Tier 3 (nice-to-have, low ROI):
- **#5** `find_uuid_by_provider_name` ambiguity docstring or `:ambiguous` return
- **#7** 3+ row down-collision test
- **#10**, **#11**, **#12**, **#13**, **#17–20** — cosmetics

---

## Verification

- Read all 16 changed files (lib + test).
- Checked `git log --follow` history for V114 numbering provenance — confirmed the rebase rename trail.
- Spot-checked `Providers.get/1`, `Settings.get_json_setting_by_uuid/1`, `Settings.Queries.get_setting_by_uuid/1` signatures referenced by the refactor (existing API, contract unchanged).
- Did NOT run `mix test` (per project policy: `mix precommit` is the bar; integration suite needs Postgres). PR description claims 1229 tests / 0 failures.
- Did NOT run `mix credo --strict` (would surface #11 variable shadowing locally).
