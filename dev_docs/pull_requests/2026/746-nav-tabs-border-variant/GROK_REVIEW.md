# Grok Review — PR #746 "Add the border variant and make nav_tabs link keys verbatim"

**Merge commit:** 50945127
**Author:** mdon (fix/nav-tabs-border-variant)
**Files:** `lib/phoenix_kit_web/components/core/nav_tabs.ex`, `test/phoenix_kit_web/components/core/nav_tabs_test.exs`

## Summary of the change

Second `nav_tabs` adoption wave. Two contracts the underline-family module
migrations need:

- `variant={:border}` — daisyUI 5's `tabs-border` underline look (the
  convention on show-page and settings strips). Unlike `:boxed` there is
  no frame to shed, so no `bg-base-200 p-1` overrides ride along.
- `:navigate` / `:patch` pass through **verbatim**, matching
  `Phoenix.Component.link/1`. 2.13.5 ran both through `Routes.path/1`,
  which double-prefixed URLs already built by a module's Paths helpers
  (found migrating the CRM show pages). Legacy `:path` still gets the
  helper: its callers predate the link keys and have always passed
  unprefixed paths. The two keys are the same link *kind* with different
  prefix rules — not interchangeable spellings.

Verified against producing code, not the PR text:

- daisyUI 5's third tab style is `tabs-border` (not the v4
  `tabs-bordered`). `:boxed` / `:plain` class strings are unchanged.
- In-repo callers (`billing_tabs`, `jobs/index`, `user_details`,
  `live_sessions`) use `:path` or event tabs — both still work.
- Across the workspace checkouts, the only `:patch` / `:navigate`
  consumer against 2.13.5 is `phoenix_kit_user_connections`, and it
  currently passes unprefixed `/profile/connections?tab=…` values.
  Companion PR #8 rebuilds those with `Routes.path/1`. Until that lands
  after this release, those tabs 404 under a non-root `url_prefix`.
- CRM companion PR #24 (and the rest of the underline wave) passes
  already-prefixed Paths helpers into `:patch` with `variant={:border}`.
  The verbatim change is load-bearing for that wave; applying
  `Routes.path/1` a second time would produce
  `/phoenix_kit/phoenix_kit/…`.

## Findings

### 1. IMPROVEMENT - MEDIUM — the prefix-rule tests did not pin either side of the contract

`:path still means navigate AND still gets the route-helper treatment`
asserted `from_path =~ "/admin/settings"`. That substring is present
whether or not `Routes.path/1` ran (`href="/admin/settings"` and
`href="/phoenix_kit/en/admin/settings"` both match).

`:navigate and :patch pass through verbatim` passed an already-prefixed
`/phoenix_kit/en/admin/…` string and asserted the same href. In this
suite `url_prefix` is `/phoenix_kit` and `prefixless_primary_safe?/0`
fails closed, so re-applying the helper *would* double-prefix and the
assertion would catch it. That is env-coupled: a root-prefix install
makes `Routes.path/1` a no-op on that fixture, and the test would pass
for the 2.13.5 behaviour too.

The load-bearing pin is the pair: the same unprefixed `/admin/…` value
must produce a helper-rewritten href through `:path` and that exact
unprefixed href through `:navigate` / `:patch`. 2.13.5 asserted
`from_path == from_navigate`; this PR deleted that equality (correct)
but did not replace it with the inequality the new contract requires.

**Fixed** in `nav_tabs_test.exs`: `:path` compares href to `Routes.path/1`
(and asserts the helper actually rewrote the string, so the pin is not a
tautology); an unprefixed `:patch` is asserted *not* to equal the helper
output; `:path` and `:navigate` with the same raw value are the same
link kind (`data-phx-link="redirect"`) with different hrefs.

### 2. NITPICK — "a query string survives the route helper intact" no longer exercised the helper

After this PR only `:path` goes through `Routes.path/1`. The test still
passed a `:patch` URL, so it pinned verbatim pass-through under a name
that claimed the helper. A helper regression that dropped `?tab=` would
have been silent.

**Fixed** by splitting: `:path` still asserts the helper keeps the
query; a separate `:patch` case pins the verbatim href.

### 3. NITPICK — `tablist_class/2` extra was untested on `:border`

`:plain` had an `extra` assertion; `:border` only checked the nil-extra
clause. **Fixed** (`tablist_class(:border, "mb-4")`).

## Not fixed / out of scope

- **Breaking change in a patch version.** `:navigate` / `:patch` written
  against 2.13.5 with unprefixed values under-prefix after this release.
  Disclosed in the PR, and there is exactly one such consumer
  (`user_connections` #8). `:path` is unchanged. Documented in the
  2.13.6 CHANGELOG; the companion must merge immediately after publish.
- **No `:lift` variant.** daisyUI 5 also has `tabs-lift`. None of the
  underline-family copies use it; adding it without a caller would be
  speculative.
- **`:path` and `:navigate` remaining dual-key footgun.** Auto-detecting
  "already prefixed" inside `Routes.path/1` would let both keys share
  one rule, but that helper is not idempotent on purpose (a path that
  happens to start with the prefix is not the same as one the helper
  built). The moduledoc now states the two keys are not interchangeable.
  Left as documented.
- **Hand-rolled `tabs-border` still in warehouse / manufacturing /
  catalogue / ecommerce `translation_tabs`.** Deliberately excluded from
  this wave (catalogue has an open PR of its own; ecommerce's strip is a
  language switcher; warehouse/manufacturing were not in the companion
  list). Out of scope.
