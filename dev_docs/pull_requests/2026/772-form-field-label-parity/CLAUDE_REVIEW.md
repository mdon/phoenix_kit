# PR #772 — Update Select/Textarea and translatable-field labels to match Input's

**Author:** mdon (`main`) · **Merged:** 2026-08-30 · **Reviewed:** 2026-08-30

Reviewed together with `585973ca` ("Add Core.ContextMenu"), which was pushed
straight to `main` with no PR and ships in the same release.

## Verdict

**#772: right outcome, wrong stated mechanism — and the wrong mechanism left
three defects.** Fixed here.
**585973ca: no XSS, sound design, six real bugs in the JS hook.** Five fixed
here; the sixth is latent (no core call site) and now documented accurately.

---

## Part 1 — PR #772

### The stated mechanism is backwards

The PR says `fieldset-legend` "shrank and muted" the labels. Verified against
the vendored daisyUI 5 build (`*/assets/vendor/daisyui.js`,
`packages/daisyui/components/fieldset/object.js`):

| selector | what it actually sets |
|---|---|
| `.fieldset-legend` | `margin-bottom:-0.25rem`, `display:flex`, `gap:0.5rem`, **`padding-block:0.5rem`**, **`color: var(--color-base-content)`**, `font-weight:600` — **no `font-size`** |
| `.fieldset` | **`font-size: 0.75rem`**, grid, `padding-block:0.25rem` |
| `.label` | `display:inline-flex`, `gap:0.375rem`, **`color: color-mix(in oklab, currentcolor 60%, transparent)`** |

So `fieldset-legend` never shrank anything. Inside `.label` it *un-muted* the
span (full `base-content` over `.label`'s 60% alpha) and added 8px of block
padding. Removing it makes a label **more** muted and **less** padded — which
is right, because that is what `<.input>` looks like, but it is the opposite of
the reasoning in the PR body, the code comments and both test comments.

The user's report was real and the fix direction is correct. Only the
explanation was wrong — and it propagated.

### BUG — MEDIUM · four call sites lost their only bottom gap
`form_field_label.ex` was `class={["label", @class]}`, with no `mb-2`; `<.input>`
hardcodes `class="label mb-2"`. `select.ex:46` and `textarea.ex:57` pass their
own `mb-2`, but the four direct `<.label>` callers do not:
`registration.html.heex:85`, `magic_link_registration.html.heex:86`,
`send_profile_form.html.heex:17` and `:24`. Their only gap had been
`fieldset-legend`'s `padding-block: 0.5rem`; post-PR it is 0. In
`send_profile_form` those labels sit in the same 2-column grid as `<.input>`
fields that still have 8px, so the row reads uneven.

**Fixed:** `mb-2` moved into the component (`class={["label mb-2", @class]}`),
matching `<.input>`; the now-redundant copies dropped from Select/Textarea.

### BUG — MEDIUM · `text-sm` in `multilang_form.ex` restored nothing
The comment claimed `fieldset-legend` "overrode" the wrapper's 0.75rem. It
cannot — it sets no font-size. The 12px came from the component's *own* wrapper,
`class="fieldset flex flex-col gap-1"` (`:988`). So `text-sm` was a new 12px→14px
bump, and since `<.input>`'s label carries no font-size at all (≈16px outside a
fieldset), `<.translatable_field>` labels were still ~2px smaller than the
`<.input>` labels beside them — visible on the catalogue item form
(Name/Description vs SKU).

**Fixed:** dropped `fieldset` from the wrapper (its `grid`/`gap` were already
overridden by `flex`/`gap-1`; only 0.25rem padding-block goes with it) and
dropped `text-sm`. The span is now byte-identical to Input's — pinned by a test
that renders both and compares.

### BUG — MEDIUM · `mentions/live.ex` was the same component, now diverged
`lib/phoenix_kit/mentions/live.ex:192-195` was a byte-for-byte copy of
`translatable_field`'s pre-PR markup, and `mention_input/1` is public — used by
`phoenix_kit_projects` in the *same forms* as `<.translatable_field>` and
`<.textarea>`. The PR moved one and not the other, so two components that
rendered identically now differed in both size and colour.

