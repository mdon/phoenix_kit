# `phx-change` forms without an `id` — LiveView form recovery silently disabled

**Reported by:** an agent working on a host app consuming phoenix_kit 1.7.214
**Investigated / fixed:** 2026-07-27, Claude Opus 5
**Released in:** 1.7.216
**Outcome:** confirmed; **26 forms** fixed — the report named 12, the audit
found 14 more that its detection method structurally could not see.

---

## The defect

LiveView cannot perform [form recovery][recovery] on a `<form phx-change=…>`
that has no `id`. After a crash or a reconnect, the client re-sends the form
state of every recoverable form so the server can rebuild it; a form without an
id is skipped, and whatever the user had typed is silently gone. There is no
error — the input just isn't there any more.

[recovery]: https://phoenix-live-view.hexdocs.pm/form-bindings.html#recovery-following-crashes-or-disconnects

The second cost lands on host apps. `Phoenix.LiveViewTest` warns
`Detected a form with phx-change but missing id` for every offending form it
renders. Because the forms live in this dep's own templates, a host had no
targeted fix — only the global
`config :phoenix_live_view, :test_warnings, missing_form_id: :ignore`, which
also mutes the host's own genuine cases. That is what prompted the report.

The exact trigger, from `Phoenix.LiveViewTest.TreeDOM.detect_forms_without_id/2`:

```elixir
{nil, phx_change, nil, auto_recover}
when is_binary(phx_change) and auto_recover != "ignore" ->
```

So: **`phx-change` present, `id` absent, no `phx-ignore-missing-id`, and
`phx-auto-recover` ≠ `"ignore"`.** `phx-submit` alone never warns — submit has
nothing to recover.

## Why the reported list was incomplete

The report's detection was:

```bash
grep -rn '<form' lib/ --include="*.ex" --include="*.heex" | grep 'phx-change' | grep -v 'id='
```

Two blind spots, each of which hid real cases:

**1. It only matches single-line tags.** Every attribute has to sit on the same
physical line as `<form`. `mix format` breaks any tag past the line limit across
lines, so the longer forms — which are exactly the ones with `phx-target`, a
`class` list, and both bindings — were invisible. That hid 9 forms, including
all five in `media_browser.html.heex` other than the new-folder one.

**2. It assumed `<.form>` is always safe.** The report states "`<.form>`
(Phoenix.Component) passes `id` through `:rest` and renders it fine, so those
are not affected." That is only true when the `for` source *supplies* an id.
Tracing `Phoenix.HTML.FormData`:

- `for={@changeset}` (`phoenix_ecto/lib/phoenix_ecto/html.ex:8-9`) —
  `name = to_string(name || form_for_name(data))`, `id = opts[:id] || name`.
  Non-nil. **Safe.**
- `for={%{}}` or any bare map (`phoenix_html/lib/phoenix_html/form_data.ex:85`,
  `:104-116`) — with no `:as`, `name` is `nil`, so `id = opts[:id] || nil` is
  **`nil`**. `<.form>` then renders no id and warns exactly like a raw tag.

That hid 4 more, including `MediaBrowser`'s search form and the storage
media-config form.

### The replacement check

`grep` is the wrong tool for this — the thing being matched spans lines and
contains `{…}` interpolations with nested quotes and `>` characters. A
brace/quote-aware scanner walks each `<form` / `<.form` to its true closing `>`:

```python
for m in re.finditer(r'<\.?form\b', src):
    i = m.end(); depth = 0; q = None
    while i < len(src):
        c = src[i]
        if q:
            if c == q: q = None
        elif c in '"\'': q = c
        elif c == '{': depth += 1
        elif c == '}': depth -= 1
        elif c == '>' and depth == 0: break
        i += 1
    yield src[m.start():i+1]
```

Then flag any tag containing `phx-change` but not `id=`. This is what confirmed
the sweep was complete. It still reports the two `for={@changeset}` forms
(§ *Deliberately unchanged*) — a false positive it can't resolve without
evaluating the source term, so treat those two as a known-good baseline.

## Sites fixed

Line numbers as of 1.7.216.

### LiveComponents — id derived from `@id`

A static id would produce duplicate DOM ids the moment a page renders two
instances, which trades the `missing_form_id` warning for a `duplicate_id` one.
`@id` is always assigned on a `live_component`.

| File | Line | Binding | Id |
|---|---|---|---|
| `live/components/media_selector_modal.html.heex` | 118 | `validate` / `save` | `#{@id}-upload-form` |
| `live/components/searchable_select.ex` | 144 | `search` | `#{@id}-search-form` |
| `components/media_browser.html.heex` | 1037 | `search` | `#{@id}-search-form` |
| `components/media_browser.html.heex` | 2387 | `new_folder_input` | `#{@id}-new-folder-form` |
| `components/annotation_composer.ex` | 356 | `update_draft` (`<.form for={%{}}>`) | `#{@id}-form` |

### Per-row inline editors — id also keyed by folder uuid

These sit inside a folder comprehension. Each is gated on
`@renaming_folder == folder.uuid` / `@editing_folder_description == folder.uuid`,
so only one can render today — but the id is keyed by uuid anyway so the
guarantee doesn't depend on that invariant holding. Grid and list variants are
namespaced separately for the same reason.

