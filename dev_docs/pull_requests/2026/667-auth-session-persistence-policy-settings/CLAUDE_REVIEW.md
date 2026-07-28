# PR #667 — Registration session persistence + auth policy settings

**Author:** mdon (Dmitri Don)
**Reviewer:** Claude Opus 5
**Date:** 2026-07-28
**Verdict:** ⚠️ APPROVE WITH FIXES — already merged. One MEDIUM bug that halves
the password-reset budget and silently swallows every second reset email, one
MEDIUM open-redirect-adjacent gap in `log_in_user/3`, two MEDIUM
maintainability findings, three NITPICKs. Four fixed post-merge; the rest are
recorded, not fixed.

---

## Summary

Three things in one PR, all on the auth surface:

1. **Session persistence.** Registration (password + magic-link) and QR login
   grow a "Keep me logged in" checkbox; a site-wide `remember_me_enabled`
   master switch and `remember_me_default` starting state back it. The master
   switch is enforced inside `maybe_write_remember_me_cookie/3` — on write
   *and* on read (`ensure_user_token/1`) — rather than at each caller, so
   turning it off can't be defeated by a forged param and doesn't leave
   already-issued cookies restoring sessions for their remaining 60 days. The
   non-remembered branch now `delete_resp_cookie`s instead of no-oping, which
   closes the "cookie points at a token that was deleted on password change,
   so the user is silently signed out weeks later" failure.
2. **Post-auth destinations.** `after_login_path` / `after_registration_path`
   settings, one resolver (`Routes.post_auth_path/1`), and `return_to` threaded
   across every hop between login / register / magic-link / QR / OAuth
   (including inside the magic-link email URL). `Routes.local_path?/1` grows an
   ASCII-control-character rejection, which is a genuine catch: LiveView's
   `validate_local_url!` doesn't block `"/\t/evil.example"` and browsers
   resolve it as `//evil.example`.
3. **`require_email_confirmation` toggle**, plus a `/users/confirm` page that
   stops stranding parked users — it advances them on mount when already
   confirmed and live off a new per-user `{:user_confirmed, _}` topic.

Riding along: enumeration hardening on three public endpoints, `catch :exit`
added to the settings/locale soft-failure paths (a dead DBConnection pool
*exits*, so `rescue` alone never delivered the documented guarantee), the
double-rendered flash group removed from `root.html.heex`, and a real fix to
the standalone `LayoutWrapper` fallback that was nesting a second full HTML
document and swallowing the page body.

The engineering quality is high and the comments are unusually good — most
non-obvious decisions carry the reasoning and the failure they prevent. Three
findings below are places where a stated intent isn't fully realized in code.

## Files changed

44 files, +2614/−243. Core: `phoenix_kit_web/users/auth.ex` (+338),
`utils/routes.ex`, `settings/{setting,settings}.ex`, the eight auth LiveViews /
controllers, `components/{layout_wrapper,oauth_buttons}.ex`. Tests: +1205 lines
across four files (`auth_flows_test.exs` alone is 954).

---

## BUG - MEDIUM: password-reset rate limit charged twice per public request

**`lib/phoenix_kit_web/users/forgot_password.ex:28` + `lib/phoenix_kit/users/auth.ex:1309`**

The PR moves the reset throttle *before* the user lookup — correct, and it
fixes a real account-existence oracle (past the threshold a registered address
got "Too many password reset requests" while an unknown one got the generic
notice, so N+1 requests answered the question). But it **adds** the pre-lookup
check without removing or bypassing the one still inside
`deliver_user_reset_password_instructions/2`, and both hit the same
`auth:password_reset:<email>` Hammer bucket, which increments on every call.

The guide the PR itself adds states the rule as "rate-limiting before the
lookup, **not inside the send**" — the second half never happened.

**Failure scenario.** Budget is 3 per 5 minutes. A registered user submits the
forgot-password form:

| Submission | LV check | `deliver_*` check | Email sent? |
|---|---|---|---|
| 1 | hit 1 → ok | hit 2 → ok | yes |
| 2 | hit 3 → ok | hit 4 → **denied** | **no** |

