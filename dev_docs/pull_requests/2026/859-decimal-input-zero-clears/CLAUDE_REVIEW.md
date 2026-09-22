# PR #859 — decimal_input: a zero clears itself on focus

**Author:** timujinne · **Merged:** 2026-09-22 (e61c1f61) · **Reviewer:** Claude · **Released in:** 2.37.4

## Summary

`<.decimal_input>` gets inline `onfocus`/`onblur` handlers. On focus, a
zero-like text (`0`, `0,00`, `-0`, `,0`) is remembered and the field
empties, so typing `1` gives `1` instead of `10`. On blur, an
untouched empty field gets the zero back. A host's own
`onfocus`/`onblur` are popped out of `@rest` and chained after the
component's, so the attribute appears only once. The tests run the
handler strings in node against a stand-in element.

Verdict: the idea and the host-chaining are sound. Inline handlers are the
right tool here: no hook, so hosts need no JS wiring, and they survive
`live_redirect`. The handlers did lose their state across LiveView patches,
though, and they missed two paths where the emptied text escapes to the
server. All four findings are fixed below.

## Findings

### BUG - MEDIUM — the remembered zero was stripped by any LiveView patch while focused

The zero was parked in `this.dataset.pkZero`, which is a `data-pk-zero`
attribute. When LiveView patches a focused text input
(`dom_patch.js` → `DOM.mergeFocusedInput` → `mergeAttrs(target, source,
{exclude: ["value"]})`), it removes every attribute the server-rendered
element doesn't have (checked against the vendored LiveView 1.2.12
bundle). So any re-render of the surrounding LiveView or component while
the field is focused dropped the marker. That covers a `phx-focus`
handler that assigns anything, a PubSub update, a timer, or a sibling
component's event. Blur then found nothing to restore, and the field
stayed empty and submitted `""`.

**Fix:** the zero now lives in expando properties (`this.__pkZero`,
`this.__pkZeroEdited`). A focused element is kept, not replaced, and
morphdom never touches its JS properties. A test asserts that no handler
uses `dataset`.

### BUG - MEDIUM — Enter in the emptied field submitted `""`

Pressing Enter right after focusing a zero field triggers implicit form
submission before any blur. The form sent `""`, not `0`, which becomes
`{:error, :empty}` or "can't be blank" for a value the person never
changed. That breaks the moduledoc's "nothing was entered, nothing
changes".

**Fix:** a third inline handler, `onkeydown`, restores the zero when the
key is Enter, a zero is remembered, and the field is still empty. Keydown
runs before the implicit submit, so the form data carries the zero. A
host's `onkeydown` is chained exactly like `onfocus`/`onblur`.

### BUG - MEDIUM — a `readonly` zero field was cleared on focus

`readonly` inputs take focus and are submitted. Clicking one blanked it,
so it looked editable when it wasn't, and Enter then submitted `""`.

**Fix:** the zero test starts with `!this.readOnly&&`. A node test covers it.

### IMPROVEMENT - MEDIUM — typed-then-erased left `phx-change` believing `""`

The sequence: focus `0`, type `5`, erase it, tab away. `phx-change` last
sent `""`, and blur restored `0` with a programmatic set, which fires no
event. The server kept `""` (a blank-field error, say) while the field
showed `0`. On the next patch the value attribute doesn't change, so
LiveView leaves the DOM value alone and the mismatch stays until submit.

**Fix:** focus registers a single stable input listener
(`this.__pkZeroOnInput`, idempotent under `addEventListener`) that marks
the clear as edited. When the restore follows an edit, it dispatches a
bubbling `input` event, so `phx-change` hears `0`. An untouched
focus/blur still fires nothing. It doesn't mark the field used or run a
validation. Node tests cover both paths.

### NITPICK — test helper unescaped only `&#39;`

The new arrow function puts `>` in the handler, and the markup escapes it
to `&gt;`. The shared `handler/2` test helper now unescapes all five
entities, and the per-test `attr` closures are gone.

## Not changed

- **Clearing vs `select()` on focus.** Selecting the zero would avoid the
  restore machinery entirely. But a mouse click's `mouseup` collapses
  the selection in some browsers (WebKit), so the PR's clear-and-restore
  is the more reliable choice. Kept.

## Validation

- `mix test test/phoenix_kit_web/components/core/decimal_input_test.exs`: 15 tests, 0 failures (node 24 present, so the browser-like runs execute).
- `mix precommit`: green.
