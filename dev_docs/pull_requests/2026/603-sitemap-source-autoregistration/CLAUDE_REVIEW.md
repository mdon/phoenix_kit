# PR #603: Add `sitemap_sources/0` module callback for source auto-registration

**Author**: @timujinne (Tymofii Shapovalov)
**Reviewer**: @CLAUDE
**Status**: ✅ Merged (post-merge review + fix)
**Commit**: `4ed98f9c` (merge), reviewed against `6e4e929e`
**Date**: 2026-06-24

## Goal

External PhoenixKit modules could not contribute entries to the generated
sitemap: `Generator.get_sources/0` only read a hardcoded `default_sources/0`
list (router discovery, static, publishing, posts, shop) or a host
`config :phoenix_kit, :sitemap, sources:` override. A module shipping its own
`Sitemap.Sources.Source` (e.g. Entities) was invisible unless every host
hand-wired it into config.

The PR adds a zero-config registration path mirroring route / CSS / JS
auto-discovery: a new optional `PhoenixKit.Module` callback `sitemap_sources/0`,
a `ModuleRegistry.all_sitemap_sources/0` aggregator, and an append-and-dedup in
`Generator.get_sources/0`.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/module.ex` | New optional `sitemap_sources/0` callback (default `[]`); added to `@optional_callbacks`, `__using__` defaults, `defoverridable` |
| `lib/phoenix_kit/module_registry.ex` | New `all_sitemap_sources/0` aggregating the callback across registered modules |
| `lib/modules/sitemap/generator.ex` | `get_sources/0` appends module-contributed sources to the base list, order-preserving + deduped |

## Assessment

The design is sound and the integration points are right: the callback wiring
(callback decl + `@optional_callbacks` + `__using__` default + `defoverridable`)
is complete and consistent with the existing `css_sources/0` / `js_sources/0`
pattern. The source representation is consistent — both `default_sources/0` and
`sitemap_sources/0` return **source modules**, so `Enum.uniq/1` deduplicates
correctly across the base + contributed lists. `module_sitemap_sources/0` wraps
the registry call in a `rescue` and the registry uses `safe_call/3`, so a
misbehaving module can't break sitemap generation. The append-after-base ordering
keeps host `config :sitemap, sources:` overrides working (now as a base that
modules extend, which the PR documents).

One real issue: the PR's documented disabled-module guarantee does not hold in
flat-sitemap mode. Fixed. Details below.

## Findings

### BUG - MEDIUM — disabled module's source leaks into the flat sitemap (documented guarantee violated)

Both the `all_sitemap_sources/0` docstring and the `get_sources/0` comment state
that iterating **all** modules (not just enabled ones) is safe because *"whether a
contributed source actually emits is decided at generation time by that source's
own `enabled?/0`"* and *"a source whose module is disabled simply emits nothing."*

That holds in **index mode** only. The generator has two generation paths
(`Generator.do_generate_all/2` → `Sitemap.flat_mode?/0`, which is just
`router_discovery_enabled?/0`):

- **Index mode** (Router Discovery off — the default): `do_generate_index/5` →
  `generate_module/2`, which checks `Source.valid_source?/1 and source_module.enabled?()`
  before collecting. Gated correctly. ✅
- **Flat mode** (Router Discovery on): `do_generate_flat/5` does
  `flat_opts = Keyword.put(opts, :force, true)` and calls `collect_all_entries/2`
  → `collect_single_language_entries/2` / `collect_multilingual_entries/3` →
  `Source.safe_collect/2`. With `force: true`, `safe_collect/2` runs
  `if valid_source?(...) and (force or source_module.enabled?())` — **the
  `enabled?/0` check is bypassed.** ⚠️

The `force: true` bypass is *intentional* for built-in sources (commit
`c853379b`: *"Add force option to Source.safe_collect to bypass enabled? checks /
Generator passes force: true in flat mode to collect from all sources"*) — flat
mode is meant to be a single comprehensive `<urlset>` ignoring the per-source UI
toggles.

But #603 fed a **new** category of sources (external-module-contributed) into
that force-collect path. Net effect: a module that registers `sitemap_sources/0`
but is **disabled** (e.g. Entities turned off) would still have its URLs published
in the sitemap whenever the host runs flat mode — exactly the opposite of what the
PR documents. Publishing a disabled feature's URLs into a public sitemap is an
SEO/exposure problem, and the false guarantee invites callers to over-trust it.

**Fix:** `ModuleRegistry.all_sitemap_sources/0` now iterates `enabled_modules/0`
instead of `all_modules/0`, so a **disabled module contributes no source at all**
— the guarantee holds in both modes. A contributed source's own `enabled?/0`
remains a secondary gate in index mode. The flat-mode force-collect is preserved
for the sources that *are* in the list (the author's deliberate flat-mode
behavior is untouched). Docstrings in `module_registry.ex` and the inline comment
in `generator.ex` were corrected to describe the actual gating.

Why `enabled_modules/0` and not "remove the flat-mode `force`": the `force`
behavior is a deliberate, pre-existing design for built-in sources (see commit
above) and changing it would alter behavior well outside #603's scope. Gating at
the module level is the surgical fix that makes #603's own contract true while
leaving flat mode's force-collect intent intact.

Note this makes module-contributed sources *stricter* than built-in sources in
flat mode (a disabled module emits nothing; a disabled built-in module's source
can still be force-collected — see the observation below). That asymmetry is the
correct direction: a fully-disabled module should never leak URLs.

### OBSERVATION - pre-existing (not fixed) — flat-mode `force` also bypasses built-in sources' `enabled?/0`

The same `force: true` mechanism means the built-in optional sources
(`Posts`, `Publishing`, `Shop`) are force-collected in flat mode even when their
owning module is disabled. This predates #603 (commit `c853379b`, deliberate
"collect from all sources") and is out of scope here, so it is **not** changed.
Flagged so the maintainer can decide whether flat mode should also honor
module-disable for built-in sources, or whether `force` should bypass only the
per-source *UI toggles* and not whole-module-disable. If the latter is desired,
the cleaner long-term fix is to split "source UI toggle" from "module enabled" in
`safe_collect/2` rather than the blunt `force` flag.

### NITPICK — double `Enum.uniq/1`

`all_sitemap_sources/0` dedups its own output, and `get_sources/0` dedups again
after concatenating base + contributed. Harmless (the second dedup is the one that
matters, since it spans both lists); left as-is for readability.

## Testing

- [x] `mix precommit` (compile --warnings-as-errors + credo --strict + dialyzer)
- [ ] No unit test added for the gating change — `all_sitemap_sources/0` reads the
      runtime module registry (`:persistent_term` populated by `ModuleRegistry`),
      and this repo is not standalone-DB-testable (per CLAUDE.md / project memory),
      so the gate is the bar. The fix is a one-token registry change
      (`all_modules` → `enabled_modules`) plus doc corrections.

## Related

- Generation mode switch: `lib/modules/sitemap/sitemap.ex` (`flat_mode?/0` = `router_discovery_enabled?/0`)
- Per-source gate: `lib/modules/sitemap/sources/source.ex` (`safe_collect/2`, `valid_source?/1`)
- Generation paths: `lib/modules/sitemap/generator.ex` (`do_generate_index/5` vs `do_generate_flat/5`)
- Force-collect origin: commit `c853379b` ("Update Router Discovery toggle to act as flat/index sitemap mode switch")
