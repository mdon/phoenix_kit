# Bug report (for phoenix_kit): `KeyError: key :inner_block not found` on auth pages after 1.7.173

**Status:** unresolved, reported upstream. Host app (langust) currently pinned to
phoenix_kit `1.7.172` in `mix.lock`; `/users/log-in`, `/users/register`,
`/users/reset-password` are **broken (500)** even on that pinned version — see
"Why this isn't just a downgrade" below.

## Summary

After running `mix deps.update phoenix_kit` (`1.7.172` → `1.7.173`), every
PhoenixKit-rendered page that goes through our custom host `layout:` config
started crashing with:

```
** (KeyError) key :inner_block not found in: %{...}
```

raised inside **our own** host layout function
(`LangustWeb.Layouts.frontend/1`, at `{render_slot(@inner_block)}`) — not
inside phoenix_kit itself. Our own app's LiveViews (which call
`<Layouts.frontend>...</Layouts.frontend>` directly via normal HEEx component
syntax) are completely unaffected; only phoenix_kit's own auth LiveViews
(`PhoenixKitWeb.Users.Login`, `Registration`, `ForgotPassword`), which reach
our layout via `PhoenixKit.Config.get(:layout)` → `apply(module, function,
[assigns])`, are affected.

**Reproducibility: 100% (6/6 identical requests fail identically — not a race
condition).**

## Why this isn't just a version-pin issue

We rolled `phoenix_kit` back to `1.7.172` (`mix.lock` hash
`88d0f3d1b02fd7b8a131672c6b2049011e0018087f8613f7d306800b426f0eac` — the
*exact* version + checksum that was confirmed working earlier the same
session, before the update). The crash **persists** on that exact version. We
ruled out every "it's just stale state" explanation we could think of:

- **Stale build artifacts** — ruled out. Wiped `_build/dev` entirely, `mix
  deps.compile` + `mix compile` from scratch.
- **Version mismatch between phoenix_kit and its sibling packages** — ruled
  out. `phoenix_kit_ai`, `phoenix_kit_entities`, `phoenix_kit_publishing`,
  `phoenix_kit_emails`, `phoenix_kit_newsletters`, `phoenix_kit_referrals` were
  all force-recompiled together against the reverted `phoenix_kit`.
- **Database/settings drift** — ruled out. Checked `schema_migrations` (no
  migration ran in the relevant window) and `phoenix_kit_settings.date_updated`
  (nothing updated in the last 2 hours at the time of investigation).
- **Multiple/zombie BEAM nodes** — ruled out. `ps aux` showed exactly one
  `beam.smp` process; `epmd -names` showed exactly one registered node,
  matching the latest restart's PID.
- **Flakiness/concurrency** — ruled out. 6 back-to-back identical requests all
  failed identically.
- **Pristine dependency source** — confirmed. `rm -rf deps/phoenix_kit && mix
  deps.get` re-fetched the package fresh from Hex; `hex_metadata.config`
  confirms `1.7.172`; `CHANGELOG.md`'s top entry is `1.7.172`.

So: identical code, identical dependency (freshly re-fetched, not just
"marked" as 1.7.172), identical database, single clean process — still
crashes. Something got left in a different state that a code-level revert
doesn't undo, or upgrading briefly to 1.7.173 exposed a **pre-existing**
fragility that was latent before and is now consistently triggered.

## What we found via temporary tracing (added to `deps/phoenix_kit`, reverted after)

We added `Logger.error` trace lines at the top of:
- `PhoenixKitWeb.Components.AuthPageWrapper.auth_page_wrapper/1`
- `PhoenixKitWeb.Components.LayoutWrapper.app_layout/1`
- `PhoenixKitWeb.Components.LayoutWrapper.normalize_content_assigns/1` (private)
- `PhoenixKitWeb.Components.LayoutWrapper.render_with_parent_layout/3` (private)
- `PhoenixKitWeb.Components.LayoutWrapper.render_modern_parent_layout/3` (private,
  right before `apply(module, function, [assigns])`)

**None of these fired for a real, failing `curl http://localhost:4000/en/users/log-in`
request** — yet the crash still happened inside `LangustWeb.Layouts.frontend/1`,
which is only ever reached (in our codebase) via that exact call chain. This is
the most important, and most confusing, finding: **the real failing request
does not appear to go through the code path the source implies it does.**

For contrast, when we called the same functions **manually** in an isolated
`project_eval` session (hand-constructed assigns simulating a real request,
including a genuine slot and a `%Phoenix.LiveView.Rendered{}` for
`inner_content`), the *entire* chain — `auth_page_wrapper` → `app_layout` →
`normalize_content_assigns` → `render_with_parent_layout` →
`render_modern_parent_layout` → our `frontend/1` — executed successfully with
no error, and the trace lines all fired exactly as expected. So the mechanism
is provably correct in isolation; something about how it's invoked for a real
LiveView-mounted request over HTTP differs from that.

