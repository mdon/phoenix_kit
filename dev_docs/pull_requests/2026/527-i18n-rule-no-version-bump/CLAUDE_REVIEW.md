# PR #527 — Tighten i18n docs: never bump @version or write CHANGELOG (any module)

- **Author:** @timujinne
- **Base:** `dev` ← **Head:** `feature/i18n-rule-no-version-bump`
- **State:** MERGED (2026-05-09, commit `23816f32`, merge commit `80364425`)
- **Scope:** docs-only — `guides/per-module-i18n.md` (+17/-12), `dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md` (+14/-14)

Skill consulted: `elixir:using-elixir-skills` → no per-paradigm skill applies (no Elixir code touched). Reviewed as documentation/process change.

---

## Summary

Inverts the i18n rollout playbook + public guide so contributors and agents do **not** edit `@version` or `CHANGELOG.md` for any package — `phoenix_kit` core and every `phoenix_kit_<x>` child module alike. Replaces the previous "owned packages bump version + CHANGELOG" carve-out with a uniform maintainer-owned rule. Adds two pre-commit `git diff --staged` greps in step 9 to catch accidental edits.

Aligns with the existing project convention codified in `CLAUDE.md`:

> **CHANGELOG ownership:** entries written by the maintainer, not agents. If `@version` bump precedes the CHANGELOG entry, that's intentional — flag the gap and stop.

This PR extends that policy from core to all child modules — a useful tightening given the Phase 2 rollout history described in the PR body.

---

## Findings

### BUG - MEDIUM — CHANGELOG verification snippet always warns, regardless of state — **FIXED on `dev`**

`dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md:189-190`

```bash
git diff --staged mix.exs | grep -E '^\+.*@version' && echo "STILL TOUCHED @version — revert that line"
git diff --staged CHANGELOG.md | head -1 && echo "CHANGELOG should be clean — revert it from HEAD"
```

The first line is correct: `grep` exits non-zero on no match, so `&& echo` only fires when a `+` line touching `@version` exists.

The second line is broken. `head -1` exits **0 on empty input** — verified locally (`printf '' | head -1; echo $?` → `0`). So when `CHANGELOG.md` has no staged change (the desired state), `git diff --staged CHANGELOG.md` is empty, `head -1` exits 0, and the warning *always* fires. When `CHANGELOG.md` *is* staged, the user sees a stray `diff --git a/CHANGELOG.md …` line followed by the same warning. Either way the snippet teaches the contributor to ignore the warning, defeating its purpose — and silently devaluing the (correct) `@version` warning above it.

A correct conditional uses the file list, not a content pipe:

```bash
git diff --staged --name-only | grep -qx 'CHANGELOG.md' && \
  echo "STILL TOUCHED CHANGELOG.md — revert it from HEAD"
```

(Or equivalently `git diff --staged --quiet -- CHANGELOG.md || echo "..."`.)

**Resolution:** fixed in this branch (`dev`) — the snippet now uses `git diff --staged --name-only | grep -qx 'CHANGELOG.md'`.

### IMPROVEMENT - MEDIUM — `@version` regex matches inside multi-line strings/heredocs — **FIXED on `dev`**

Same hunk, line 189:

```bash
git diff --staged mix.exs | grep -E '^\+.*@version'
```

`^\+.*@version` will match any added line that contains the substring `@version` — including `@versions` (plural), an `@version` mention inside a `@moduledoc` heredoc, a comment, or a string literal. In a typical `mix.exs` the only realistic match is the actual attribute, so the false-positive risk is small, but the snippet is part of a doc that may be copy-pasted to other contexts. Tightening to the actual attribute form costs nothing:

```bash
git diff --staged mix.exs | grep -E '^\+\s*@version\s+"' && echo "STILL TOUCHED @version — revert that line"
```

This anchors on `@version "…"` specifically and skips heredoc bodies and comments.

**Resolution:** applied verbatim in this branch (`dev`).

### IMPROVEMENT - MEDIUM — Public guide setup checklist drops a numbered row but the prose neighborhood still says "11 steps"

`guides/per-module-i18n.md:91-102`

The checklist used to end at row 11 ("Bump module `@version` and add a CHANGELOG entry"). It now ends at row 10 with a `> **Do NOT bump…**` callout below. The change is clear in the table itself, but I did not see a line elsewhere in the guide that hard-codes the count of "11 steps" — searched and didn't find one, so this is a non-issue today. Flagging because the callout is positioned *after* the table separator (`---`) at the section boundary; on a quick skim it reads like the start of the next section. Consider moving it inside the table block (still as prose, just before `---`) so the visual scope is unambiguous: the checklist owns the "do NOT" rule, not the next section.

Optional, not blocking.

### NITPICK — Phase 2 module list duplicated across the two docs

`dev_docs/instructions/.../step-8` enumerates "newsletters / customer_support / emails / billing / ecommerce / legal / crm" inline as the seven Phase 2 packages. The public guide does not (correctly — it's an internal rollout detail). If a future Phase 3 happens, this list will need touching in only one place, but it would be easy to miss. Consider linking from step 8 to the rollout history table in the guide (`§ Where this fits in the rollout`, if that's the relevant section) rather than re-listing — keeps the source of truth singular.

Strictly stylistic; the current duplication does not cause a problem yet.

### NITPICK — "even by one patch" reads slightly off — **FIXED on `dev`**

`guides/per-module-i18n.md:453`:

> Edit `@version` in `mix.exs` (even by one patch).

Reworded to "even a single patch bump" in this branch.

---

## What's good

- **Anchor consistency** — both files now point at `[§ Version and CHANGELOG ownership](#version-and-changelog-ownership)`; the heading in the guide is `## Version and CHANGELOG ownership`, which produces the matching anchor. Verified.
- **Phase 2 history note in step 8.** "The earlier rollout … had every implementer agent bump `@version` and add a CHANGELOG entry — and the maintainer ended up overwriting both on every PR." Exactly the *why* future agents need to judge edge cases (e.g. "should I bump for an emergency fix?" → no, same rule). This matches the project's preferred style for codified guidance.
- **Retrofit checklist last item flipped consistently.** `guides/per-module-i18n.md:374` now reads "Do NOT bump `@version` or write a CHANGELOG entry" with the correct cross-link. No straggler "Bump and write CHANGELOG" lines remain in either doc — searched both files end-to-end.
- **Uniformity argument is well-grounded.** The PR body's three reasons (squash + release timing, release-notes-from-commits, merge-conflict frequency) match the lived behavior observed across Phase 2 PRs, and the rule generalizes cleanly to core (which already worked this way per `CLAUDE.md`).
- **Out-of-scope note is honest.** Calling out that the open `phoenix_kit_crm` PR still carries the old rule's edits — and that the maintainer can squash them out at merge — saves a future "wait, this PR violates the new rule" round-trip.

---

## Verdict

Docs-only change, already merged. Net positive: codifies a rule the maintainer has been applying by hand and removes the carve-out that was generating churn.

The two real defects (broken CHANGELOG check; loose `@version` regex) plus the phrasing nit have been fixed directly on `dev` in a follow-up commit alongside this review. The two remaining items (callout placement, Phase-2 module-list duplication) are stylistic and intentionally left as-is.