The LiveView now discards `deliver_*`'s return value, so submission 2 renders
the same "If your email is in our system…" success notice while sending
nothing. A user who didn't get the first mail (spam folder, typo'd nothing,
just impatient) retries, is told it worked, and waits for an email that was
never queued. Effective budget for a legitimate user is halved from 3 to 1,
and the failure is completely invisible.

Note it does *not* re-open the oracle — the response is now uniform either way.
It's a silent-drop / availability bug, not a disclosure one.

**Fixed.** `deliver_user_reset_password_instructions/3` gains a `:rate_limit`
option (default `true`); `forgot_password.ex` passes `rate_limit: false`
because it already charged this request's hit. The internal limiter stays on by
default for the other caller — the admin "send reset link" action in
`user_form.ex:196`, which has no limiter of its own and would otherwise become
an unthrottled mail-send-at-any-user button. Two tests added to
`auth_flows_test.exs` pin both halves (three public submissions all send; the
default-opts path still denies the fourth).

## BUG - MEDIUM: `log_in_user/3` bypassed the loop/lockout guard on `return_to`

**`lib/phoenix_kit_web/users/auth.ex:114`**

The PR is careful that the *settings* can't be pointed at a page which bounces
an authenticated visitor — `after_login_path` / `after_registration_path` are
refused at save time and re-guarded on read, with `/users/log-out` called out
explicitly in three separate comments as the nasty one (it's a real GET route,
so it signs the user straight back out, locking out the admin who set it).

`log_in_user/3` applied only `local_path?/1`:

```elixir
user_return_to = sanitize_local(params["return_to"]) || get_session(conn, :user_return_to)
```

`/users/log-out` is a perfectly good local path. So the guard held for the
value an admin types into a settings form and did not hold for the value that
arrives in a URL — the *less* trusted of the two. `?return_to=%2Fusers%2Flog-out`
appended to any login / register / magic-link / QR / OAuth link (all of which
this PR taught to thread the param onward) means the victim authenticates
successfully and is signed back out in the same response. Repeatable, and it
looks like a broken site rather than an attack. The session-stashed branch
wasn't validated at all, only the param.

`Routes.post_auth_path/1` had the same gap for its candidates — it filtered
them with `local_path?/1` while applying the auth-page rule only to the
`after_login_path` fallback. So both confirmation LiveViews inherited it too.

**Fixed.** `post_auth_path/1` now filters candidates with
`local_path? and not auth_page?`, and `log_in_user/3` resolves its destination
through `post_auth_path([params["return_to"], get_session(conn, :user_return_to)])`
instead of its own local guard — which also makes the module's docs literally
true ("one resolver") and removes the now-dead `sanitize_local/1` and the
`|| signed_in_path(conn)` fallback (`post_auth_path/1` already ends there).
Regression test added.

## IMPROVEMENT - MEDIUM: `@auth_paths` was copy-pasted into two modules

**`lib/phoenix_kit/utils/routes.ex:115` and `lib/phoenix_kit/settings/setting.ex:419`**

The seven-entry path list *and* the `auth_page?/1` predicate existed verbatim
in both `Routes` (read side) and `Setting.SettingsForm` (save side), including
the same four-line comment. This is the classic two-lists-that-must-stay-in-sync
shape: add `/users/passkey` to the router, guard it on read, forget the
changeset copy, and the loop is reachable again through a saved setting — with
no test failing, because each module's tests cover its own copy.

**Fixed.** `Routes.auth_page?/1` is now public (with doctests), and the
changeset calls it. One list, one predicate, three call sites.

## IMPROVEMENT - LOW: `after_registration_path` not re-guarded on read

**`lib/phoenix_kit_web/users/session.ex:168`**

`Routes.after_login_path/0` trims, `local_path?`-checks and `auth_page?`-checks
the stored value on every read, explicitly because "a hand-edited DB row can't
turn a post-auth redirect into an open redirect".
`maybe_store_after_registration_path/1` — the twin — only checked
`local_path?/1`, and didn't trim.

Trimming matters more than it looks: `validate_local_path/2` trims via
`update_change/3`, but `update_all_settings_from_changeset/1` persists
`changeset.params`, **not** `changeset.changes`. So the trim never reaches
storage. `" /welcome"` saves cleanly, then fails `local_path?/1` on read and is
silently ignored — the admin sets the setting, sees no error, and registration
keeps landing on the after-login default.