| File | Line | Binding | Id |
|---|---|---|---|
| `components/media_browser.html.heex` | 1302 | `folder_description_input` (grid) | `#{@id}-grid-folder-description-form-#{folder.uuid}` |
| `components/media_browser.html.heex` | 1341 | `rename_folder_input` (grid) | `#{@id}-grid-folder-rename-form-#{folder.uuid}` |
| `components/media_browser.html.heex` | 1838 | `folder_description_input` (list) | `#{@id}-list-folder-description-form-#{folder.uuid}` |
| `components/media_browser.html.heex` | 1891 | `rename_folder_input` (list) | `#{@id}-list-folder-rename-form-#{folder.uuid}` |
| `components/folder_explorer.ex` | 372 | `rename_folder_input` | `folder-tree-rename-form-#{@node.folder.uuid}` |

`folder_explorer.ex` is a plain function component (`use PhoenixKitWeb, :html`)
that receives `myself` as an attr. The rename form lives in
`folder_tree_node/1`, which has no `:id` attr in scope — hence the uuid-only id
rather than an `@id`-derived one.

### LiveViews — static ids

| File | Line | Binding | Id |
|---|---|---|---|
| `modules/sitemap/web/settings.html.heex` | 544 | `update_style` | `sitemap-style-form` |
| `modules/sitemap/web/settings.html.heex` | 581 | `update_interval` | `sitemap-interval-form` |
| `modules/maintenance/settings.ex` | 383 | `update_content` / `save` | `maintenance-content-form` |
| `modules/storage/web/settings.html.heex` | 321 | `update_storage_form` (`<.form for={%{…}}>`) | `storage-media-config-form` |
| `live/modules/jobs/index.html.heex` | 76 | `filter_queue` | `jobs-filter-queue-form` |
| `live/modules/jobs/index.html.heex` | 90 | `filter_state` | `jobs-filter-state-form` |
| `live/modules/jobs/index.html.heex` | 122 | `filter_worker` | `jobs-filter-worker-form` |
| `live/users/sessions.html.heex` | 175 | `search` | `sessions-search-form` |
| `live/users/sessions.html.heex` | 194 | `filter_by_user_status` | `sessions-user-status-filter-form` |
| `live/users/live_sessions.html.heex` | 122 | `search` | `live-sessions-search-form` |
| `live/users/users.html.heex` | 240 | `search` / `search` | `users-search-form` |
| `live/users/media_selector.html.heex` | 57 | `validate` / `save` (`<.form for={%{}}>`) | `media-selector-upload-form` |
| `live/notifications/settings.ex` | 236 | `form_changed` / `save` | `notification-settings-form` |
| `live/integrations/my_integration_form.ex` | 466 | `set_mode` | `telegram-mode-form` |
| `users/qr_login.html.heex` | 26 | `set_remember` | `qr-login-remember-form` |

### `<.sort_selector>` — new public `id` attr

`components/core/sort_selector.ex` is a reusable stateless function component
with no `@id` to borrow and no per-item key. It gained:

```elixir
attr :id, :string, default: nil
# → assign(:form_id, assigns[:id] || "pk-sort-selector-#{assigns[:event]}")
```

The event-derived default keeps two selectors distinct in the common case (they
drive different events); the moduledoc records that a page rendering two
selectors on the *same* event must pass an explicit `id`. This is the only
API-surface change in the release.

The `<.popover_panel>` moduledoc example also carried an id-less
`<form phx-change="search">` — updated so it stops teaching the defect.

## Deliberately unchanged

`modules/storage/web/bucket_form.html.heex:16` and
`dimension_form.html.heex:16` use `<.form for={@changeset}>`, which already
renders an id (`"bucket"` / `"dimension"`, from the schema source name) and does
not warn. Adding an explicit `id` there would *not* be a no-op: `<.form>` threads
`id` into the `to_form` opts, so every nested field id would change
(`bucket_name` → `storage-bucket-form_name`), breaking any label `for=`
association, JS selector or test that references them. A cosmetic rename is not
worth that.

## Verification

- `mix precommit` clean — format, `compile --warnings-as-errors --all-warnings`,
  `credo --strict`, dialyzer.
- The brace-aware scanner reports zero id-less `phx-change` forms outside the
  two changeset-backed ones above.
- **Not** verified by running the suite under
  `config :phoenix_live_view, :test_warnings, missing_form_id: :raise`, which is
  what the report suggested. This repo is not standalone-testable
  (`mix precommit` is the project's gate), so the evidence here is static.
  A host app on 1.7.216 can confirm the runtime side by flipping that config and
  running its own suite — worth doing before assuming the class is closed.
- The original report likewise had only **one** verified runtime reproduction
  (the media selector modal); the rest were pattern matches. Same caveat applies
  to the 14 additional sites found here.

## The recurrence rule

New `<form>` markup with `phx-change` needs an `id`, and the id has to be unique
in the rendered page:

- **LiveComponent** → derive from `@id`, never a static string.
- **Inside a comprehension** → include the row's uuid.
- **Reusable function component** → expose an `id` attr with a sensible derived
  default; don't hardcode.
- **`<.form for={%{}}>`** → same rule as a raw tag. Only `for={@changeset}` (or
  a `to_form(…, as: :x)`) supplies an id for free.

Detect with the scanner logic above, not a line-oriented `grep`.
