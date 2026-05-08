# PR #516 — V111 PDF library tables + #511 / #512 / #515 follow-ups

**Author:** @mdon
**Branch:** `dev` ← `dev` (mdon fork)
**Merged:** 2026-05-06T16:00:01Z (`0447564c`)
**Diff:** +550 / -23 (11 files, 4 commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/516

## Verdict

**APPROVE.** Three roughly-independent threads bundled into one PR, each
small enough that the bundling reads as efficient rather than risky:

1. **V111 — PDF library tables.** Four catalogue-side tables on top of
   `phoenix_kit_files`. The shape is right: per-upload row separated
   from per-file extraction state separated from per-page text dedup.
   The composite-PK + content-hash design is the load-bearing decision,
   and it's the right one — same boilerplate text (legal disclaimers,
   product cross-references) doesn't bloat the GIN index.

2. **OAuth URL interpolation + Microsoft 365 tenant fix** (closing
   PR #511's MED #2). `interpolate_url/3` is a clean primitive — substring
   `{` test → cheap pass-through for every other provider, regex only
   when needed. Three pinning tests cover the contract (substitution,
   default fallback, no-placeholder pass-through).

3. **Three follow-up audits** documenting that 9/10 of #511's findings,
   all 6 of #512's, and all 5 of #515's were already closed in code by
   the time of triage. This is the right shape for "what was acted on,
   what was rejected, what's still open" — it preserves the audit trail
   in-repo per the workspace convention.

Findings below are improvements / nitpicks; nothing blocking.

## What changed

| Layer | Change |
|---|---|
| Migration | New `V111` — four tables, enables `pg_trgm`, `@current_version` 110 → 111 |
| Schema | `phoenix_kit_cat_pdfs` (per-upload), `_extractions` (per-file state machine), `_page_contents` (content-hash dedup cache + GIN trigram), `_pages` (composite-PK join) |
| OAuth | `interpolate_url/3` private helper in `OAuth`; wired into `authorization_url/5`, `exchange_code/4`, `refresh_access_token/2` |
| Provider registry | Microsoft 365 — `{tenant_id}` URL template + `url_defaults` + `tenant_id` setup field |
| OAuth state | `verify_oauth_state/2` — missing stored state now `{:error, :state_mismatch}` (was `:ok`) |
| Picker | `IntegrationPicker` — drop `conn.name == "default"` substitution; always render user-chosen name + provider badge |
| Component | `<.file_upload>` — `Uploading… N%` instead of bare `N%` in entry-progress label |
| Tests | +3 OAuth interpolation tests pinning the M365 fix |
| Docs | `FOLLOW_UP.md` for PRs #511 / #512 / #515 |

## Findings

### IMPROVEMENT - MEDIUM — `up/1` opens with unconditional `DROP TABLE … CASCADE` on four catalogue-prefix tables

`lib/phoenix_kit/migrations/postgres/v111.ex:51-54`:

```elixir
execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdf_pages CASCADE")
execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdfs CASCADE")
execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdf_extractions CASCADE")
execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdf_page_contents CASCADE")
```

The comment on `:48-50` explains: *"if an earlier (pre-rewrite) V111 left
rows behind in dev they get dropped here so the schema matches the new
code."* This is a development workaround — fine for catalogue's pre-1.0
state, but it has two non-obvious consequences once anyone has a real
PDF library to lose:

1. **`up/1` is no longer additive.** Every other Vxxx migration in
   `lib/phoenix_kit/migrations/postgres/` is monotonic — applying it to
   a DB at the same version is a no-op (idempotent guards) or a
   forward-only schema delta. V111 is the first migration that
   *destructively* re-runs against an already-current DB if you ever
   call `Ecto.Migrator.run/4` with `all: true` against a DB that's
   already at 111: the marker comment is `'111'` so the migrator filters
   it out, but a manual `up(%{prefix: "..."})` call (e.g. via
   `ensure_current/2` quirks or a re-run after `down/1`) drops live
   data.
2. **`CASCADE` propagates beyond the four tables.** If a downstream
   catalogue table grows an FK to `phoenix_kit_cat_pdfs` or
   `phoenix_kit_cat_pdf_extractions` *without* a matching V112 to drop
   that FK, V111's `DROP … CASCADE` will silently take that downstream
   table's rows down with it. Today no such FK exists, but the
   destructive `CASCADE` is a footgun for the catalogue team in the
   weeks ahead.

A safer shape: leave the `DROP TABLE` lines out, write a one-shot
catalogue-side cleanup script (`mix phoenix_kit_catalogue.reset_pdfs` or
similar) that operators run *only* if they have a pre-rewrite prototype
DB, and let V111 itself stay strictly additive.

If the destructive `up/1` stays, the moduledoc should say so — the
current moduledoc reads as a normal additive migration and a future
maintainer running `Ecto.Migrator.up(repo, [PhoenixKit.Migrations.Postgres.V111], log: true)`
on a populated DB has no warning that they're about to wipe tables.

**Where:** `lib/phoenix_kit/migrations/postgres/v111.ex:42-54`

### IMPROVEMENT - LOW — `interpolate_url/3` has a dead atom-key fallback

`lib/phoenix_kit/integrations/oauth.ex:222-233`:

```elixir
Regex.replace(~r/\{([a-zA-Z0-9_]+)\}/, url, fn _, key ->
  integration_data[key] ||
    defaults[key] || defaults[String.to_atom(key)] ||
    ""
end)
```

The chain has three lookups, but only two of them can ever hit. Provider
definitions in `providers.ex` are hardcoded maps with **string keys**
(`url_defaults: %{"tenant_id" => "common"}`), and `oauth_config` flows
straight from `Providers.get_provider/1` into `interpolate_url/3` without
an intermediate `Map.new(...)` step that would atomize anything. That
makes `defaults[String.to_atom(key)]` dead code — there is no path in
the current codebase that reaches it.

The risk is twofold:

1. **`String.to_atom/1` on user-controlled-ish input** — even though
   the regex `[a-zA-Z0-9_]+` bounds the cardinality, atom-table growth
   is irreversible. The bound is fine in practice (any real provider
   has a finite, small placeholder set baked in at compile time), but
   the `String.to_atom` exists *only* to support a code path that
   doesn't actually run.
2. **Future maintainer confusion** — the chain implies "we sometimes
   see atom-keyed defaults," which would be wrong evidence to plan
   future work around.

Either:
- Drop `defaults[String.to_atom(key)]` and let `defaults[key]` be the
  only fallback, *or*
- Keep the atom-key path and convert one provider to atom-keyed
  `url_defaults` to prove the path runs, *or*
- Rename to `defaults[key] || defaults[:"#{key}"]` and add a one-line
  comment explaining why both shapes are accepted.

The empty-string final fallback (`|| ""`) is also worth a moduledoc
note: a missing-everywhere placeholder produces
`https://login.microsoftonline.com//oauth2/v2.0/authorize` (double
slash) which would 404 at OAuth time. The `url_defaults` for M365
guarantees this can't happen for the current provider, but a future
provider author who omits `url_defaults` will silently ship a broken
OAuth flow. Better to raise on `nil`-everywhere and force the provider
author to think about it.

**Where:** `lib/phoenix_kit/integrations/oauth.ex:215-234`

### NITPICK — `phoenix_kit_cat_pdf_pages.content_hash` references via `type: :"varchar(64)"`

`lib/phoenix_kit/migrations/postgres/v111.ex:124-130`:

```elixir
add(
  :content_hash,
  references(:phoenix_kit_cat_pdf_page_contents,
    column: :content_hash,
    type: :"varchar(64)",
    on_delete: :restrict,
    prefix: prefix
  ),
  null: false
)
```

The atom literal `:"varchar(64)"` works (Ecto.Migration passes the type
verbatim to the FK declaration), but it's an unusual shape — the parent
column was declared as `add(:content_hash, :string, primary_key: true,
null: false, size: 64)` which produces `varchar(64)` from Ecto's
`:string + size:` mapping. The two declarations diverge in style:
parent uses Ecto-symbolic, FK uses the rendered SQL type. If anyone
ever changes the parent column's size, the FK silently drifts.

A more conventional shape:

```elixir
add(
  :content_hash,
  references(:phoenix_kit_cat_pdf_page_contents,
    column: :content_hash,
    type: :string,         # produces varchar without size; PG matches FK to parent column type
    on_delete: :restrict,
    prefix: prefix
  ),
  null: false
)
```

Postgres's FK type-matching is by-name-and-collation rather than
strict-size-equality (it'll accept `varchar` matching `varchar(64)` as
long as the values fit), so dropping the size from the FK side is safe.
Or, if you want strictness: declare the parent as `:binary, size: 32`
(SHA-256 raw is 32 bytes) and store as bytea — half the storage, no
hex-decode at search time.

**Where:** `lib/phoenix_kit/migrations/postgres/v111.ex:113-130`

### NITPICK — `phoenix_kit_cat_pdf_page_contents` has `inserted_at` but no `updated_at` (intentional, undocumented)

`lib/phoenix_kit/migrations/postgres/v111.ex:104-110`:

```elixir
create table(:phoenix_kit_cat_pdf_page_contents,
         primary_key: false,
         prefix: prefix
       ) do
  add(:content_hash, :string, primary_key: true, null: false, size: 64)
  add(:text, :text, null: false)
  add(:inserted_at, :utc_datetime, null: false)
end
```

Same on `_pages` (`:130`). This is correct — the rows are immutable
content-addressed by SHA-256 hash, an `updated_at` would always equal
`inserted_at` — but it's the first migration in `lib/phoenix_kit/migrations/postgres/`
to use raw `inserted_at` instead of `timestamps()`. The moduledoc would
benefit from one line per table (in the "## Tables" section) explicitly
noting *"immutable; no `updated_at`."* Otherwise a future maintainer
adding a touch-on-write column has no warning that the table's contract
is "rows are deduped, never updated."

**Where:** `lib/phoenix_kit/migrations/postgres/v111.ex:25-39, 101-110, 130-145`

### NITPICK — `phoenix_kit_cat_pdfs.byte_size` is nullable

`lib/phoenix_kit/migrations/postgres/v111.ex:84`:

```elixir
add(:byte_size, :bigint)
```

Every upload via `phoenix_kit_files` has a known size at the moment of
upload — there's no flow where you'd write a `phoenix_kit_cat_pdfs` row
without a corresponding sized `phoenix_kit_files` row. Making the
column `null: false` would catch a future inserter that forgets to
populate it, at zero cost today.

If the intent is "this column might also store decoded PDF size after
extraction" (different from the on-disk file size), say so in the
moduledoc — but currently it reads as a denormalized copy of
`phoenix_kit_files.byte_size` and the column comment doesn't indicate
otherwise.

**Where:** `lib/phoenix_kit/migrations/postgres/v111.ex:78-86`

### NITPICK — PR body's "verification" gap

The PR body acknowledges:

> - [ ] `mix precommit` clean end-to-end (running phx.server on the
>       shared dev DB blocks an ad-hoc full-suite run from this branch
>       this session)

That's a known limitation rather than a defect, but it's worth noting
that the OAuth tests run in isolation (they use config-only assertions,
no DB). The migration test verifies V111 applies on a fresh DB at
catalogue-side `mix test` time — that's the empirical pass for the
schema. Three OAuth tests pinning M365 + the catalogue boot proof are
together stronger than `mix precommit` would be for this specific PR's
risk surface.

### NITPICK — `IntegrationPicker` simplification could drop `is_map(conn[:provider])` guard

`lib/phoenix_kit_web/components/core/integration_picker.ex:174-183`:

```heex
<span
  :if={is_map(conn[:provider])}
  class="badge badge-ghost badge-xs shrink-0"
>
  {conn.provider.name}
</span>
```

The pre-PR shape needed the guard because `conn.name == "default"` was
the trigger; now that the substitution is gone, the badge always wants
to render — the only failure mode is `conn` lacking `:provider`, which
shouldn't happen for any normally-loaded connection (`list_connections/1`
populates it). A defensive `is_map(conn[:provider])` is fine, but the
parallel comment block on `:170-171` already says "always the
user-chosen label" — the badge case deserves the same comment style:
"badge always renders when the provider is loaded; defensive guard
covers the partially-loaded case in tests / migrations."

