# Message templates: findings and direction

**Created:** 2026-09-06
**Status:** Findings recorded; core-side work not started
**Scope:** phoenix_kit (core), phoenix_kit_emails, phoenix_kit_newsletters,
phoenix_kit_billing
**Detailed design:** `phoenix_kit_templates/dev_docs/plans/2026-09-06-design.md`

This document records what we found and what we decided. The design of the
new renderer package lives in that package's repo; this one keeps the
findings that motivated it and the work core itself owns.

---

## How this started

A new-login alert email arrived as bare plain text, addressed to an email
address rather than a name, in English, with no link. Tracing why turned up a
good deal more than a missing template.

---

## Findings

### 1. Core never passes the recipient's locale

Of core's six template call sites, exactly one — `mailer.ex:174`, the generic
host-facing `send_from_template/4` — passes a locale. All five auth emails
(`user_notifier.ex:123, 162, 201, 273, 328`) call the **2-arity**
`render_template/2`, which defaults to `"en"`.

So even with the emails package installed and a template translated into all
seven locales, every confirmation, reset, magic-link and login-alert email
renders in English. The translations sit in the database and are never read.

The recipient's locale is available and has been all along:
`custom_fields["preferred_locale"]`, written by
`Auth.update_user_locale_preference/2` off the language switcher
(`phoenix_kit_web/users/auth.ex:942`).

This is the single highest-value fix in the whole area and is independent of
everything else here.

### 2. Two core emails have no template at all

`new_login_alert` (`user_notifier.ex:307`) and `magic_link_registration`
(`user_notifier.ex:256`) are looked up but never seeded. The seeded set is
`magic_link`, `register`, `reset_password`, `test_email`, `update_email` and
four `billing_*`. That is why the alert email arrived as the hardcoded
fallback.

The fallback itself also tells the user to "change your password immediately"
and gives them no link to do it (`user_notifier.ex:321`) — the one channel
that reaches a genuinely compromised account is the one with no way through.

### 3. Three parallel content systems that don't know about each other

| System | Storage | i18n | Editable | Used by |
|---|---|---|---|---|
| `phoenix_kit_email_templates` | DB, JSONB lang maps | yes | admin editor | email only |
| `Notifications.Render.icon_and_text/2` | hardcoded English literals in a `case` | **no** | no | inbox, Telegram, email channel, any future push |
| gettext `.po` | files | 7 locales at 100% | no | UI only — neither of the above |

`PhoenixKit.Notifications.Channel`'s own moduledoc already names the hole:
the envelope carries `:locale` for channels that localize, *"but the core's
built-in rendering is English today (i18n of the rendered strings is not
wired yet) — so treat `:locale` as a hint, not a guarantee."* The envelope
was designed for a renderer that was never built.

### 4. The 2026-03 emails extraction is still half-finished

`0d45a284` (2026-03-20) *"Remove Emails module from core, extract to
phoenix_kit_emails package"* moved the schema, context, both editor
LiveViews and the seed task out.

**The table did not move.** Core's V135 still creates
`phoenix_kit_email_templates` (`lib/phoenix_kit/migrations/postgres/v135.ex:247`)
and all seven of its indexes. `phoenix_kit_emails` adopted the table on
2026-08-12, but its `migrations.ex:88` records why core cannot let go:

> Core's V135 creates `fk_newsletters_broadcasts_template` —
> `phoenix_kit_newsletters_broadcasts.template_uuid` referencing
> `phoenix_kit_email_templates(uuid)` — so a core release that stops creating
> `phoenix_kit_email_templates` breaks a FRESH install outright […] That FK
> has to move or go in the same release.

Core therefore declares an FK between two tables that both belong to external
packages (`v135.ex:7838`, mirrored in `expected_schema.ex:39795`), and the
extraction has been stuck mid-flight for six months. This work finishes it
rather than layering a second transition on top.

### 5. `phoenix_kit_emails` hardcodes another module's content

`seed_system_templates/0` seeds `billing_invoice`, `billing_receipt`,
`billing_credit_note` and `billing_payment_confirmation`. The emails package
owns billing's copy. That is backwards coupling, and it is what the wrong
home for templates looks like.

---

## Decisions

### Filesystem is the baseline; the database was never the right one

System templates become files owned by the package that sends the message,
translated through that package's gettext. A host customizes by shipping its
own file in its own repo. No template table, no admin editor, no seeding.

Everything in findings 2–5 is downstream of DB-as-baseline:

- **Seeding disappears** — nothing to seed, which deletes the bug class
  behind `366c6254 "Fix email template seeding failing on fresh install"`.
