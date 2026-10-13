# PR #928 — admin Edit link passthrough

Reviewer: Codex · Date: 2026-10-13 · Status: reviewed, unreleased

No additional defect found. Checked the automatic admin layout, direct component
callers, module-assign override, account menu, and host-layout merge.

The URL and label travel together, the explicit module URL takes precedence,
and nil/default values render no link. Permission checks remain in
`AdminEditHelper.assign_admin_edit/3`, with the documented admin-area backstop
in the menu. A hand-filled `module_assigns` map is the caller's authorization
responsibility. The linked target remains responsible for enforcing access.
