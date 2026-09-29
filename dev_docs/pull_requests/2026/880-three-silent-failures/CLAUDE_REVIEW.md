# PR #880 review — Fix three silent failures

**Author:** alexdont · **Merged:** 2026-09-29 (`376c2b788`) · **Reviewer:** Claude

Scope: `MediaBrowser` scoped-root `appearance_folder` + "Failed to remove file"
flash; OAuth callback honours `allow_registration`; `UserForm` refuses out-loud
a credential change the actor lacks rank for.

**Verdict:** the three fixes are correct and well tested (15 tests, all green).
Ordering in `OAuth.find_or_create_user/3` is right — the identity-link and
existing-email branches come first, so only *new-account creation* is gated and
sign-in is untouched. `OAuth` is the only caller of `register_oauth_user`, and
`Registration` / magic-link registration already carried their own gates, so no
other door is left open. Findings below were fixed in the follow-up commit.

## Findings

### BUG - MEDIUM — new gettext strings never extracted; fuzzy carryover served a wrong translation
Three new msgids (`Failed to remove file`, `Registration is currently disabled.
Contact an administrator for access.`, the `UserForm` "Saved, but…" flash) were
in source and in no `.pot`, so `mix gettext.extract --check-up-to-date` was red
and every locale rendered English. The extract that catches them also fuzzy-
matched `Failed to remove file` onto *Failed to restore file* in seven locales
(de "…wiederhergestellt", ru "…восстановить") — the remove button would have
announced a restore. **Fixed:** extracted, all three msgids translated by hand in
de/es/et/fr/it/pl/ru, fuzzy flags cleared (0 fuzzy outside `en`'s known 48).

### IMPROVEMENT - MEDIUM — `credential_authority_now/2` ran a DB read on every ordinary save
`credentials_refused?` evaluated `not credential_authority_now(socket, user)`
*first*; that helper does `Auth.get_user/1` plus a permission check, and the
form submits `email`/`username` on every save, so the read was paid even when
nothing credential-related was asked. **Fixed:** the cheap
`credential_change_attempted?/2` comparison now short-circuits first.

### NITPICK — refusal flash omitted `username`
The flash said "password and email were not changed", but `@credential_fields`
also drops `username` (and `rewrites?/3` reports it). **Fixed:** wording now
"password, email and username".

### NITPICK — `OAuth.find_or_create_user/3` moduledoc listed only the three cases
Case 3 read "No local account registers a new one" with no mention of the new
`{:error, :registration_disabled}` outcome. **Fixed.**

## Noted, not changed

- `credentials_refused?` re-asks authority *after* the write, so a rank change in
  that window could flash the wrong way. The window is one request wide and the
  write path itself already re-reads authority (by design); threading a single
  answer through the `with` would mean returning it from `update_user_profile/3`
  for no real gain.
- `submitted_password?/1` does not consult `show_password_field`; a forged
  password param against a page that hides the field would get the "no
  permission" flash instead of silence. Harmless (still nothing written).