- **The vendor-vs-operator merge problem never arises.** With DB-as-baseline,
  shipping an improved template means writing into a table the operator may
  have edited: clobber their copy, or skip the update and they never get the
  fix. As layers, defaults change freely per release and the override keeps
  winning.
- **Translations ship.** `wrap_i18n/1` produces `%{"en" => v}`, so every
  install starts English and someone hand-translates in the editor. On the
  filesystem the defaults ride the gettext pipeline that is already at 100%
  in seven locales.
- **Billing's coupling dissolves** — each package ships its own files.

The trade accepted: customization now needs a developer and a deploy.
Transactional copy is developer-owned content, and the editing capability we
give up was mostly used to fix copy a developer wrote.

### A template overrides a translated baseline; it never *is* the baseline

Resolution runs host override → package default (gettext) → literal. gettext
and file/DB overrides answer different questions — gettext is strings the
*developer* owns, shipped translated; an override is content the *operator*
owns, per install. Making overrides the baseline is what loses the seven
locales.

This also means core's no-package fallback path and its normal path are one
mechanism rather than two.

### The renderer is a separate leaf package

`phoenix_kit_templates` — pure resolution and `{{var}}` substitution, no
Ecto, no Phoenix, no storage, no UI. Because it depends on nothing in the
tree, **core can depend on it** without a cycle.

Weighed and accepted: core's release becomes gated on a release there, and
modules pinning core `~> 2.0` carry the pin transitively. Bought in exchange
for a small repo with a fast precommit that refactors without touching core.
The package doc records the condition under which that trade goes bad.

---

## Scope correction: the table conflates two different things

Load-bearing, and it narrows what can actually move.
`phoenix_kit_email_templates` holds two populations with opposite ownership:

| | **System** | **Operator-authored** |
|---|---|---|
| Examples | `register`, `reset_password`, `magic_link`, `new_login_alert`, `billing_*` | newsletter broadcast wrappers |
| Author | developer, at build time | marketing/ops, at runtime |
| Ships with product | yes | no — created per install |
| Needs translation | yes, 7 locales | no — authored in one language |
| Flag today | `is_system: true` | `is_system: false` |
| Can move to files | **yes** | **no** |

The second kind is real and in use. `phoenix_kit_newsletters`' broadcast
editor loads `list_templates(%{status: "active"})`
(`broadcast_editor.ex:276`) — *all* active templates, unfiltered by
`is_system` — lets the operator pick one per broadcast, injects rendered
markdown into it (`inject_into_template/3`, `broadcast_editor.ex:538`),
stores the choice as `phoenix_kit_newsletters_broadcasts.template_uuid`,
resolves it at send time (`delivery_worker.ex:341`), and keeps a site default
in the `newsletters_default_template` setting.

You cannot ask a marketing user to open a PR to restyle a newsletter. So:

- **System templates** move to the filesystem. That is the package design.
- **Operator-authored templates** keep a table and an editor, but move to
  `phoenix_kit_newsletters` — the only package that reads them. Renamed
  (`phoenix_kit_newsletters_layouts` or similar), created by the newsletters
  migration chain, and `template_uuid` becomes an intra-package FK.

That split is what actually resolves finding 4, and it is a better outcome
than dropping the FK alone: each table ends up owned by the package that
reads it.

---

## Work core owns

Everything else lives in the package design doc.

1. **Locale resolver** threaded through the five `user_notifier.ex` sites.
   Resolution: `custom_fields["preferred_locale"]` → default language setting
   → `"en"`. No schema change, no dependency on the rest of this.
2. **gettext the hardcoded fallbacks** in `user_notifier.ex` and the English
   literals in `Notifications.Render.icon_and_text/2` — this is the
   translated baseline everything else resolves down to, and it is the whole
   fix for a host with no emails package installed.
3. **Depend on `phoenix_kit_templates`** and route the five auth emails
   through it; ship `new_login_alert` and `magic_link_registration` as files,
   the alert with the account-security link it currently lacks.
4. **Drop `fk_newsletters_broadcasts_template`** from V135 and stop creating
   `phoenix_kit_email_templates` — necessarily in the same release as the
   newsletters table lands, since core's chain runs before every module chain.
   Update `expected_schema.ex` to match.
5. **Remove the four template callbacks** from `PhoenixKit.Email.Provider`
   (`get_active_template_by_name/1`, `render_template/2,3`, `track_usage/1`,
   `get_source_module/1`) and their `DefaultProvider` no-ops. Interception,
   `maybe_enqueue/2`, AWS config and provider detection stay — those are
   delivery concerns.
6. **Notification channels render through the package**, turning the
   envelope's `:locale` from a documented hint into a guarantee.

Items 1 and 2 are worth shipping on their own merits whatever happens to the
rest; item 4 is the only irreversible one, and it needs the emails package's
export task released and announced first.
