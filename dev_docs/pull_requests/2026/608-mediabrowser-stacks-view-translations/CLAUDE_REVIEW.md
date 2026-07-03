# PR #608 — MediaBrowser: Basecamp-style stacks view + Estonian/Russian translations

**Author:** alexdont (Sasha Don) · **Base:** `main` · **Merged:** 2026-06-26
**Reviewer:** Claude (Opus 4.8)
**Scope reviewed:** `media_browser.ex`, `media_browser.html.heex`, `priv/static/assets/phoenix_kit.js`, and the `priv/gettext/*` churn.

Skill invoked first: `elixir:phoenix-thinking` (LiveComponent / hooks / PubSub-style `push_event`).

---

## Summary

The stacks-view feature (Elixir + HEEx + JS) is well-built and internally consistent:
the StackMemory localStorage round-trip, the FLIP fly-out/fly-back animations, the
per-stack pagination, and the view-mode whitelist extensions all check out. The one
**concrete defect is in the translations**, not the feature code, plus some
documented-but-noted improvements.

---

## Findings

### BUG - LOW (i18n) — `Created by %{name}` fuzzy mistranslation in ru/et — **FIXED**

`Created by %{name}` is the folder-header creator label
(`media_browser.html.heex:688`, `{gettext("Created by %{name}", name: @folder_creator_name)}`),
a **pre-existing** source string. This PR's `gettext.extract`/`merge` first surfaced it
into the ru/et catalogs as a **`fuzzy` auto-fill**:

| locale | msgid | PR's msgstr | meaning | placeholder |
|---|---|---|---|---|
| ru | `Created by %{name}` | `Создайте` | "Create!" (imperative) | **`%{name}` dropped** |
| et | `Created by %{name}` | `Loo` | "Create" (imperative) | **`%{name}` dropped** |

Two problems: the text is semantically wrong, and it **drops the `%{name}` placeholder**.

**Why it matters / current blast radius:** both entries were flagged `fuzzy`, and gettext
**ignores fuzzy translations at compile time and falls back to the English msgid**, so
users currently see English "Created by Alice" — *not* the wrong "Создайте"/"Loo". So
there is no live regression today. But it is a latent landmine: the day anyone clears the
`fuzzy` flag (a translator "confirming" it, or a future merge), the creator's name
silently disappears and the label reads "Создал" → "Создайте"/"Loo". It also contradicts
the PR's claim that ru/et "come out fully translated."

**Fix applied:** corrected to `Создал %{name}` (ru) / `Loonud %{name}` (et) and removed the
`fuzzy` flag so the proper translation is now active. (`Создал %{name}` is the direct
"created by" rendering; a maintainer may prefer the gender-neutral `Автор: %{name}` — flagging
the choice.)

### IMPROVEMENT - MEDIUM (i18n) — ~36 new fuzzy auto-fills render as English — *not fixed (out of scope)*

The re-extraction did good work (empty/untranslated strings dropped 14 → 1 in both
locales), but fuzzy entries rose **ru 165 → 201, et 166 → 202** — ~36 newly-surfaced
strings were auto-matched from translation memory and left `fuzzy`. gettext renders fuzzy
as the English fallback, so those strings show untranslated in ru/et despite the
"fully translated" claim.

Verified: **none of these except `Created by %{name}` carry `%{}` placeholders**, so there
is no crash / placeholder-mismatch risk — purely a completeness gap. Recommend a follow-up
de-fuzz pass (review `mix gettext.merge` output and confirm/clear the fuzzies). Not done
here because most are unrelated to the stacks feature and hand-translating ~70 entries
would be disproportionate to this release and risks new errors.

### IMPROVEMENT - MEDIUM (perf) — `assign_stacks/1` N+1 — *acknowledged by author, unchanged*

In stacks mode `assign_stacks/1` issues one `Storage.list_files_in_scope/2` per child
folder (previews) **plus** one per expanded stack, re-run on every component reload
(`update/2` → load → `assign_stacks`). The author's own comment acknowledges and defers it
("Cheap enough for a typical folder count; revisit with a batched query if folder lists
grow large"). Fine for typical folder counts; recorded for the future batched-query
follow-up.

### NITPICK (consistency) — `drop_outline_color/1` uses legacy daisyUI-4 `--wa`

```elixir
defp drop_outline_color(color), do: folder_color_hex(color) || "oklch(var(--wa))"
```

The fallback uses the legacy daisyUI-4 raw-component var `--wa`, while the **new JS** drag
outline in the same PR uses the daisyUI-5 form `var(--color-primary)` — and the PR's own JS
comment notes daisyUI 5 dropped the legacy raw vars in favor of complete `--color-*` values.
For default-colored folders (`folder_color_hex/1 → nil`) the drop outline/ring resolves to
`oklch(var(--wa))`, which is invalid if `--wa` is undefined under daisyUI 5 → no outline
shown. Because the JS always receives the non-empty string from `data-drop-color`, its own
`|| "var(--color-primary)"` fallback never fires for these.

**Not fixed:** this is the file's pre-existing convention (`media_browser.html.heex:1374,1968`,
`folder_explorer.ex`), so changing only this one call would diverge it. Worth a future sweep
to `oklch(var(--color-warning))` / `--color-primary` across the file.

### NITPICK (reuse) — per-stack pagination reimplements `<.load_more>`

The expanded-stack "Showing X of Y / Load more" block hand-rolls markup that the core
`<.load_more>` component (documented in CLAUDE.md) already provides. Per-folder `phx-value`
and custom layout make direct reuse awkward, so acceptable — noted for possible
consolidation.

---

## Verified correct (spot-checks that passed)

- **StackMemory round-trip** — hide-before-paint + `restore_stacks` push + `pk:stacks` echo
  + reveal, with a 600ms safety reveal if the echo never lands; self-prunes invalid uuids.
  Persisting from the server echo (not the DOM) correctly avoids reading a mid-fly-back stack
  as still-open.
- **`restore_stacks`** validates uuids against `@folders` (MapSet membership) — no
  `String.to_atom`/unsafe-input path — and preserves open order.
- **View-mode whitelists** (`set_view_mode/3` guard and `load_user_view_mode/1`) both
  correctly extended with `"stacks"`.
- **`push_event` from a LiveComponent** reaches the `StackMemory` hook (`handleEvent` is
  global) — correct.
- **New placeholder strings** `%{days} days`, `Heading %{level}`,
  `Showing %{loaded} of %{total} %{noun}` translate with placeholders intact in ru/et.
- **LiveComponent lifecycle** — no DB queries in `mount/1`; loads happen in `update/2` and
  event handlers (the "no queries in mount" Iron Law is LiveView-specific and N/A here).
- **Placeholder integrity sweep** across all 8 `.po` files: the only PR-introduced singular
  placeholder drop is `Created by %{name}` (now fixed). Remaining mismatches
  (`Requires %{module}` in de/es/fr/it/pl) are pre-existing stub translations, unchanged by
  this PR.

---

## Outcome

- Fixed the `Created by %{name}` ru/et translation (de-fuzzed + placeholder restored).
- Everything else is either author-acknowledged, pre-existing convention, or a noted
  follow-up; no functional defect in the stacks feature itself.
