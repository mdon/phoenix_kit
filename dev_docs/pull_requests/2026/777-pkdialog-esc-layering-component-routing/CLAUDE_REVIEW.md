# PR #777 — PkDialog Esc layering + component routing (JS) · image-selector quality sweep

**Author:** mdon (`mdon/main`) · **Merged:** 2026-09-01 (`91110364`) · **Reviewed:** 2026-08-31

## Verdict

**The diagnosis behind every change is right, and the four Elixir/HEEx changes
are correct as written.** Four defects sit around them: one that makes this
PR's own headline fix — translatable digest strings — unreachable at runtime,
one in the sibling of the path matcher it fixed, and two in the new JS. All
four fixed here, each with a test that fails without the fix.

---

## Verified — correct, re-derived against the source

| change | verdict |
|---|---|
| `Tab.normalize_path/1` strips `?`/`#` | correct; both sides of every `matches_path?/2` clause normalize, so exact, prefix, regex and fn matches all benefit |
| `resolve_url(_, :card)` → `small \|\| medium \|\| thumbnail` | correct; now mirrors the `file_type: "image"` clause, which already ordered `small` before `thumbnail` |
| `resolve_url(_, :medium)` → `medium` first | correct; the old order served a 150px thumbnail for an explicit `:medium` request |
| `media_selector_modal` `size={:card}` | correct; an `aspect-square` grid tile is the card tier, and the media browser's own grid already passed it |
| `DigestWorker` → `use Gettext, backend:` + `gettext/2` | correct; `gettext/2`'s default domain **is** `"default"`, so the extracted references match the old `dgettext` calls |
| `.pot` currency | `mix gettext.extract` on the merged tree produces **zero** diff |
| catalogue completeness | ru went 82 → **0** untranslated, et held at **0** — the PR's claim holds |
| `isDialogOpenInBrowser` over `dialog[open]` | correct; morphdom strips the reflected attribute between a patch and the next `_sync` |
| CID as a push target | correct; a bare number is first-class in LiveView's `withinTargets`, an element is resolved via its (absent) `phx-target` |

---

## BUG — HIGH · The digest translations this PR added can never reach a recipient

`DigestWorker` now renders its strings through `gettext/2`, they extract, and
the PR ships Russian for all five of them. No recipient will see any of it.

`gettext/2` resolves the locale from the **calling process**, and an Oban
worker starts on the default one. Both digest surfaces freeze their text at
write time, and neither set a locale:

```elixir
# digest_envelope/4 — external channels
locale: recipient_locale(user),                              # resolved…
text: digest_text(count, type_label(type_key), cadence),     # …and ignored

# digest_inapp/4 — the persisted inbox row
text: digest_text(count, type_label(type_key), cadence),
```

The envelope *computes the recipient's locale on the line above* and hands it
to the channel, so the message goes out labelled `ru` with an English body.
The immediate path is not a counter-example: `DeliveryWorker` passes the locale
into `Render.render/2`, which uses it — for `link_for/2` only. `Render` calls
no gettext at all, so these digest strings are the only translated notification
text in the system, and they were rendering in `en` for everyone.

**Fixed.** A shared `digest_body/4` builds the text inside
`Gettext.with_locale(PhoenixKitWeb.Gettext, locale, …)`, used by both
surfaces; `nil` (no stored preference) keeps the default. `digest_envelope/4`
is now `@doc false` public — the repo's existing "public for testability"
convention (`migration_strategy.ex:466`, `v176.ex:108`) — because it is pure,
so the four new tests need no database.

`test/phoenix_kit/notifications/digest_worker_test.exs` — recipient locale,
`ru-RU` dialect narrowing, the `nil` fallback, and that the switch does not
leak into the calling process.

**Known limitation, left as is:** `%{label}` stays English. Type labels are
runtime registry data (`Types.list/0`), which `mix gettext.extract` cannot
see — the module's own moduledoc says so. Translating them is a Types-registry
change, not a digest change.

## IMPROVEMENT — MEDIUM · The other active-path matcher strips `?` but not `#`

The PR taught `Tab.normalize_path/1` to strip **both** a query and a fragment,
and tested both. `AdminNav.parse_admin_path/1` — the matcher behind every
sidebar item's active state — strips only the query:

```elixir
[path_part | _] = String.split(path, "?")
```

So the exact input that motivated the PR (a module publishing its full URL into
`:url_path`) gets a correctly-highlighted tab and an unhighlighted sidebar the
moment a fragment is involved. The `?tab=` extraction had the same gap one
level down: `?tab=files#top` yielded the tab `"files#top"`, matching nothing.

Core itself never produces either — `Auth.set_routing_info/3` assigns
`URI.parse(url).path`, already stripped — so this is reachable only through the
same external-module route as the bug the PR fixed, which is exactly why both
matchers should agree.

**Fixed.** Both splits now cut on `["?", "#"]`.
`test/phoenix_kit_web/components/admin_nav_active_path_test.exs` (5 tests, 2
of which fail on the pre-fix code).

## BUG — MEDIUM · `_pkStackClosePushed` can strand a dialog the server never hears about

The stacked-cancel path sets a boolean on the child element and relies on the
child's own `close` handler to clear it:

```js
top._pkStackClosePushed = true;
…
top.close();
```

The PR's own comment explains that this handler is unreliable here — *"the
queued close event was observed not to fire at all in this stack"*, which is
precisely why the parent pushes the child's event directly. When it does not
fire, the flag is never cleared. Nothing else clears it, and a `keep_in_dom`
dialog element outlives the interaction, so the **next** genuine close of that
child (Esc as the top dialog, or a backdrop click) hits
`if (!self._closeFromLV && !self.el._pkStackClosePushed)` and skips the push.
The server still believes the dialog is open, and the next patch re-opens it
via `_sync`.

**Fixed.** The flag is a timestamp (`_pkStackClosePushedAt`) and the
suppression is time-boxed to 1s. `close()` queues its event as a task, so a
real echo lands in the same tick and is still suppressed; a stamp whose event
never arrives expires instead of poisoning the element. Worst case degrades to
one duplicate push rather than a dialog that will not stay closed.

## IMPROVEMENT — MEDIUM · The CID-routing block is copy-pasted three times, and walks past nested LiveViews

`_pushClose`, the stacked-cancel relay and `InfiniteScroll.maybeLoad` each
carry their own copy of

```js
const comp = this.el.closest("[data-phx-component]");
if (comp) this.pushEventTo(parseInt(comp.getAttribute("data-phx-component"), 10), …)
```

Two problems the copies share. `closest("[data-phx-component]")` does not stop
at a **nested LiveView root**: for an element inside a nested LV that is itself
rendered inside a LiveComponent of the parent LV, it returns the parent's
component and pushes a cid that means nothing to this hook's socket. PhoenixKit
ships both shapes (`NotificationsBell` is a sticky nested LV; `MediaBrowser` is
a LiveComponent), so the combination is reachable. And a non-numeric attribute
would push `NaN`.

**Fixed.** One `ownerComponentCid/1` + `pushToOwner/4` pair, used at all three
sites and exported through the bundle's existing `module.exports` seam. The
lookup is `closest("[data-phx-component],[data-phx-session]")` — whichever
boundary is nearer wins, so a nested view root correctly means "push to the
view". `test/js/push_to_owner.test.cjs` (8 tests) covers component, no
ancestor, the nested-LV boundary, a junk cid, and a missing payload.

## Not fixed — on record

**The five Western catalogues lost ground.** The extraction refresh added 57
msgids, and only et/ru were completed:

| | de | es | fr | it | pl | ru | et |
|---|---|---|---|---|---|---|---|
| before | 160 | 160 | 160 | 160 | 160 | 82 | 0 |
| after | 212 | 212 | 212 | 212 | 212 | **0** | **0** |

That is the pre-existing backlog widening, not a regression this PR
introduced — untranslated entries fall back to the msgid, so nothing breaks —
but release notes must not claim complete catalogues, and 260 translations is
its own change, not a review fix.

**No JS test for the stacked-cancel path itself.** The routing helper is now
covered, but `showModal()`, `:modal` and the grouped-`cancel` behaviour it
works around have no jsdom equivalent; a test would assert the mock, not the
browser.