Cosmetic; not load-bearing.

**Where:** `lib/phoenix_kit_web/components/core/integration_picker.ex:167-185`

### NITPICK — Three FOLLOW_UP.md docs land in one PR; future audits can't easily attribute closures

The PR body and the three `FOLLOW_UP.md` files attribute closures to
"pre-existing" vs. "fixed in this PR's batch 1." Useful, but a future
maintainer wanting to understand "when did NIT #6 of #511 actually
land?" has to cross-reference the PR's commit list against the file's
diff — `8a5a393b` covered Batch 1, `0447564c` is the tail commit. A
single-line `(commit `8a5a393b`)` next to each "Fixed (Batch 1)" entry
in the FOLLOW_UP files would close that loop.

This is deep-archaeology nitpicking; the FOLLOW_UPs are clearly written
and the closure rationales are sound. Just noting that the audit trail
would be slightly tighter with explicit commit pinning.

**Where:** `dev_docs/pull_requests/2026/511-strict-uuid-integrations-v107/FOLLOW_UP.md:52-107`

## What's good

- **`interpolate_url/3` short-circuit on `String.contains?(url, "{")`.**
  Provider-specific cost only — Google / OpenRouter / Mistral / DeepSeek
  pay one `String.contains?/2` call per OAuth roundtrip, then bail. The
  alternative ("always run `Regex.replace`") would impose a regex
  compilation + match cost on every provider for a feature 1/N of them
  needs.
