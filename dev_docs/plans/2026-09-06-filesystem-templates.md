# Filesystem-first templates

**Created:** 2026-09-06
**Status:** Design — not started
**Scope:** phoenix_kit (core), phoenix_kit_emails, phoenix_kit_newsletters, phoenix_kit_billing

---

## Decision

Message templates (email, and later push / Telegram / SMS / in-app) become
**filesystem content owned by the package that sends the message**, translated
through the existing gettext pipeline. A host customizes by shipping its own
file in its own repo.

No template table. No admin template editor. No seeding.

Resolution chain, top to bottom:

```
1. host priv/   · recipient locale
2. host priv/   · "en"
3. package      · recipient locale   (gettext)
4. package      · "en"
5. literal
```

Customization stays per-install and version-controlled, but requires a
developer and a deploy. That is the accepted trade: transactional message
copy is developer-owned content, and the current DB model has cost us a
seeding bug class, an untranslated shipped default, and a half-finished
extraction (below) in exchange for an editing capability that is mostly
used to fix copy a developer wrote.

---

## Why now: the current state is already broken in half

`0d45a284` (2026-03-20) *"Remove Emails module from core, extract to
phoenix_kit_emails package"* moved the schema, context, both editor
LiveViews and the seed task into `phoenix_kit_emails`.

**The table did not move.** Core's V135 still creates
`phoenix_kit_email_templates` (`lib/phoenix_kit/migrations/postgres/v135.ex:247`)
and all seven of its indexes. `phoenix_kit_emails` "adopted" the table on
2026-08-12, but its own `migrations.ex:88` records why core cannot let go:

> Core's V135 creates `fk_newsletters_broadcasts_template` —
> `phoenix_kit_newsletters_broadcasts.template_uuid` referencing
> `phoenix_kit_email_templates(uuid)` — so a core release that stops creating
> `phoenix_kit_email_templates` breaks a FRESH install outright […] That FK
> has to move or go in the same release.

So core declares an FK between two tables that both belong to external
packages (`v135.ex:7838`, mirrored in `expected_schema.ex:39795`), and the
extraction has been stuck mid-flight for six months. This work finishes it
rather than layering a second transition on top.

---

## Scope correction: the table conflates two different things

This is the one place the decision has to narrow, and it is load-bearing.

`phoenix_kit_email_templates` holds two populations with opposite ownership:

| | Kind 1 — **system** | Kind 2 — **operator-authored** |
|---|---|---|
| Examples | `register`, `reset_password`, `magic_link`, `new_login_alert`, `billing_*` | newsletter broadcast wrappers |
| Author | developer, at build time | marketing/ops, at runtime |
| Ships with product | yes | no — created per install |
| Needs translation | yes, all 7 locales | no — authored in one language |
| Flag today | `is_system: true` | `is_system: false` |
| Moves to filesystem | **yes** | **no — cannot** |

Kind 2 is real and in use. `phoenix_kit_newsletters`' broadcast editor loads
`list_templates(%{status: "active"})` (`broadcast_editor.ex:276`) — *all*
active templates, unfiltered by `is_system` — lets the operator pick one per
broadcast, injects the rendered markdown into it (`inject_into_template/3`,
`broadcast_editor.ex:538`), stores the choice as
`phoenix_kit_newsletters_broadcasts.template_uuid`, resolves it at send time
(`delivery_worker.ex:341`), and keeps a site default in the
`newsletters_default_template` setting.

You cannot ask a marketing user to open a PR to restyle a newsletter. So:

- **Kind 1 moves to the filesystem.** This is the whole of the design below.
- **Kind 2 stays in a database table with an editor — but moves to
  `phoenix_kit_newsletters`, which is the only thing that uses it.**
  Renamed (`phoenix_kit_newsletters_layouts` or similar), created by the
  newsletters migration chain, and the `template_uuid` FK becomes an
  intra-package FK instead of a core-declared cross-package one.

That split is what actually resolves the stuck FK, and it is a better
outcome than the FK drop alone: each table ends up owned by the package
that reads it.

---

## Where the renderer lives

Removing storage and the editor removes the reason the templates code
needed core. What remains is pure: resolve the chain, pick a locale out of a
map, substitute `{{vars}}`. No Ecto, no Phoenix, no gettext backend of its
own (each package passes its already-translated strings in).

That makes a leaf `phoenix_kit_templates` package that **core depends on**
viable, which the earlier storage-bearing design ruled out as circular. It
delivers the smaller-repo / faster-precommit / independent-refactor goals.

The cost to weigh: core's release becomes gated on a templates release, and
modules pinning core `~> 2.0` carry the pin transitively. Against ~300 lines
of pure functions that will change rarely once stable.

**Recommendation:** start the renderer as two modules inside core
(`PhoenixKit.Templates` / `PhoenixKit.Templates.Resolver`). Extract to a leaf
package once the API has stopped moving — extraction of a dependency-free
pure module is cheap and reversible; a premature release-ordering constraint
is not.

---

## File layout and format

Package defaults live with the package that sends the message:

```
priv/phoenix_kit_templates/<name>/subject.eex
priv/phoenix_kit_templates/<name>/text.eex
priv/phoenix_kit_templates/<name>/html.eex     # optional, email only
```

