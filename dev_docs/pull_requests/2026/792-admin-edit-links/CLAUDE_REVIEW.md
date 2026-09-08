# Claude Review — PR #792

**Title:** Public-page Edit link: documented helper API, component, per-module permission gate
**Author:** timujinne
**Merge commit:** d381f5bd
**Verdict:** Approve, one doc bug fixed post-merge

## Summary

Promotes `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3` to a documented
public API (host/module code declares a public page's admin counterpart) and
adds `PhoenixKitWeb.Components.Core.AdminEditLink.admin_edit_link/1` to render
it — button or `:menu_item` variant, renders nothing when unauthorized/unset.
`label_or_opts` now also accepts a keyword list (`label:`, `permission:`),
gating on `Scope.has_module_access?/2` in addition to the existing
`can_access_admin_area?/1` check, backward compatible with plain-string
callers.

## Findings

### IMPROVEMENT - MEDIUM: moduledoc/guide examples hardcoded an `/admin/...` path instead of routing it through `Routes.path/1` — fixed

`lib/phoenix_kit_web/helpers/admin_edit_helper.ex` (moduledoc) and
`guides/integration.md` ("Edit link on public pages") both showed:

```elixir
AdminEditHelper.assign_admin_edit(socket, "/admin/posts/#{post.id}/edit")
```

`assign_admin_edit/3` assigns whatever `path` it's given verbatim — the
component (`<.link navigate={@url}>`) does no further resolution. But `posts`
is a PhoenixKit tab-only module (`AGENTS.md` → "External Module Route
Discovery"), so `/admin/posts/:id/edit` is a PhoenixKit-routed page, and the
project's own convention (AGENTS.md → "URL Prefix and Navigation": "NEVER
hardcode PhoenixKit paths") requires such paths go through
`PhoenixKit.Utils.Routes.path/1`. Without it, the link silently breaks on any
install with a non-root mount prefix, a locale segment, or (per the recently
documented rename mechanism, see PR #794 below) a renamed `admin_path`
segment — it would point at the literal string `/admin/...` instead of the
resolved location.

Both examples (host LiveView and the `phoenix_kit_publishing` module
controller pattern) hit this, and module authors are expected to copy the
guarded-call pattern verbatim, so the bad example would have propagated.
Fixed by wrapping both example paths in `Routes.path(...)` and adding a note
above the examples explaining when it's needed. The helper's own code needed
no change — it is correctly path-agnostic; resolving the path is the
caller's job, the docs just showed the wrong caller-side pattern.

No caller in this repo invokes `assign_admin_edit/3` yet (it's a new public
API for hosts/modules), so nothing shipped was actually broken — this was
caught before anyone copied the example.
