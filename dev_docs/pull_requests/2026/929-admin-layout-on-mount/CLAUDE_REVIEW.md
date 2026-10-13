# PR #929 — `:phoenix_kit_admin_layout` on_mount hook (layout without the admin gate)

**Author:** timujinne · **Merged:** 2026-10-13 (a46d67e74) · **Reviewer:** Claude · **Released in:** unreleased

## Summary

New fail-open on_mount hook: mounts the scope and, for a scope that can reach the admin area AND passes `account_gate/1`,
reuses `prepare_admin_mount/3` with `force_layout?` to put any view in `{PhoenixKitWeb.Layouts, :admin}`. Everyone else mounts
untouched (`{:cont, _}` on every path). Documented loudly as authorizing nothing, with the pairing recipe
(`{:phoenix_kit_require, {:module, key}}` declared after it).

Verdict: correct; the "fail-open" contract is stated in the hook docs, the guide and the code comment.

## Checked

- Never redirects or 403s, so it cannot be mistaken for a gate by its behaviour; an unconfirmed admin gets the bare view (no nav ahead of the confirmation page).
- Reuses the one admin-mount assembler, so it cannot drift from `:phoenix_kit_ensure_admin` (locale hook, module-events subscription).
- Maintenance mode: a non-admin keeps the maintenance layout (hook leaves it alone); an admin bypasses it — matches the docs.
- `maybe_apply_plugin_layout/2` doc references updated (`/1` → `/2`, `prepare_admin_mount/3`).
