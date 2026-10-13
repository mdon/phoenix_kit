# PR #924 — modal input protection

Reviewer: Codex · Date: 2026-10-13 · Status: reviewed and fixed, unreleased

Reviewed the merged PR and Claude's follow-up in `32a02d503`.

## Findings

- **BUG - MEDIUM (fixed): native dialogs were missing from the class-modal Escape decision.**
  Claude correctly stopped walking down the `.modal-open` stack, but `<.modal>` opens
  a native `<dialog>` without that class. A dirty class modal underneath it still
  swallowed Escape and nudged the wrong box. An open native dialog now owns Escape;
  typing in a native child also cannot arm its class-modal ancestor.
- **BUG - MEDIUM (fixed): submitting a class-modal form cleared its guard before the save succeeded.**
  Validation or persistence can fail, leaving unsaved input with no protection.
  Submission now retains the guard. After a successful save, a form that remains
  open can clear it with `push_event(socket, "pk:dialog-saved", %{id: modal_id})`.
  Both modal implementations accept this signal, resolving Claude's add-another
  limitation without treating a failed save as a success. A targeted DOM
  `pk:dialog-saved` event works too. The component documents the server signal.

## Validation

The real document listeners are exercised in `test/js/backdrop_click.test.cjs`:
class stacks, native dialogs above class modals, closed native dialogs, failed
submission, nested inputs, and explicit successful saves. Two new regressions
failed against the reviewed commit before the fixes. The textarea size keeper
and press/release backdrop checks retain their existing behavior.

The textarea id-to-size map remains scoped to the browser page's lifetime. Its
unbounded number of distinct ids is a minor existing limitation; it does not
warrant changing form-state behavior in this review.
