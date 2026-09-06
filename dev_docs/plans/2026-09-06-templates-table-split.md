# Step 6 — retiring the email templates table

**Created:** 2026-09-06
**Status:** Plan only. Nothing executed.
**Scope:** phoenix_kit (core), phoenix_kit_emails, phoenix_kit_newsletters,
**phoenix_kit_billing**
**Context:** `2026-09-06-filesystem-templates.md` (findings and decisions),
`phoenix_kit_templates/dev_docs/plans/2026-09-06-design.md` (the renderer)

Steps 1–5 shipped: core 2.16.0 resolves messages through
`phoenix_kit_templates`, and emails 0.5.0 ships
`mix phoenix_kit_emails.templates.export` with the deprecation announced.
This is the step that finishes the job, and the only irreversible one.

**Do not start until operators have had a real window to run the export.**
0.5.0 published 2026-09-06. One core release cycle, or a direct check on the
installs that matter, is the gate.

---

## Two findings that change the shape

Both surfaced while surveying, and both contradict assumptions in the original
design.

### 1. It is FOUR repos, not three — billing is in the blast radius

`phoenix_kit_billing` sends its invoice, receipt, credit-note and
payment-confirmation emails through a chain nobody had traced:

    billing (phoenix_kit_billing.ex:2597)
      → Emails.Templates.send_email/4        (templates.ex:467)
        → core Mailer.send_from_template/4   (mailer.ex:165)
          → Provider.get_active_template_by_name/1   ← THE TABLE

`send_from_template/4` returns `{:error, :template_not_found}` when there is no
row. Drop the table with this path untouched and **billing's four emails stop
sending**, quietly, with an error shape its caller already tolerates.

That path is also core's generic host-facing API. Any host application calling
`PhoenixKit.Mailer.send_from_template/4` breaks the same way. It has to be
rewired before the table goes, not after.

### 2. Newsletters has no migration chain — the table cannot "move" to it

The design said the operator-authored rows move into a newsletters-owned
table. Newsletters owns no tables: `phoenix_kit_newsletters_broadcasts` is
created by **core's V135**, and the package contains no `Ecto.Migration` at all.