- **The new tenant_id setup field.** Adding the operator-facing form
  field rather than telling them to "edit the URLs manually" (the old
  instructions panel note) eliminates a per-deployment manual step
  that would have been a copy-paste failure mode forever.
- **`verify_oauth_state/2` tightening.** The `:state_mismatch` change
  is correctly a *security* fix, not just a hygiene one. The comment on
  `integration_form.ex:638-642` explains the threat model (CSRF in the
  callback handler) and the historical context (lenient `:ok` was
  justified by a flow that no longer exists). That kind of
  paper-trail-in-code is exactly what makes future audits possible.
- **Composite-PK + content-hash dedup.** `phoenix_kit_cat_pdf_pages`
  having `(file_uuid, page_number)` as PK and a separate
  `content_hash → phoenix_kit_cat_pdf_page_contents` reference is the
  cleanest split for the actual access patterns: page-by-page reads
  (PK lookup) and full-text search (single GIN index over deduped
  content). A naive design with `text` on `_pages` directly would have
  bloated the GIN index by the duplication factor.
- **`on_delete: :restrict` on `phoenix_kit_cat_pdfs.file_uuid`.**
  The right choice — catalogue-side rows are user-visible references
  to a file, and core's prune flow shouldn't be able to delete out
  from under them. The cascading flow runs the other direction: when a
  catalogue user trashes the `phoenix_kit_cat_pdfs` row,
  catalogue-side code can then orphan-GC the file once no other row
  references it.
- **`on_delete: :delete_all` on `_extractions.file_uuid` and
  `_pages.file_uuid`.** Symmetric: extractions and per-page rows are
  cache derived from the file's content; if the file goes, they
  should go too. Two different cascading rules from the same FK target
  is a sign someone thought about the lifecycle, not a smell.
- **Marker comment correctness.** `up/1` writes `'111'`, `down/1`
  writes `'110'` — matches the workspace's review rule. ✓
- **FOLLOW_UP.md format.** "Fixed pre-existing" / "Fixed (Batch 1)" /
  "Skipped" / "Open" headings line up cleanly. The strikethrough
  `~~bullet~~` notation makes it visually obvious which findings have
  been closed without losing the original wording.
- **Bundling rationale.** Each of the three threads (V111, OAuth fix,
  follow-ups) is small enough that splitting would have been
  ceremony-heavy churn. The PR body's framing — "V111 is the headline,
  these three follow-ups close out outstanding review items" — is the
  right shape for the bundle.
