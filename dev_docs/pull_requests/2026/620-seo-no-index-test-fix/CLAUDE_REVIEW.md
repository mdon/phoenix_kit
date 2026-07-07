# PR #620 — Fix broken seo_no_index regression test from #616

**Author:** timujinne (`timujinne/main`) · **Merge:** `0d458624` · **Reviewer:** Claude

## Summary

Three files, +69/−21. The regression test added with #616
(`test/phoenix_kit_web/users/auth_seo_no_index_test.exs`) raised during mount
and broke `mix test`: its inline `PublicHostAppLive` mounted through
`:phoenix_kit_mount_current_scope`, whose `:current_page` `handle_params` hook
calls `attach_hook/4` — which requires a non-nil `socket.router`.
`live_isolated/3` never sets one, so both cases errored out unconditionally
before their assertions, independent of the DB.

Fix:
- Moves `PublicHostAppLive` out of the `.exs` (a `defmodule` nested in a test
  file only exists at test-runtime, so a compiled router can't reference it)
  into a real compiled module `PhoenixKitWeb.Test.PublicHostAppLive` at
  `test/support/public_host_app_live.ex`.
- Adds a `Mix.env() == :test`-gated `live "/__test/seo-no-index-probe", …`
  route in `PhoenixKitWeb.Router` (the library's dev/test-only router).
- Rewrites the test to drive the view via a real HTTP `GET` (so `socket.router`
  is set and the hook attaches) and to assert against the actual
  disconnected/initial HTML — the `<meta name="robots" …>` / `googlebot` tags a
  crawler would see — rather than the raw `:seo_no_index` assign.

**Verdict: correct, and a genuine improvement over the original test.** No
blocking findings. One acknowledged latent trade-off (below), which I agree
should not be "fixed."

## Verification

- **The test now exercises the real #616 path, not just the assign.** GET
  `/__test/seo-no-index-probe` → `:browser` pipeline (`put_root_layout`) →
  `PublicHostAppLive` mounts via `:phoenix_kit_mount_current_scope` →
  `mount_phoenix_kit_current_user/2` attaches `:current_page` on
  `:handle_params` → `set_routing_info/3` does
  `assign_new(:seo_no_index, fn -> SEO.no_index_enabled?() end)` → `root.html.heex`'s
  `<%= if assigns[:seo_no_index] do %>` emits the meta. `handle_params` runs on
  the disconnected render too, so the assign is present before the first render.
  This is exactly the host-app-public-LiveView path #616 fixed. ✓
- **The assertion strings actually match the rendered output.** `root.html.heex`
  writes `<meta name="robots" content="noindex,nofollow" />` (self-closing in
  source), but the test asserts the substring `…noindex,nofollow">` (no slash).
  I rendered the snippet through HEEx (phoenix_live_view `~> 1.1`) directly:
  void elements serialize **without** the trailing slash —
  `<meta name="robots" content="noindex,nofollow">` — so both `assert`/`refute`
  substrings match. (This was the one place the never-locally-run test could
  have silently been wrong; it isn't.) ✓
- **The moved module compiles in this repo.** `elixirc_paths(:test)` is
  `["lib", "test/support"]`, so `PhoenixKitWeb.Test.PublicHostAppLive` is
  compiled in `:test`; the test-gated route resolves to a real module here. ✓
- **No anonymous redirect.** `on_mount(:phoenix_kit_mount_current_scope, …)`
  only assigns scope + attaches the locale hook and returns `{:cont, socket}`
  (no auth gate — that's `:phoenix_kit_ensure_authenticated_scope`), so the
  anonymous `GET` returns 200 and `html_response(200)` holds. ✓
- **No route shadowing in core.** The probe route is declared after
  `phoenix_kit_routes()`; the only known catch-all that could swallow a 2-segment
  path (`publishing`'s `/:language/:group/*path`) lives in the separate
  `phoenix_kit_publishing` package, which core does not depend on, so it is not
  in this router. ✓
- **Test-env compile clean** (warnings-as-errors) — validates the router block
  and `test/support` module in the env where they are active (my earlier
  `mix precommit` compiles under `:dev`, where the block is excluded). ✓

## Findings

### IMPROVEMENT — LOW (acknowledged; no change recommended)

The `Mix.env() == :test` router block is a **latent dead reference in consumer
test builds.** `Mix.env()` in a dependency reflects the *consumer's* build env,
so when a host app runs `mix test`, PhoenixKit's router compiles this block —
but the Hex package doesn't ship `test/`, so `PhoenixKitWeb.Test.PublicHostAppLive`
is absent there.

Not a build failure: Phoenix's `live` macro only stores the module as an atom
and resolves it at request time (no compile-time reference to the module), and
`PhoenixKitWeb.Router` is never mounted by parent apps (they use
`phoenix_kit_routes()` in their own router), so the route is unreachable dead
code in an unused module.

The author documented this inline and I concur. The clean alternatives are both
worse here:
- A dedicated test-only `Endpoint`+`Router` under `test/support/` — real
  scaffolding for a single probe route (author's own assessment; agreed).
- Guarding on `Code.ensure_loaded?(PhoenixKitWeb.Test.PublicHostAppLive)` instead
  of `Mix.env()` — **unsafe**: it would run at router compile time against a
  same-app module whose beam may not be compiled yet (compilation order isn't
  guaranteed without a dependency edge), so it could spuriously exclude the route
  in this repo's own `:test` env and re-break the test.

So `Mix.env() == :test` is the pragmatic choice. Recording the trade-off so the
"inert" claim is on the record; **no code change.**

## Fixes applied

None — the PR is correct as merged.
