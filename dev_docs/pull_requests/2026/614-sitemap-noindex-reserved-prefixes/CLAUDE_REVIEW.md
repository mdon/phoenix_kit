# PR #614 — Fix sitemap silent-disable, honor SEO noindex, add reserved-route-prefix callback

**Author:** timujinne (`main`) · **Merge:** `92242760` · **Reviewer:** Claude

## Summary

Three logically separate fixes bundled in one PR (7 files, +324/−24):

1. **SEO `noindex` → empty sitemap.** `SEO.update_no_index/1` now invalidates and
   regenerates the sitemap after every toggle (rescued, best-effort —
   `Generator.invalidate_and_regenerate/0` failing can never break the settings
   write). `Generator.do_generate_all/2` and `generate_html/1` both short-circuit
   to an empty-but-schema-valid `<urlset>` when `SEO.no_index_enabled?/0` is true,
   for both flat and index modes, and delete stale per-module files.
2. **`RouterDiscovery` pattern hygiene.** Exclude/include-only patterns are
   regexes, not globs; a bare `"*"` used to fail `Regex.compile/1` and be
   silently swallowed (contributing neither an exclude nor an include match).
   Patterns are now pre-compiled once per `collect/1` call (was: recompiled per
   route per pattern) and invalid patterns are logged instead of silently
   dropped.
3. **`reserved_route_prefixes/0` module callback.** New optional
   `PhoenixKit.Module` callback + `ModuleRegistry.all_reserved_route_prefixes/0`
   aggregator, for a future dispatcher (e.g. Publishing's `/:language/:group/*path`
   catch-all, which lives in a separate `phoenix_kit_publishing` package) to avoid
   swallowing a route another module owns.

**Verdict: correct, safe to release.** One documentation-worthy observation, not
a bug — recorded below, not fixed.

## Verification

### noindex → empty sitemap

- `do_generate_no_index/2` builds `build_urlset_xml([], xsl_style, xsl_enabled)`
  — verified this produces a schema-valid empty `<urlset>` (the XML declaration,
  optional XSL line, and open/close tags don't depend on `entries`). ✓
- `seo_no_index?/0` wraps `SEO.no_index_enabled?/0` in a `rescue` — consistent
  with the "never let sitemap generation break on an SEO lookup error" framing
  in the module doc. ✓
- `generate_html/1`'s noindex branch calls
  `HtmlGenerator.generate(opts, [], :"html_#{style}", cache: false)` — matches
  `HtmlGenerator.generate/4`'s actual arity and re-derives `style` from the same
  `opts`, so the cache key and the rendered style stay consistent. ✓
- `Generator.invalidate_and_regenerate/0` is `Cache.invalidate/0` +
  `SchedulerWorker.regenerate_now/0`, and `regenerate_now/0` inserts an **async**
  Oban job — `SEO.update_no_index/1` does not block on a full sitemap rebuild,
  and there's no synchronous re-entrancy risk from `SEO` ↔ `Generator`'s mutual
  runtime dependency (both are plain function calls, not compile-time/macro
  dependencies, so no cycle). ✓
- `FileStorage.delete_all_modules/0` (pre-existing, unchanged) already rescues
  its own `File` errors, matching the "best-effort" framing. ✓

### RouterDiscovery pattern compilation

- `compile_patterns/2` is called once in `do_collect/1` and the compiled regex
  lists are threaded through `valid_for_sitemap?/3` → `excluded?/2` /
  `included?/2` — confirmed no call site still calls `Regex.compile/1` per-path.
  This is a genuine perf improvement (was O(routes × patterns) compiles, now
  O(patterns)). ✓
- Behavior for an all-invalid include-only list is unchanged (still "exclude
  everything") — old code's `Enum.any?` over uncompilable patterns also
  evaluated to `false` for every path; the new `{:whitelist, []}` after
  filtering produces the same result. The only behavioral delta is the added
  `Logger.warning` diagnostic. ✓

### `reserved_route_prefixes/0`

- `ModuleRegistry.all_reserved_route_prefixes/0` reuses the existing
  `safe_call/3` helper (handles missing/erroring callback, defaults to `[]`),
  and defensively `List.wrap/1` + `Enum.filter(&is_binary/1)`s the result before
  trimming slashes — matches the test suite's nil/mixed-type/slash coverage. ✓
- Correctly iterates `all_modules/0`, not `enabled_modules/0` — the module doc's
  stated rationale (the guarded route is compiled into the host router
  independent of the owning module's runtime enabled/disabled toggle) is sound:
  gating on `enabled_modules/0` would reopen the hijack the moment the owning
  module is disabled while its route/data still exist. ✓
- **Observation (not a bug):** `rg`-searching this repo confirms the callback
  and aggregator are not consumed anywhere yet — no dispatcher calls
  `all_reserved_route_prefixes/0`, and no module implements
  `reserved_route_prefixes/0` besides the test's fake modules. This is
  consistent with `AGENTS.md`'s existing "Publishing Routing Strategy" note that
  the actual consumer (`PhoenixKitPublishing.RouterDispatch`) lives in a
  separate package — wiring it up is out-of-repo follow-up work, not something
  this PR was scoped to do. The module doc is explicit about this
  ("Declaring a prefix is passive — it changes nothing unless a dispatcher
  actively consults this function"), so this isn't a misleading claim, just
  worth flagging for whoever picks up the Publishing side.

## Gate

Covered by the combined `mix precommit` run for this release batch (PRs
#613–#616); result recorded in the release commit/notes.
