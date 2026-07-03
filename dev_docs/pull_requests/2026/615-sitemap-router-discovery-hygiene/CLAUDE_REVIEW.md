# PR #615 — Prevent RouterDiscovery from masking richer sitemap entries and leaking internal routes

**Author:** timujinne (`fix/sitemap-router-discovery-hygiene`) · **Merge:** `4e7fd276` · **Reviewer:** Claude

## Summary

Two files, +205/−2, plus a 165-line regression test.

1. **`loc`-collision dedup fix.** `RouterDiscovery` blindly enumerates every GET
   route, so when a content source (Publishing, Entities, …) emits a richer
   entry (priority, `canonical_path`, hreflang `alternates`) for the same URL, the
   old `Enum.uniq_by(& &1.loc)` kept whichever entry happened to be listed first
   in `default_sources/0` — always `RouterDiscovery`, since it's first in that
   list — silently dropping the richer metadata. Replaced with `dedupe_by_loc/1`,
   which groups by `loc` and picks the entry with the highest `entry_richness/1`
   score; `RouterDiscovery` entries always score `0` and so always lose to any
   other source.
2. **Two more default excludes.** `^/__` (internal/technical routes, e.g.
   Publishing's `/__phoenix_kit_publishing_dispatch` catch-all scope) and
   `^/maintenance$` (PhoenixKit's reserved maintenance page).

**Verdict: correct, safe to release.** No findings.

## Verification

### `dedupe_by_loc/1` / `entry_richness/1`

- `entry_richness(%UrlEntry{source: :router_discovery})` is a distinct clause
  scoring `0`, matched before the generic clause — confirmed `router_discovery.ex`
  sets `source: :router_discovery` on every entry it builds, so this clause is
  reachable and exhaustive for that source. ✓
- For non-`RouterDiscovery` entries: `1 + canonical_bonus + alternates_bonus +
  priority`, where the two bonuses are 0/2 and `priority` (0.0–1.0 in every
  real source: checked `static.ex`, `shop.ex`, `publishing.ex`, `posts.ex` — all
  emit floats) acts as a same-tier tiebreaker. Traced through both new test
  scenarios (RouterDiscovery vs. a richer content source; two non-RouterDiscovery
  entries where only one carries `canonical_path`) and the scoring produces the
  asserted winner in each. ✓
- `Enum.group_by(& &1.loc)` preserves each group's original relative order, so a
  genuine tie (two entries, identical richness) falls back to source-list order
  — an acceptable, documented edge case, not a regression from the prior
  behavior (which was source-order-dependent for *every* collision, not just
  ties). ✓
- Both call sites (`collect_single_language_entries/2`,
  `collect_multilingual_entries/3`) were updated — verified no remaining
  `Enum.uniq_by(& &1.loc)` in the file. ✓

### New default excludes

- `/maintenance` is mounted at `scope unquote(url_prefix) ... live "/maintenance"`
  in `integration.ex` — under the default `url_prefix` (`/phoenix_kit`) it's
  already covered by the pre-existing `^/phoenix_kit` exclude, but a host that
  configures `url_prefix: ""` mounts it at bare `/maintenance`, which only the
  new `^/maintenance$` pattern catches. Correct hardening for that
  configuration, not a no-op. ✓
- Same reasoning for `^/__`: Publishing's internal dispatch scope is
  `/<url_prefix>/__phoenix_kit_publishing_dispatch`, redundant with
  `^/phoenix_kit` at the default prefix but load-bearing at `url_prefix: ""`. ✓
- Both patterns are additive to `@default_exclude_patterns` and don't touch
  `get_exclude_patterns/0`'s merge-with-configured-patterns logic. ✓

## Gate

Covered by the combined `mix precommit` run for this release batch (PRs
#613–#616); result recorded in the release commit/notes.
