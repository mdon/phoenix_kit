# The admin header trail

Every admin page renders through `PhoenixKitWeb.Components.LayoutWrapper.app_layout`,
and its header bar draws one breadcrumb:

    Project · Admin Panel / page_section / crumb / crumb / page_title · page_subtitle

The bar owns the separators, the truncation on narrow screens (the trail
drops from the left, the last crumb and the title survive), the ▾ switchers
and the toolbar. A page only says *where it is*, through four assigns:

| Assign | What it is | Example |
|---|---|---|
| `page_section`, `page_section_path` | The module — its admin tab label, linking to its landing page | `CRM` → `/admin/crm` |
| `page_crumbs` | Every level between the module and this page, top down: list pages, parent records | `[%{label: "Contacts", path: …}, %{label: "Jaan Mets", path: …}]` |
| `page_title` | This page, and only this page | `Edit`, `Jaan Mets`, `Contacts`, `New contact` |
| `page_subtitle` | One optional sentence. Rendered only when the `show_page_descriptions` setting is on (Settings → General; off by default) | `Everyone on staff, linked to their user.` |

## The rules

1. **The title never carries a trail.** Not `"CRM — Contacts"`, not
   `"Catalogue - Edit item"`, not `"Entities / Tests"`. The bar draws the
   separators; a title with its own is a second, differently-shaped trail.
   `page_title` also feeds the browser tab, where the module prefix is
   equally noise (`default_tab_title` handles the suffix).
2. **The section is the module.** Its label is the admin tab's label; its
   path is the module's landing page. A settings page under
   `/admin/settings/<module>` uses `Settings` → `/admin/settings` instead —
   it lives in Settings, not in the module. Nothing else goes there: not
   `Modules`, not `Admin`, not a parent record (that is a crumb).
3. **The trail is complete.** From the module down to the page, every level
   a person could go back to is a crumb, in order. A page must not lose a
   level its parent page shows: if the catalogue page shows
   `Catalogues / Kitchen / Doors`, the item page under it shows
   `Catalogues / Kitchen / Doors / <item>`, and its edit page
   `Catalogues / Kitchen / Doors / <item> / Edit`.
4. **Crumbs link.** `path` for another LiveView, `patch` for a drill inside
   the same one. A crumb with neither renders as text — only for a level
   that has no page of its own.
5. **The landing page has no section.** `Admin Panel / CRM` — the module is
   the title there. Its sub-pages carry it as the section.
6. **A description is a description**, not a second title and not the trail:
   one sentence, stated once. Under the setting it appears after the title
   in the bar and under the in-page `admin_page_header` title; with the
   setting off (the default) neither shows, so a page must not rely on it
   to say what it is.

## The shapes, by page type

| Page | `page_section` | `page_crumbs` | `page_title` |
|---|---|---|---|
| Module landing (`/admin/crm`) | — | `[]` | `CRM` |
| List under the module (`/admin/crm/contacts`) | `CRM` | `[]` | `Contacts` |
| Record (`/admin/crm/contacts/:uuid`) | `CRM` | `[Contacts]` | the record's name |
| Record's sub-page (`…/:uuid/members`) | `CRM` | `[Contacts, <record>]` | `Members` |
| New (`/admin/crm/contacts/new`) | `CRM` | `[Contacts]` | `New contact` |
| Edit (`…/:uuid/edit`) | `CRM` | `[Contacts, <record>]` (the record crumb links to its page, or is text when the list is its only page) | `Edit` |
| Nested record (`/admin/catalogue/:c/…/items/:i`) | `Catalogues` | `[<catalogue>, <category>, …]` | the item's name |
| Module settings (`/admin/settings/crm`) | `Settings` | `[]` | `CRM` |

A module whose landing page is itself a list (`/admin/posts` is the posts
list) treats it as the landing page: title `Posts`, no section; the pages
under it carry `Posts` as the section.

## Where the assigns are set

Set them in `mount/3` or `handle_params/3` and pass them through to
`app_layout` (`page_title={@page_title} page_section={@page_section} …`),
or through `PhoenixKitWeb.Live.Helpers`' pass-through where the page renders
in the admin shell without its own layout call. Labels go through the
module's gettext backend like any other string; a record's name is data and
is not translated.

## Checking a module

- `rg -n 'page_title' lib/<module>/web` — every page sets one, none carries
  ` — `, ` - ` or ` / `.
- `rg -n 'page_section' lib/<module>/web` — every non-landing page sets it to
  the module (or `Settings`), with a path.
- Open a record page and its edit page: the edit page's trail is the
  record page's trail plus the record.
