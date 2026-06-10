# PR #590 — Media admin: back arrow, breadcrumb stability, title placement + leaf 0.2.23

Reviewed post-merge (merged 2026-06-10). Scope: media browser header UX + Leaf dep bump.
Net diff is small and the UX changes read well. One critical accidental commit, plus a few
lower-severity notes.

## BUG - CRITICAL: broken absolute symlink committed (`priv/static/assets/leaf.js`)

Commit `630e6933` ("Move media browser title above the folder description") accidentally
staged a stray dev symlink:

```
priv/static/assets/leaf.js -> /Users/don/Projects/elixir/work/pk/leaf/priv/static/assets/leaf.js
```

- Mode `120000`, an **absolute** path that only exists on the author's machine. On every
  other clone (CI, Hex consumers, other devs) it is a dangling symlink.
- It is **unused**: the Leaf editor is loaded from the jsDelivr CDN by `phoenix_kit.js`
  (`LEAF_CDN = ".../leaf@v0.2.23/.../leaf.js"`). Nothing in `lib/` or `priv/` references a
  vendored `/assets/leaf.js`, and no install/update task copies it. It is purely an
  artifact of the author testing against a local Leaf checkout.
- Risk: ships inside the Hex package (`priv/static/assets/**` is included), so consumers get
  a dangling symlink in their deps; some tooling/tar extraction and security scanners treat
  absolute-path symlinks as errors.

**Fix applied:** `git rm priv/static/assets/leaf.js` (staged in the working tree).

## IMPROVEMENT - MEDIUM: unrelated lockfile bumps not called out

`mix.lock` in this PR also bumped, with no mention in the PR body or CHANGELOG:

- `phoenix` 1.8.7 → 1.8.8
- `phoenix_live_view` **1.1.31 → 1.2.0** (a minor-series bump)

These are unrelated to the Leaf change and the LV 1.1→1.2 jump can carry behavior changes.
Either intentional (then note it in the CHANGELOG) or an accident of a broad
`mix deps.update` (then it should have been a separate, deliberate bump). Not reverting here
since 1.2.0 is presumably already exercised locally — flagging for awareness.

## NITPICK: hardcoded user-facing strings on the detail back button

`media_detail.html.heex` adds `title="Back"` / `aria-label="Back"` (and keeps the plain
`"Media Detail"` title). The new breadcrumb/title in `media_browser.html.heex` use
`gettext(...)`, so these are inconsistent with the surrounding i18n. Low priority (the old
`admin_page_header title="Media Detail"` wasn't translated either), but a `gettext("Back")`
would match the rest of the header work.

## NITPICK: `window.history.length > 1` is a coarse back heuristic

The inline `onclick` falls back to `/admin/media` only when `history.length <= 1`. If the
user reached the detail page via an external link after other navigation in the same tab,
`history.back()` can step outside the app. Acceptable for an admin tool and the common
in-app path (push_navigate from the grid) works correctly; noting the edge for completeness.

## Good

- Breadcrumb-always-rendered fix removes a real layout jump at the root, and the root crumb
  now consistently resolves scope name vs "All Media" (the old toolbar title's `true ->`
  branch rendered a bare `@scope_folder_name`, blank when unscoped — now `gettext("All
  Media")`). Net correctness improvement.
- The whitespace-only `></tag>` collapses across ~10 files are HEEx-formatter churn, not
  behavior changes — harmless.
- CHANGELOG entries are split per-version and match house style.

## Verdict

Ship the symlink removal. Everything else is informational.