Host overrides mirror the same tree under the host's own
`priv/phoenix_kit_templates/`, discovered by convention with a config escape
hatch. Files are read and validated **at compile time**, not per send —
validated at build, no runtime file IO, and correct under a release (where
`priv/` is read-only).

### Translation granularity

The template file is **structure**; the prose inside it is `gettext/1`. Do
not make an HTML body a single msgid — it is an unusable translation unit
and any markup tweak invalidates all seven locales at once.

Constraint carried from the `admin_panel_label` work: a msgid must be a
**literal** `gettext/1` call, or extraction silently misses it and the string
ships untranslated.

### Content parts

Keep three parts, named channel-neutrally rather than email-specifically:

- `subject` → subject line / push title
- `text` → plain body; Telegram, SMS, in-app inbox
- `html` → rich body; email only, `nil` elsewhere

Push uses `subject` + `text`; Telegram and SMS use `text`; the inbox uses
`text` + icon. No generic `parts` map until a channel actually needs a fourth.

---

## What shrinks in `PhoenixKit.Email.Provider`

The provider behaviour (`lib/phoenix_kit/email/provider.ex`) currently mixes
delivery interception, AWS config, provider detection **and** templates. The
template callbacks lose their reason to exist once lookup is a compile-time
filesystem read:

| Callback | Fate |
|---|---|
| `get_active_template_by_name/1` | removed — resolution is not provider business |
| `render_template/2` and `/3` | removed — `PhoenixKit.Templates.render/3` |
| `track_usage/1` | removed — `usage_count` / `last_used_at` die with the table; derive from `phoenix_kit_email_logs` if anyone wants the metric back |
| `get_source_module/1` | removed — the owning package is known statically |

`status: "draft"/"active"` disappears: a file that exists is active.
Interception, `maybe_enqueue/2`, AWS and provider detection are untouched.

---

## Migration

The destructive part. Installs have rows, and some are operator edits.

1. **Classify, don't clobber.** For each existing row, compare against the
   value the old `seed_system_templates/0` would have produced. Byte-identical
   → an untouched seed, safe to drop. Different → a real customization.
2. **`mix phoenix_kit.templates.export`** writes every customized row into the
   host's `priv/phoenix_kit_templates/` as files, for the operator to review
   and commit. This is the whole upgrade path for Kind 1 and must ship (and be
   announced) at least one release *before* anything drops.
3. **Kind 2 rows** (`is_system: false`, referenced by a broadcast) migrate
   into the new newsletters-owned table. Do not export these to files.
4. **Then** drop `fk_newsletters_broadcasts_template` from core's chain and
   hand the table over, per the transitional note in
   `phoenix_kit_emails/dev_docs/reports/2026-08-12-emails-table-adoption.md`.
5. Delete `seed_system_templates/0`, `wrap_i18n/1`, the four editor files, and
   the templates route + settings tab from `phoenix_kit_emails`.

Ordering matters: core's chain runs before every module chain, so the core FK
drop and the newsletters table creation must land in the same release, and
the export task must predate both.

---

## Sequencing

1. **Locale resolver threaded through the five `user_notifier.ex` sites**
   (`:123, :162, :201, :273, :328` all call the 2-arity `render_template/2`
   and therefore always render `"en"`; only `mailer.ex:174` passes a locale).
   Independent of everything else here — ship it first, it is what changes
   the mail that actually lands in an inbox.
2. **gettext the hardcoded fallbacks** in `user_notifier.ex` and the English
   literals in `Notifications.Render.icon_and_text/2`. This establishes the
   translated baseline that steps 3+ build on, and it is the entire fix for a
   host with no emails module installed.
3. **`PhoenixKit.Templates` renderer + resolution chain in core**, plus the
   two missing templates (`new_login_alert`, `magic_link_registration`) as
   files. Add the "review your sessions" link the login alert currently lacks.
4. **Export task**, released and announced.
5. **The table split**: newsletters takes Kind 2, core drops the FK, emails
   loses the editor and the seed.
6. **Notification channels render through it** — `Channel`'s envelope
   `:locale`, documented today as *"a hint, not a guarantee the `:text` is
   already translated"*, becomes a guarantee.

Steps 1–3 are independently valuable and carry no migration risk. Step 5 is
the only irreversible one.

---

## Open questions

- **Host override discovery**: convention-only (`priv/phoenix_kit_templates/`
  in the host app) or an explicit `config :phoenix_kit, template_paths:`?
  Convention is less to document; explicit config composes better with umbrella
  hosts and lets a host keep templates outside `priv/`.
- **Compile-time vs runtime read.** Compile-time is assumed above. It means a
  host override needs a recompile — fine for a deploy, mildly annoying in dev.
  Worth a `@external_resource` so edits trigger recompilation.
- **Do we keep a read-only template viewer in the admin UI?** Operators lose
  all visibility into what the system sends. A non-editable "here is what this
  email looks like" page may be worth keeping from the editor's preview code.
- **`newsletters_default_template`** holds a uuid pointing into the old table;
  it needs migrating alongside the Kind 2 rows.
