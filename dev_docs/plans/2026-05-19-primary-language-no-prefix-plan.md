# Primary-Language-No-Prefix — Plan & Open Items

**Created:** 2026-05-19
**Status:** Core behaviour shipped in PR #551 (v1.7.x). Open items below.
**Scope:** phoenix_kit core — `lib/phoenix_kit/utils/routes.ex`,
`lib/phoenix_kit_web/users/auth.ex`, `lib/phoenix_kit_web/integration.ex`.

---

## Context

PhoenixKit's locale model has two tiers (see
`PhoenixKit.Modules.Languages.DialectMapper`):

- **Base codes** in URLs (`/en/`, `/de/`) — user-facing, SEO-friendly.
- **Dialect codes** internally for Gettext (`en-US`, `de-DE`).

PR #551 made the URL the single source of truth for locale and made the
**primary language prefixless**: the default-locale segment is dropped
from every emitted URL, admin and non-admin alike.

What shipped in #551:

- `Routes.path/2` and `Routes.admin_path/2` emit prefixless URLs for the
  primary language; non-primary locales keep their `/:locale` segment.
- The router emits **both** shapes for admin — `/<prefix>/admin/*` AND
  `/<prefix>/:locale/admin/*` — so a prefixed legacy link still resolves.
- Session-stored locale (`phoenix_kit_locale_base`) was removed. It
  caused a sticky-locale bug: visiting `/foo/et/...` once stashed `"et"`
  and every later prefixless URL inherited Estonian.
- `user.custom_fields["preferred_locale"]` is no longer read for routing
  (base or dialect). The HTTP plug and the LV mount now agree: pure
  URL → default. The field is still **written** by the locale switcher
  so the data survives for a future opt-in feature.

Follow-up cleanup (post-#551): `DialectMapper.resolve_dialect/2`
collapsed to `resolve_dialect/1` (the user-aware arity was dead and an
active foot-gun); dead `User.preferred_locale_changeset/2` and
`User.get_preferred_locale/1` removed.

---

## TODO 1 — Unify the admin `live_session`s so locale switching stays on the WebSocket

### Problem

Admin routes are emitted by `phoenix_kit_admin_routes(suffix)` in
`integration.ex`, which wraps its `live` routes in
`live_session :"phoenix_kit_admin#{suffix}"`. The macro is invoked
twice:

- `phoenix_kit_admin_routes(:_locale)` — inside the `/<prefix>/:locale`
  scope → `live_session :phoenix_kit_admin_locale`.
- `phoenix_kit_admin_routes(:"")` — inside the `/<prefix>` scope →
  `live_session :phoenix_kit_admin`.

`live_redirect` / `push_navigate` only stay on the WebSocket **within
one `live_session`**. Navigating between the prefixless primary shape
(`/<prefix>/admin/*`, session `:phoenix_kit_admin`) and a non-primary
shape (`/<prefix>/de/admin/*`, session `:phoenix_kit_admin_locale`)
crosses the boundary and forces a full-page reload.

Today this is partly masked: the locale switcher
(`handle_locale_event/3` in `auth.ex`) uses `Phoenix.LiveView.redirect/2`,
which is a hard navigation regardless of `live_session`. So the reload
on locale switch is currently *by design* — but it also means there is
no path to a WebSocket-preserving locale switch until the sessions are
unified.

### Goal

One `live_session :phoenix_kit_admin` that contains **both** URL shapes,
so an in-admin locale switch can use `push_navigate` and stay live.

### Plan

1. **Extract the admin `live` routes into one reusable quoted
   fragment.** Today they are inline in `phoenix_kit_admin_routes/1`.
   Factor them into a private helper (e.g. `admin_live_routes(suffix)`)
   returning a `quote` block. The per-suffix pieces
   (`compile_custom_admin_routes/1`, `compile_plugin_admin_routes/1`,
   `compile_external_admin_routes/1`, `safe_route_call` for shop /
   referrals) must still be threaded by `suffix`.

2. **Emit one `live_session` wrapping two scopes.** Replace the two
   `phoenix_kit_admin_routes/1` calls with a single block:

   ```elixir
   live_session :phoenix_kit_admin,
     on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
     scope "#{url_prefix}/:locale", PhoenixKitWeb,
       locale: ~r/^(#{pattern})$/ do
       pipe_through [admin pipeline]
       unquote(admin_live_routes(:_locale))
     end

     scope "#{url_prefix}", PhoenixKitWeb do
       pipe_through [admin pipeline]
       unquote(admin_live_routes(:""))
     end
   end
   ```

   Admin routes currently piggyback the **public** scope's
   `pipe_through`. Pulling them into their own scope means giving them
   an explicit pipeline — confirm whether `:phoenix_kit_admin_only`
   belongs in `pipe_through` or whether the `:phoenix_kit_ensure_admin`
   `on_mount` is the sole gate (it is the gate for LV; the HTTP-side
   plug auth still needs a pipeline).

3. **Switch the in-admin locale switch to `push_navigate`.** In
   `handle_locale_event/3`, when the target URL is an admin path, use
   `Phoenix.LiveView.push_navigate/2` instead of `redirect/2`. Non-admin
   paths still cross the public live_session split — leave them on
   `redirect/2` (or unify the public sessions as a TODO 2).

4. **Route ordering.** The publishing catch-all
   (`/:language/:group/*path`, see `integration.ex` →
   `compile_publishing_routing/1`) matches every 2+ segment URL. The
   unified admin `live_session` must still be emitted **before** the
   publishing routes so `/de/admin/*` is not swallowed. Verify with
   `mix phx.routes` in a parent app.

### Verification (requires a parent app — not standalone-testable)

- `mix phx.routes` shows every admin path under one `live_session`.
- Manual: from `/<prefix>/admin/users` switch locale to `de` → URL
  becomes `/<prefix>/de/admin/users` with **no** full-page reload
  (Network tab shows a LiveView patch, not a document request).
- Legacy `/<prefix>/en/admin/users` still resolves.
- Publishing routes (`/:language/:group/*path`) still resolve.

### Risks

- Core router-macro surgery in a published library; route resolution
  cannot be unit-tested here (`mix precommit` is the bar; integration
  routing needs a host app).
- The per-suffix `compile_*` / `safe_route_call` helpers must keep
  firing for both shapes inside the single `live_session`.
- Interaction with the publishing dispatch shim (`call/2` override).

This warrants its **own focused PR** with parent-app verification —
do not bundle it with unrelated changes.

---

## TODO 2 — (optional) Unify the public `live_session`s

The same split exists for non-admin routes
(`:phoenix_kit_public_locale` vs `:phoenix_kit_public`). Unifying them
would let the front-end locale switcher also stay on the WebSocket.
Lower priority than TODO 1 — front-end locale switches are rarer and
the prefixless-primary redirect already lands users on a clean URL.