## Full stack trace (representative — same shape for Login/Registration/ForgotPassword)

```
** (KeyError) key :inner_block not found in: %{...}
    (langust 0.1.0) lib/langust_web/components/layouts.ex:195: anonymous fn/2 in LangustWeb.Layouts."frontend (overridable 1)"/1
    (phoenix_live_view 1.2.5) lib/phoenix_live_view/diff.ex:457: Phoenix.LiveView.Diff.traverse/6
    (phoenix_live_view 1.2.5) lib/phoenix_live_view/diff.ex:162: Phoenix.LiveView.Diff.render/4
    (phoenix_live_view 1.2.5) lib/phoenix_live_view/static.ex:291: Phoenix.LiveView.Static.to_rendered_content_tag/4
    (phoenix_live_view 1.2.5) lib/phoenix_live_view/static.ex:171: Phoenix.LiveView.Static.do_render/4
    (phoenix_live_view 1.2.5) lib/phoenix_live_view/controller.ex:39: Phoenix.LiveView.Controller.live_render/3
    (phoenix 1.8.8) lib/phoenix/router.ex:416: Phoenix.Router.__call__/5
    (langust 0.1.0) lib/langust_web/endpoint.ex:1: LangustWeb.Endpoint.plug_builder_call/2
    ...
```

The dumped assigns (redacted for length) at the crash site include, among
others: `socket` (a real `%Phoenix.LiveView.Socket{view: PhoenixKitWeb.Users.Login, ...}`),
`form`, `inner_content: %Phoenix.LiveView.Rendered{static: [...PhoenixKitWeb.Users.Login.render...], dynamic: #Function<.../1 in PhoenixKitWeb.Users.Login.render/1>, ...}`,
`phoenix_kit_current_scope`, `current_locale: "en-US"`, `logo`, `icon`, `nav`
(our own layout's fallback-computed nav, present and correct), `current_scope`
— i.e. **our own layout code (added this session, unrelated to this bug) ran
fine up to the point of `render_slot(@inner_block)`**. `inner_content` is
present; `inner_block` is not, at the point our template tries to use it.

## Host app config (for context)

```elixir
# config/config.exs
config :phoenix_kit,
  parent_app_name: :langust,
  parent_module: Langust,
  url_prefix: "",
  repo: Langust.Repo,
  mailer: Langust.Mailer,
  layouts_module: LangustWeb.Layouts,
  layout: {LangustWeb.Layouts, :frontend},
  phoenix_version_strategy: :modern,
  modules: [Langust.Vocabulary.Admin, Langust.Learning.Admin]
```

`LangustWeb.Layouts.frontend/1` is **not** the generator-default `:app` layout
— it's a sidebar-drawer shell (desktop rail + mobile overlay + header +
footer) wrapping the whole site, `slot :inner_block, required: true`, `attr
:nav, :list, default: []` among others. This is a fairly typical "real app"
host layout shape (not a bare header), for context in case the fragility is
specific to layouts with more structure than the generator default.

## Reproduction steps

1. Host app with `config :phoenix_kit, layout: {SomeHostWeb.Layouts, :some_function}`
   pointing at a non-trivial layout (sidebar shell, not the bare `:app` default).
2. `mix deps.update phoenix_kit` from `1.7.172` to `1.7.173`.
3. Visit `/users/log-in` (or `/users/register`, `/users/reset-password`) — 500,
   `KeyError: key :inner_block not found`, raised inside the host layout
   function at its `render_slot(@inner_block)` call.
4. Revert to `1.7.172` (matching lock hash) — crash persists.
5. Full clean rebuild of all deps + host app — crash persists.

## What would help us most

- Does anything in the `1.7.173` changelog touch `layout_wrapper.ex`,
  `auth_page_wrapper.ex`, or how `inner_content`/`inner_block` get threaded
  through `PhoenixKitWeb.Users.Login`/`Registration`/`ForgotPassword`? The
  published changelog for `1.7.173` we could see only mentioned: DaisyUI theme
  i18n, the new `user_dashboard_nav.ex` `authenticated_links` attr, a
  dependency bump, a V80 migration fix, and French i18n — nothing that
  obviously touches this path, which is itself part of why this was so hard to
  pin down from our side.
- Is there a known interaction between `PhoenixKit.Config.get(:layout)` and a
  host layout with more than a bare header (e.g. one requiring `nav`/sidebar
  state) that we should be aware of?
- Any chance a previous `1.7.173` boot (even briefly) writes something
  persistent (DB row, cached compiled template, etc.) that isn't undone by
  reverting the dependency version? We checked `phoenix_kit_settings` and
  `schema_migrations` and found nothing, but we don't have full visibility
  into phoenix_kit's internals.

Happy to run anything you'd like us to test against this exact host app/config
— it's fully reproducible on our end.