**Fixed:** same one-line edit, with a comment saying they track each other.

### IMPROVEMENT — MEDIUM · required marker diverged from Input
`select.ex`/`textarea.ex` put the asterisk *inside* the slot, so it landed
inside the `font-semibold` span. Under the old markup that span was
`display:flex; gap:0.5rem`, giving ~10px before the `*`; with `fieldset-legend`
gone the gap collapsed to `ml-0.5` and the asterisk is bold, where Input's
(`input.ex:87`) is a non-bold sibling.

**Fixed:** `FormFieldLabel` takes `required` and renders the marker exactly as
Input does; Select/Textarea pass it instead of hand-rolling the span.

### IMPROVEMENT — MEDIUM · tests didn't pin the invariant they exist for
`form_field_label_test.exs:22` asserted the substring `"font-semibold"` — which
still passes with `text-xs` appended, i.e. the exact regression class. The
multilang case pinned `font-semibold text-sm` but never asserted the wrapper,
the coupling that was the whole justification for `text-sm`.

**Fixed:** added a byte-identical-to-Input span comparison, a
`refute =~ ~r/text-(xs|sm|base|lg|xl)/` on the span, a class-survival case, a
required-marker case, and a wrapper assertion on the multilang side.

### The PR's formatter caveat is false — the tree is clean
The body reports `mix format --check-formatted` failing on
`test/mix/tasks/phoenix_kit_doctor_test.exs`. That file is byte-identical
between `348ccb91` and `HEAD` and is correctly formatted; `mix format
--check-formatted` exits 0 here (Elixir 1.19.5 / OTP 28). Local toolchain
variance on the author's box, not a tree problem — no release risk.

### Left alone (agreed out of scope)
- `searchable_select.ex:117` — a real `<legend class="fieldset-legend">` in a
  real `<fieldset>`, the sanctioned daisyUI idiom. Both call sites are
  internally consistent. Correct as-is.
- `registration.html.heex` / `magic_link_registration.html.heex` — every other
  field on those two public pages hand-rolls `<span class="fieldset-legend">`,
  so the referral-code label (the one `<.label>` call) is now muted where its
  siblings are opaque. Fixing it properly means converting ~10 spans and
  changing the look of the public signup page: a design call for the
  maintainer, not a patch-release edit. **Top follow-up.**
- `user_form.html.heex:166,235` — same shape on `/admin/users/:id/edit`, where
  the hand-rolled pair now mismatches adjacent `<.select>` labels on both size
  and colour. Same sweep.

---

## Part 2 — `585973ca` Core.ContextMenu

Reviewed because it ships in this release and had no PR.

### No XSS — checked first
`_stamp` is the only path from row data to the DOM: `textContent` for the
heading, `setAttribute` for the values. There is no `innerHTML`,
`insertAdjacentHTML`, `outerHTML` or markup string anywhere in the ContextMenu
IIFE, and `data-context-label` reaches the DOM through HEEx escaping. Folder and
file names are safe.

The design is good: one menu per row *kind* rather than per row, no round-trip
to open, `TableRowMenu` markup reused so a context menu and a `⋮` menu are
identical, and the portal-to-`<body>` with restore-on-close mirrors `RowMenu`.
The render tests are non-tautological and pin the DOM contract the hook reads.

### Fixed here

1. **`destroyed()` didn't cancel a pending long press.** Hold a row, let the
   LiveView patch it away inside the 450ms, and the timer still fired
   `_open()` — appending a menu belonging to a destroyed hook into `<body>`,
   where nothing owned it. Now cancels, and the timer also bails if its menu
   left `menus`.
2. **`within` honoured only the first matching container.**
   `document.querySelector(within)` means a class-based selector silently left
   every row in the second and later containers with no menu. Now
   `row.closest(within)` — correct for N containers, handles the ancestor case,
   and cheaper than a document query per pointerdown.
3. **A right-click on empty space left the open menu on screen** under the
   browser's native one: `contextmenu` produces no click, and the mouse path
   arms no long press, so nothing closed it. Now closes.
4. **The native-menu grace window wasn't gated on the menu being open,** so a
   right-click within 800ms of a dismissed long press was suppressed with
   nothing shown in its place.
