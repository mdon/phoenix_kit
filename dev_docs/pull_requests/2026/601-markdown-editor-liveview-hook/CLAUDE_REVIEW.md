# PR #601 — Drive the markdown editor with a LiveView hook (CSP-safe, navigation-proof)

**Author:** mdon · **Base:** main · **State:** MERGED · **Reviewer:** Claude
**Files:** `lib/phoenix_kit_web/components/core/markdown_editor.ex`, `lib/phoenix_kit_web/components/core/modal.ex`, `priv/static/assets/phoenix_kit.js` (+333 / −332)

## Verdict

Solid, well-motivated refactor. Replacing the inline `<script>` + `onclick`/`onmousedown`
with a `window.PhoenixKitHooks.MarkdownEditor` hook is the right call: it fixes the real
CSP breakage and the LiveView-navigation dead-toolbar bug, and the new code is cleaner than
what it replaces. The `global_id` filtering on server→client events is a genuine correctness
upgrade over the old "update every textarea on the page" broadcast. No blocking bugs found.
A few follow-ups below — none critical, the strongest two are MEDIUM.

Verified non-issues while reviewing:
- **No `handleEvent` leak.** The hook registers 4 `handleEvent` callbacks in `mounted()` and
  only removes the `window` `beforeunload` listener in `destroyed()`. That's correct for
  **phoenix_live_view 1.2.3** (locked): `destroyHook → hook.__cleanup__() → removeHandleEvent`
  for every hook-registered callback. No manual cleanup needed.
- **mousedown `preventDefault` on `phx-click` buttons (image/video/save) is fine** — preventing
  the mousedown default blocks focus/selection-collapse but does **not** suppress the subsequent
  `click`, so those server events still fire. This deliberately preserves the old
  `onmousedown="event.preventDefault()"` behavior.
- **Modal `phx-disable-with={@confirm_button_text}` can't crash** — `confirm_button_text` is
  always set via `assign_new` (`modal.ex:272`).

---

## IMPROVEMENT - MEDIUM — Orphaned `phoenix_kit_markdown_editor.js` is now dead code in the package

`priv/static/assets/phoenix_kit_markdown_editor.js` still contains the **old** standalone
implementation (`window.markdownEditors`, `markdownEditorInsert_<id>`, `markdownFormat_<id>`,
the `MutationObserver`, etc.). After this PR nothing references it:

- The component no longer emits the inline script or calls those globals.
- The installer copies **only** `phoenix_kit.js` (`install/js_integration.ex` → `@source_filename "phoenix_kit.js"`).
- Repo-wide search finds zero references except the file's own doc comment.

It still ships to consumers because `mix.exs` `package.files` includes all of `priv`. It's now
pure dead weight and a source of confusion (two divergent markdown-editor implementations in the
tree). **Recommend removing it** — after a quick confirm that no parent app manually does
`import ".../phoenix_kit_markdown_editor.js"` (the file's own doc comment advertises that path,
so a grep across the consuming apps is worth one minute before deletion).

## IMPROVEMENT - MEDIUM — `dirty` never resets on save → spurious "unsaved changes" prompt

`_hasUnsavedChanges()` returns `this.dirty || status === "unsaved" || status === "saving"`.
`this.dirty` is set `true` on every `input`/`_notifyChange`, and is only ever cleared by the
`set-content` and `changes-status{has_changes:false}` handlers. Per the PR's own comment, only
**publishing** pushes `changes-status`; other consumers (newsletters, and any host that just
flips `save_status` to `:saved`) never clear it.

Result: once the user types anything, `this.dirty` stays `true` for the page's lifetime even
after a successful save, so closing/refreshing the tab fires a bogus `beforeunload` confirm.
(Net it's still an improvement — the old `hasUnsavedChanges` flag was never set anywhere, so the
old guard effectively never fired — but the new one now over-fires.)

`data-save-status` is already rendered on the wrapper, so the fix is one line in `updated()`:

```js
updated() {
  this._acquireTextarea();
  this._revealToolbars();
  if (this.el.dataset.saveStatus === "saved") this.dirty = false; // trust server's saved state
}
```

## IMPROVEMENT - LOW/MEDIUM — Hook-not-registered is now a silent failure