This makes the fix simpler than planned. The original complaint was that core
declares an FK to a table *another package adopted*
(`phoenix_kit_email_templates`, in emails' `@adopted_tables`). If the surviving
table is **core-created and newsletters-named** — exactly what
`phoenix_kit_newsletters_broadcasts` already is — the FK becomes core→core and
the smell is gone without inventing a migration chain.

So: **core keeps the table and renames it. Emails gives up its adoption.**

---

## The migration destroys nothing

The single most important decision here, and a change from the original plan.

A filtered migration that keeps `is_system: false` rows and drops the rest
would destroy every customization an operator never got round to exporting —
precisely the people the export window exists to protect, and the ones least
likely to have read the changelog.

Instead:

- **Rename the table, carrying every row across.** `ALTER TABLE ... RENAME`
  preserves data, indexes and the FK target in one statement, with no copy.
- **Newsletters filters** `is_system: false` when listing pickable layouts, so
  leftover system rows are invisible without being deleted.
- **A later, separate release prunes** the leftovers, once nobody is nervous.

The step stays irreversible in *schema* terms — the editor and the emails-side
code go — but stops being irreversible in *data* terms. An operator who missed
the export still has their rows and can recover them by hand. That is worth
more than a tidy table.

---

## Order of work

Core's migration chain runs before every module chain, so the schema move and
the module code that reads it must land in one coordinated release.

### A — core: rewire `send_from_template/4` (ships FIRST, on its own)

Point it at `PhoenixKit.Email.Content` so a name resolves through host override
files and a caller-supplied default rather than the table. This is additive and
safe to release ahead of everything else, which is the point: it closes
finding 1 while the table is still there, so billing is never in a window where
its emails depend on a path that no longer works.

Keep the DB layer winning, exactly as `Content.resolve/5` already does.

### B — billing: ship its four templates as files

`billing_invoice`, `billing_receipt`, `billing_credit_note`,
`billing_payment_confirmation` move from emails'
`default_system_templates/0` into billing's own `priv/phoenix_kit_templates/`,
and billing passes its own Gettext defaults. This also closes the backwards
coupling recorded in the findings doc — the emails package currently hardcodes
another module's copy.

Billing's floor moves to core ≥ 2.17.

### C — core: the migration (V187)

    ALTER TABLE phoenix_kit_email_templates RENAME TO phoenix_kit_newsletters_layouts

then rename its indexes and the FK constraint to match, and update
`expected_schema.ex` (objects + a `:revisions` entry, `@chain_hash` restamped —
`mix phoenix_kit.release_check` verifies).

`phoenix_kit_newsletters_broadcasts.template_uuid` keeps pointing at the same
rows; only the name changes. Both tables are core-created, so the FK is
core→core.

⚠️ Prefix-safe rules apply (`dev_docs/guides/2026-07-27-prefix-safe-migrations.md`):
index names bare on CREATE, schema-anchored existence checks, and the oracle
(`test/integration/prefix_migration_test.exs`) must run the whole chain into a
scratch schema.

### D — core: remove the template callbacks

`get_active_template_by_name/1`, `render_template/2,3`, `track_usage/1`,
`get_source_module/1` come off `PhoenixKit.Email.Provider` and its
`DefaultProvider`. Interception, `maybe_enqueue/2`, AWS config and provider
detection stay — those are delivery concerns.

### E — emails: lose the templates half

Delete `web/templates.ex`, `web/templates.html.heex`, `web/template_editor.ex`,
`web/template_editor.html.heex`, the route, the settings tab,
`seed_system_templates/0`, `wrap_i18n_fields/1`, the `Template` schema and the
`Templates` context. Drop `phoenix_kit_email_templates` from `@adopted_tables`
and `@adopted_columns` in `migrations.ex`.

**Keep** `TemplateExport` and the export task for at least one more release —
an operator upgrading late still needs it, and it is the only way back for
someone who skipped 0.5.0.

`Templates.send_email/4` is billing's entry point: keep it as a delegate, or
move billing onto `Mailer.send_from_template/4` directly in step B.

### F — newsletters: point at the renamed schema

`PhoenixKit.Modules.Emails.Template` → the core schema for
`phoenix_kit_newsletters_layouts`; `list_templates(%{status: "active"})` →
the equivalent core call, filtered to `is_system: false`. All existing call
sites are already `Code.ensure_loaded?`-guarded, so a version mismatch degrades
rather than crashes — but the guards now protect nothing, since the schema
becomes core's and core is a hard dependency. Simplify them.

Also migrate the `newsletters_default_template` setting: it holds a uuid into
the old table. The uuid is unchanged by a rename, so **no data migration is
needed** — worth stating so nobody writes one.

---

## Release ordering

| Release | Repos | Contents |
|---|---|---|
| core 2.17.0 | core | A (rewire `send_from_template/4`) — additive, no schema change |
| billing next | billing | B (its own template files), floor core ≥ 2.17 |
| core 2.18.0 | core | C + D (V187 rename, callbacks removed) |
| same window | emails, newsletters | E + F, floors core ≥ 2.18 |

The last row is the coordinated one. A host that upgrades core to 2.18 without
upgrading emails gets an emails package whose `Template` schema points at a
table that no longer exists — so emails' next release must **require** core
≥ 2.18, and be published before or alongside it.

## Rollback

- Before C: everything is additive, roll back normally.
- After C: `V187.down/1` renames the table back. Data is intact because
  nothing was deleted, which is the whole reason for the no-destruction rule.
- The emails editor does not come back on a rollback — that code is gone from
  the package. A host needing it must pin the previous emails version.

## Open questions

- **Does `phoenix_kit_newsletters_layouts` want a slimmer schema?** It inherits
  every column the email templates table had — `usage_count`, `last_used_at`,
  `category`, `is_system`, `variables`. A layout needs almost none. Renaming is
  cheap now; a column cleanup can follow once the dust settles, and doing both
  at once makes the rollback harder to reason about.
- **A read-only viewer in core.** Operators lose all visibility into what the
  system sends once the editor goes. The editor's preview code is the obvious
  seed for one, and this is the last moment it exists to salvage from.