5. **The click swallower was tied to the menu's open state.** `onDocClick` was
   registered in `_open` and removed in `_close`, so anything that closed the
   menu between the long press and the release (Escape, `scroll`, an Android
   URL-bar `resize`) left the flag armed with no listener — and the release
   click then activated the row underneath, the exact thing the swallow exists
   to prevent. Now registered once in `install()`; it no-ops when idle.
6. **The swallow backstop timer was untracked,** so with two long presses
   inside 700ms the first press's backstop cleared the second's flag.

Also: the JS test named "clamps to the 8px margin when the flip would go off
the other edge" never reached the flip branch (`4 + 200` doesn't overflow) — it
passed for the wrong reason, and the horizontal flip-then-clamp was untested.
Renamed to what it checks, and a real flip-then-clamp case added.

### Not fixed — latent, now documented accurately

**The MediaDragDrop long-press collision.** `MediaDragDrop` binds its own 450ms
long press to `[data-draggable-file]`/`[data-draggable-folder]`, and
`media_browser.html.heex:8` wraps the `<.folder_explorer>` this commit made
context-menu-ready. One hold would fire both gestures. Two things made the
existing warning inadequate:

- Its advice — use "a `selector` that does not overlap" — does not work. Rows
  resolve via `Element.closest/1`, so the two collide whenever one element
  merely *contains* the other, and in FolderExplorer they do in both
  directions.
- ContextMenu swallows the post-long-press click at `document` capture, which
  is upstream of the per-element listener MediaDragDrop uses to clear its own
  `_lpFired`. That flag then stays set and eats one later tap on the same card.

**Not reachable in core today:** `<.context_menu>` has no real call site — all
eight matches in `lib/` are moduledoc examples. It goes live the moment a
consumer declares a menu over the media browser's folder tree, which is exactly
the documented use case. Rewriting gesture arbitration blind, with no device to
test on, is worse than shipping it documented, so the moduledoc now states the
containment rule, the `_lpFired` effect, and the workaround that does work
(`long_press={false}`, or don't wire `MediaDragDrop`).

### Also noted, not fixed
- **The swallow can eat a deliberate menu-item tap.** On a browser that
  dispatches no click after a long press, the flag stays armed for the full
  700ms from menu-open; a fast tap on "Rename" inside that window is
  discarded, reading as a flaky menu. The fix (clear on `pointerup` next
  macrotask, or gate on proximity) risks *missing* the swallow on a device
  that dispatches the click later — the 700ms is deliberately generous.
  Needs a real device.
- **No focus restore on close** (`_close` re-parents while an item holds
  focus, so focus falls to `<body>`), and `onKeydown` doesn't trap Tab, so
  tabbing out of the portaled menu jumps to whatever follows `<body>`'s last
  child. `RowMenu` avoids this by refocusing its trigger; ContextMenu has no
  trigger and doesn't remember the row.
- **The hook's five `document` listeners are never removed** — bounded at one
  set per page and harmless once `menus` is empty, but the one asymmetry
  against `destroyed()`.
- **Everything DOM-dependent in the hook is untested** (`_stamp`, `bestMatch`
  deepest-match, `within`, the portal round trip, the timers, the swallow).
  Covering it needs jsdom, which `mix test.js` (plain `node --test`) doesn't
  provide.

Docs: `folder_explorer.ex` and the CHANGELOG said rows cost "two attributes";
it is three (`-kind`, `-value`, `-label`). Corrected.

## Verification

- `mix precommit` — **clean, exit 0** (compile `--warnings-as-errors`,
  `deps.unlock --check-unused`, format-check, `credo --strict`, dialyzer, JS
  tests).
- `mix test` on a real PostgreSQL — 43 doctests, 4314 tests, **8 failures, all
  pre-existing environment flakes**: the 7-test S015 block (passes in
  isolation: 17 tests, 0 failures) and the destructive orphaned-FK test, which
  needs a superuser to disable triggers. Identical set before and after these
  changes.
- `node --test test/js/*.test.cjs` — 8 ContextMenu cases, 52 total, 0 failures.
