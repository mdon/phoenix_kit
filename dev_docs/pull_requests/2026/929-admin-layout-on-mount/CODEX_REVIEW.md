# PR #929 — opt-in admin layout hook

Reviewer: Codex · Date: 2026-10-13 · Status: reviewed and fixed, unreleased

## Findings

- **BUG - MEDIUM (fixed): all four new LiveView integration tests requested an absent route.**
  `AdminLayoutProbeLive` and its tests were added, but the test router lacked
  `/phoenix_kit/admin/__test/admin-layout-probe`. The full PostgreSQL-backed suite
  returned 404 for every case. Added the route inside the existing test-only
  scope; the actual admin/non-admin/anonymous LiveView cases now pass.

The hook's implementation respects its documented layout-only contract. It
mounts scope, applies admin chrome only after the admin-area and account checks,
and preserves the surrounding website/maintenance gates. The opt-in forces the
layout for core-namespace views too. A module requirement must follow the hook
to perform authorization, as the guides explain.

The shared `prepare_admin_mount/3` path retains locale hooks and module-event
subscriptions. The low-level account-gate tests and actual LiveView tests were
run with a reachable test database.