The old code showed a visible warning banner when init failed
(`warningEl.classList.remove('hidden')`). The new code dropped that and relies solely on
`<noscript>`, which only covers **JS fully disabled**. The toolbars ship with `hidden` and are
revealed only by the hook. So if a parent app forgets to spread `window.PhoenixKitHooks` into its
LiveSocket (a documented but easy-to-miss step), the formatting toolbar silently stays hidden with
**no diagnostic** — the editor degrades to a bare textarea and the integrator gets no hint why.
For a library consumed by many host apps, consider a cheap guard: a `console.warn` (or a
`setTimeout` that reveals + warns if the hook never mounted) so the misconfiguration is
discoverable.

## NITPICK — New/changed gettext strings not extracted

`"Heading %{level}"` (new) and `"Enable JavaScript to use the toolbar and media insertion."`
(changed from the old inline-script wording) are not reflected in `.pot`/`.po` (the PR touched
only 3 files). ru/et are the 100%-translated locales — run `mix gettext.extract --merge` before
the next release so they don't regress to fuzzy/missing.

## NITPICK — Toolbar Link prompt and wrap placeholder are hardcoded English

`_link()` calls `window.prompt("Enter URL:")` and `_wrap()` inserts the literal placeholder
`"text"` — both untranslatable, carried over from the old code. The PR added a translatable
`:prompt_insert` path (server supplies the prompt text); the built-in Link button could route
through that same mechanism to become localizable. Minor, pre-existing.

## NITPICK — `phx-disable-with={@confirm_button_text}` gives no in-progress cue

Using the same label as the button means the only visible effect is the disable; the confirm
icon also vanishes during the in-flight swap. The double-submit fix itself is correct and
worthwhile — just noting a "…"/spinner label would read more clearly as "working".

## Informational

- `set-content` is intentionally dropped while the textarea is focused (anti-clobber). Acceptable
  given collaborative spectators are read-only, but it means a focused editor can miss a sync; the
  old code clobbered unconditionally. Worth a one-line note in the moduledoc if collab grows.
- Release housekeeping: changes are unreleased on top of 1.7.161 — needs a `@version` bump +
  CHANGELOG entry alongside the gettext extract.

---

## Aside (not part of this PR): why `req` won't upgrade off 0.5.17

**Real cause: `req 0.6.1` conflicts with the locked `finch 0.23.0`** — not a lock pin. Confirmed
empirically: `mix deps.update req` (which unlocks req and re-resolves) leaves the lock **unchanged**
at 0.5.17.

The direct constraints on `req` are a red herring — every one of them allows 0.6.1, which is why
`mix hex.outdated req` reports "Up-to-date: Yes" across the board (it only checks the *direct* req
requirement, not req's own transitive deps). The block is one level deeper, in `req`'s **own**
`finch` requirement:

| | finch requirement | satisfied by locked finch 0.23.0? |
|---|---|---|
| req **0.5.17** | `~> 0.17` → `>= 0.17.0 and < 1.0.0` | ✅ |
| req **0.6.1** | `~> 0.21.0 or ~> 0.22.0` → `>= 0.21.0 and **< 0.23.0**` | ❌ excludes 0.23.0 |

`finch` resolved to **0.23.0** (the latest) because every requirer allows it — `swoosh ~> 0.6`,
`tesla ~> 0.13`, and `req 0.5.17 ~> 0.17`. `req 0.6.1` pins finch *below* 0.23.0, so it simply
isn't satisfiable against the current tree. `mix deps.update req` unlocks only `req`, can't roll
`finch` back, and so correctly keeps `req` at 0.5.17 (the newest req compatible with finch 0.23.0).
**Nothing downgraded req — it has never been able to move up.** req 0.6.x just hasn't caught up to
finch 0.23 yet (req 0.6.1 shipped 2026-06-08; finch 0.23 landed after its pin).

**Recommendation: stay on req 0.5.17.** The only way to land req 0.6.1 today is
`mix deps.update req finch`, which would *downgrade* finch to 0.22.x — trading a newer, healthy
dependency for a req minor bump, net-negative. Revisit when req publishes a release that accepts
`finch ~> 0.23` (likely req 0.6.2+). phoenix_kit only uses the stable
`Req.get` / `Req.post` / `Req.Response` / `Req.TransportError` surface, so there's no feature
pressure to force it.
