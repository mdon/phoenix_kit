# PR #631 — Prefix hardening for low-privilege multi-schema installs, runtime schema-prefix support + daisyUI modal-gutter fix

**Author:** Max Don (`mdon`) · **Base:** `main` · **Merge:** `9ddd321e` · **Reviewer:** Claude (Sonnet 5)
**Scope:** ~90 files — follow-up to PR #628, driven by a field report from a hardened multi-schema install (DBA-pre-created schema, no database-level CREATE, PG15+ non-writable `public`). Already went through a multi-AI review (Codex/GLM/Kimi) and a "quality sweep" + "quorum review" pass as commits within its own branch history before merging.

Reviewed post-merge against `main`. Given the extensive prior review, this pass focused on what could have slipped through rather than re-litigating already-covered ground — spot-checked ~20 of the ~40 mechanically-edited migration files, read `helpers.ex`/`schema_prefix.ex`/`oban_config.ex`/`common.ex` in full, and traced call sites for the claims in the PR description rather than trusting them.

---

## BUG — MEDIUM (fixed)

- **V26's `digest()` call was unqualified — the exact bug family this PR fixes elsewhere, in a file the PR itself touched.** `v26.ex`'s backfill (`UPDATE ... SET user_file_checksum = encode(digest(...), 'hex')`) calls pgcrypto's `digest/2` unqualified. The PR swapped the `CREATE EXTENSION IF NOT EXISTS pgcrypto` two lines above for `Helpers.ensure_extension!("pgcrypto")`, but left `digest()` itself bare. `helpers.ex`'s own moduledoc explains why this matters: a plpgsql body (and, per this bug, a plain SQL statement too) resolves identifiers via the *calling role's* `search_path`, so pgcrypto installed outside that search_path (exactly the hardened multi-schema scenario this whole PR targets) makes V26 fail with `function digest(...) does not exist`. **Fixed:** added `Helpers.pgcrypto_call/1`, which resolves pgcrypto's actual schema (reusing the same `pg_extension`/`pg_namespace` lookup `ensure_uuid_v7_function/1` already uses) and qualifies the call; V26 now emits `#{Helpers.pgcrypto_call("digest")}(...)`. Same latent class, lower priority and **not fixed** (pre-dates this PR's uuid-specific sweep, not claimed as fixed by it): V01's `citext` column type and V111's `gin_trgm_ops` opclass rely on the identical unqualified search_path resolution for extension-provided names.
- **`ObanConfig.oban_block_missing_prefix?/1` didn't strip comments — reproduced both a false positive and a false negative.** Unlike the sibling `oban_config_exists?/1`, which explicitly skips `#`-prefixed lines, the new block-scoping regex ran against raw file content. A file containing only a commented-out example Oban block (no `prefix:` in the comment) triggered a false "your Oban config lacks this install's prefix" warning; conversely, a commented block that happened to mention `prefix:` followed by a genuinely-unprefixed *active* block made `Enum.all?/2` see one block "with prefix" and suppressed the warning entirely — silently defeating the exact protection the function exists for. **Fixed:** added `strip_comment_lines/1` (same line-based `#`-stripping convention as `oban_config_exists?/1`) and applied it before both the block-scan regex and the `has_block?` detector in `maybe_warn_missing_oban_prefix/2`. Added two regression tests reproducing each direction.

## IMPROVEMENT — MEDIUM (not fixed, recorded)

- **`schema_prefix_test.exs`'s conformance test checks presence, not placement.** It asserts `String.contains?(content, "use PhoenixKit.SchemaPrefix")` — a whole-file substring check with no positional relationship to `use Ecto.Schema` or the `schema "..." do` block. `@schema_prefix` is a module attribute read by Ecto's `schema/2` macro at expansion time, so a future schema declaring `use PhoenixKit.SchemaPrefix` *after* its `schema` block would silently fall back to unprefixed queries while this test still passes. Manually verified all 21 current call sites are correctly placed. Not fixed here — tightening the test to check ordering (not just presence) is a reasonable follow-up but out of scope for this pass.

## Verified correct (no findings)

- **~20 spot-checked mechanically-edited migration files** (V40, V56, V59, V61, V63, V75, V78, V79, V86, V87, V90–95, V100–102, V111, V113, V115, V117, V120, V122–125, V133, V135–138, V140–141): every `uuid_generate_v7()` call site is correctly schema-qualified via `Helpers.uuid_v7_call/1` or an in-scope local equivalent; grepped the whole codebase for leftover bare call sites and found none outside docstrings/comments.
- **`helpers.ex`:** `ensure_uuid_v7_function/1` correctly resolves pgcrypto's actual schema (falling back to `public` only when the extension isn't visible yet, safe given `ensure_extension!` runs immediately beforehand); `ensure_extension!/1` checks `pg_extension` before attempting creation and raises a clear operator-facing message rather than a raw Postgrex error when genuinely blocked.
- **`schema_prefix.ex`:** all 21 table-backed schemas correctly `use PhoenixKit.SchemaPrefix` immediately after `use Ecto.Schema`; unset config compiles to `nil`, byte-identical to the attribute being undeclared.
- **`oban_config.ex` cross-file block-scoping:** a prefix in `runtime.exs` with the base Oban block in `config.exs` is correctly treated as "not missing," matching real `Config.Reader` deep-merge semantics.
- **`install/common.ex` `{:unreachable, reason}` propagation:** traced every call site in `phoenix_kit.status.ex` and `phoenix_kit.update.ex` — nothing pattern-matches only the old two-tuple shapes.
- **V27 `create_schema: false` threading:** verified in code (not just the PR description) across all three generator paths (fresh install, `gen.migration`, `update`).
- **daisyUI scrollbar-gutter removal:** clean across `layout_wrapper.ex`, `root.html.heex`, `phoenix_kit.js` — no dangling references to the removed refcount machinery.

## NITPICK (not fixed)

- `v40.ex` interpolates `#{prefix}.uuid_generate_v7()` directly instead of calling the `Helpers.uuid_v7_call/1` this same PR introduced — functionally identical (V40's `prefix` is never `nil`), just inconsistent with the new helper.
- `PhoenixKit.Install.Common.check_update_needed/2` has no callers anywhere in `lib/` — pre-existing dead code, not introduced by this PR, but its new `{:unreachable, reason}` clause is untested by construction as a result.

## Testing

`mix test test/phoenix_kit/install/oban_config_test.exs test/phoenix_kit/migrations/postgres_helpers_test.exs` — added two regression tests for the comment-stripping fix (commented-only block → no false positive; commented block mentioning `prefix:` masking a real unprefixed block → no false negative); all pass, no PostgreSQL required. `Helpers.pgcrypto_call/1` isn't independently unit-tested — like `ensure_extension!/1` and `ensure_uuid_v7_function/1`, it requires a live migration/repo context, and the existing `prefix_migration_test.exs` oracle doesn't currently install pgcrypto outside the default search_path (which is exactly how this bug shipped unnoticed).

## Gate

`mix compile --warnings-as-errors` clean after the fixes. Full `mix precommit` run alongside PR #630's fixes for the combined release — see the release commit for the gate result.
