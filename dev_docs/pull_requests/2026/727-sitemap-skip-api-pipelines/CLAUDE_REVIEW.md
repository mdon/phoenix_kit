# PR #727 — Skip JSON-pipeline routes in sitemap router discovery

Merge commit: `774b1c4e` (diff `578e1590`) · Author: timujinne · Reviewed by: Claude

Files in scope: `lib/modules/sitemap/sources/router_discovery.ex`,
`test/integration/sitemap/router_discovery_api_pipeline_test.exs`.

## Summary

Router-discovery previously only excluded API routes by path pattern (`^/api`),
missing JSON pipelines mounted elsewhere — a module's own API prefix
(`:phoenix_kit_api`, e.g. `/sync/api/status`) or a host's infrastructure endpoint
outside `/api` entirely (Caddy on-demand-TLS's `:api` pipe at `/caddy/ask`). This PR
adds a pipeline-based check (`@default_non_page_pipelines`, checked via
`has_non_page_pipeline?/1`) alongside the existing path-pattern and protected-pipeline
checks, folded into the single existing `route_info` lookup so no extra call is added.

## Review

This is exactly the shape the review process flags as high-risk — a PR narrowing (or
here, adding) a rule based on a fixed pipeline-name list, which needs cross-checking
against the actual pipelines declared across the codebase, not just the two cases in
the commit message. Verified:

- `:phoenix_kit_api` is genuinely declared in `lib/phoenix_kit_web/integration.ex:223,308`
  — not a guessed name.
- `:api` is not defined anywhere in this repo; it's the host/Caddy-side convention
  named in the PR description — same "conventional name" risk profile the existing
  `@default_protected_pipelines` list already accepts (`:admin`, `:authenticated`,
  etc. are conventions too, not enforced names).
- The new check composes into the existing single `route_info` call
  (`excluded_by_route_info?/1`), no duplicate lookup introduced.
- The test builds a real `Phoenix.Router` with `:browser`, `:api` (→ `/caddy/ask`),
  and `:phoenix_kit_api` (→ `/sync/api/status`) pipelines and asserts only `/about`
  survives — exercises both real-world cases from the commit message, plus a
  positive-inclusion regression guard.

No regression to the pre-existing path-pattern `^/api` exclusion — the two checks
run independently.

## Findings

**IMPROVEMENT - MEDIUM** — `router_discovery.ex:172-175` (`@default_non_page_pipelines`).
Unlike `@default_protected_pipelines`, which is extendable per-install via the
`sitemap_protected_pipelines` setting, the new non-page-pipeline list is a fixed
`[:api, :phoenix_kit_api]` with no settings equivalent. The PR's own motivating cases
were two *different* real-world pipeline names found in production; a third-party
module or host naming its JSON pipeline something else (`:rest_api`, `:json_api`,
...) will still leak into the sitemap — the same bug class this PR fixes, just for a
name outside the hardcoded pair.

**Not fixed.** This is a design choice, not a defect introduced by the PR — the two
known real leaks are covered, and adding a mirrored `sitemap_non_page_pipelines`
setting (plus settings-UI wiring, matching `protected_pipelines_text/0` and the
`save_protected_pipelines` event in `web/settings.ex`) is a small feature addition
beyond what a review-and-fix pass should introduce unprompted. Recording it here so
a future PR can extend it the same way `sitemap_protected_pipelines` was extended,
if a third pipeline name turns up in the field.

## Verdict

No bugs found. Correct, well-tested. No fix applied.
