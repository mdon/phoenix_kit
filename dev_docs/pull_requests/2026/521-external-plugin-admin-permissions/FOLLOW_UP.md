# PR #521 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**NITPICK: `permission_key_for_admin_view/1` resolution order
  bears a docstring note.** Added a four-line block comment
  immediately above the function (`lib/phoenix_kit_web/users/auth.ex:1150-1170`)
  enumerating the four resolution steps (static map → custom-tabs →
  `PhoenixKit.Modules.*` namespace → registered-plugin namespace),
  noting the fail-closed default, and explaining why the function is
  exposed as `@doc false def`. Used a `#` comment block rather than
  `@doc """..."""` to avoid the `@doc` attribute redefinition warning
  that comes with adjacent `@doc false` — the result is invisible to
  ExDoc but visible to source readers, which is what the test seam
  needed.~~

## Skipped (deferred / out-of-scope)

- **NITPICK: `Module.create/3` fixture modules persist across the
  test process lifetime.** Forward-looking advice for the next
  plugin-permission test, not actionable for past PRs. The current
  shape works.
- **NITPICK: `@doc false def` exposure could move to a dedicated
  `Internal` module.** Speculative refactor to anticipate three-or-
  more test seams in `Auth`. Premature; lift if the Internal module
  becomes worth its own moduledoc.
- **NITPICK: `safe_call/3` returns `nil` for both crash and
  legitimate nil.** On reflection, adding generic warning logs to
  `safe_call/3` would log too aggressively — every "module doesn't
  expose this callback" lookup would emit a warning. The existing
  `safe_enabled?/1` pattern (warn only on rescue) is the right shape
  for what it does. Skipping the suggested fix.
- **NITPICK: `permission_key_for_admin_view/1` resolution-order
  docstring.** Resolved above (the suggestion was implemented as a
  comment block, not a `@doc` attribute, due to the adjacent
  `@doc false` constraint).
- **NITPICK: Verification gap — no integration test for the redirect
  path.** Out of scope — needs DataCase setup and is a separate test
  PR, not a triage-sized fix.

## Open

None.