**Fixed.** Same three guards as the after-login twin, plus the trim.

*Not fixed:* the underlying params-vs-changes persistence quirk in
`Settings.update_all_settings_from_changeset/1`. It's long-standing, affects
every setting, and changing it is a much wider blast radius than this PR.
Recorded here so the next person doesn't re-derive it.

## NITPICK: `auth_page?/1` suffix-matches, so host paths can be over-refused

`String.ends_with?/2` is necessary — the real URL carries the host's mount
prefix and an optional locale segment (`/app/et/users/log-in`) — but it also
refuses a host's own `/help/users/register` or `/docs/users/confirm` as a
post-login destination, with an error message ("cannot point at a sign-in
page") that won't make sense to whoever hit it. Over-strict rather than
loop-permitting is the right default; documented in the new `auth_page?/1`
doc rather than changed, since resolving it properly means resolving the path
against the actual route table.

## NITPICK: AGENTS.md undercounted the confirmation gates

The new section said `require_email_confirmation` is "honored at **six** sites"
and then listed seven, omitting the four role/permission conn plugs
(`require_owner`, `require_admin`, `require_module_access`, `require_role`)
that the PR wires through the new `confirmation_gate/2`. The real count is
eleven — five on_mount hooks, two authentication plugs, four role plugs.
Corrected, with the reason `confirmation_gate/2` exists (the shipped
`:phoenix_kit_admin_only` pipeline runs `require_admin` with **no** preceding
`require_authenticated_*`, so a host controller route behind it enforced
confirmation nowhere, even at the default). That last point is a genuinely good
catch by the PR and deserved to be in the doc.

## NITPICK: magic-link registration for an existing address now sends nothing

`magic_link_registration_request.ex` correctly stops answering "This email is
already registered" — that was an enumeration oracle the other two entry points
don't have. But the user now gets a success notice and **no email at all**, so
someone who forgot they have an account will keep retrying with no way to learn
why. The standard remedy is to send a short "you already have an account, sign
in instead" mail so the response stays uniform to an attacker and informative
to the account owner. Not fixed — it needs a new mailer template and copy in
eight locales, which is its own change.

## Verified, no finding

Spot-checked and found correct:

- The `remember_me` master switch really is unbypassable — enforced on cookie
  write *and* on `ensure_user_token/1` read, and every login path
  (`session.ex`, `oauth.ex`, `magic_link_verify.ex`, `qr_login_complete.ex`)
  funnels through `maybe_write_remember_me_cookie/3`. `@remember_me_options`
  sets no custom `path`/`domain`, so the new `delete_resp_cookie/2` calls
  actually match the cookie they're deleting.
- `@form_fields` in both registration LiveViews covers every field its template
  submits (checked against the `user[...]` inputs in both `.heex` files), so
  the `Map.take/2` hardening drops `custom_fields` without dropping anything
  legitimate.
- The magic-link registration handoff still works after the new
  `admin_confirm_user/1` call: `confirm_changeset/1` is `change(user, ...)`, so
  the virtual `password` survives into the struct the completion form re-posts.
- `/users/confirm` sits in the public `live_session`
  (`:phoenix_kit_mount_current_scope`), so the new confirmation gates redirect
  there without looping, and the LiveView really does get
  `phoenix_kit_current_user` assigned — which the parked-page logic depends on.
- `subscribe`-then-re-read ordering in `ConfirmationInstructions.mount/3` is
  right, and the extra `Auth.get_user/1` is behind `connected?/1`, so the
  double-mount doesn't double-query.
- Removing `<.flash_group>` from `root.html.heex` doesn't strand any surface:
  every `LayoutWrapper` branch that owns a document renders one, the auth pages
  reach it through `AuthPageWrapper` → `LayoutWrapper.app_layout`, and no
  PhoenixKit controller renders a template through the root layout (they all
  redirect).

## Gate

`mix precommit` (format + `compile --warnings-as-errors` + `credo --strict` +
dialyzer) passes clean, before and after the fixes. Per `AGENTS.md` this repo
isn't standalone-`mix test`-able (no PostgreSQL here); the added tests are
integration-tagged and run in a DB-backed environment.
