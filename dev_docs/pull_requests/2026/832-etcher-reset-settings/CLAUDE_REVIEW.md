# PR #832 — Annotation-settings reset on the profile settings page

**Author:** alexdont (`etcher-reset-settings`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-18 (post-merge)

3 files: a new `:etcher` section and `reset_etcher_settings` handler in
`PhoenixKitWeb.Live.Components.UserSettings`, an `EtcherReset` hook in
`priv/static/assets/phoenix_kit.js`, and a test file covering both halves.

## Verdict

The mechanism is right and the two halves genuinely match reality — I verified
each claim against Etcher's own source and against the code that writes the
user row, rather than against the PR description:

- `etcher_colors` / `etcher_line_params` are exactly the two keys
  `MediaCanvasViewer` persists (`@etcher_colors_key`, `@etcher_line_params_key`)
  — the server half clears everything the server ever wrote.
- `etcher:prefs` is exactly `_prefsKey` in `deps/etcher/priv/static/etcher.js`
  (unchanged in 0.15.0), and what it holds — `grid`, `connectors`, `panel`,
  `tools`, `colors`, `compact` — is what the button's copy promises.
- `push_event/3` from a LiveComponent reaches any mounted hook's
  `handleEvent`, and LiveView removes the listener on hook teardown
  (`__listeners` in `phoenix_live_view.js`), so no leak across `live_redirect`.
- `priv/static/assets/phoenix_kit.js` is a hand-maintained source, not a build
  artifact — `Mix.Tasks.Compile.PhoenixKitJsSources` copies it into the host —
  so editing it directly is correct.

Four findings, three fixed here. Nothing blocking.

## BUG — MEDIUM: the new copy was never extracted

The six new msgids reached no `.pot` and no catalogue, so
`mix gettext.extract --check-up-to-date` was red on `main` and every string
rendered as English in all seven translated locales. This is the fourth
recurrence of the same pattern in this repo (2.8.0, 2.9.0, 2.30.0, now).

The extract that caught it also pulled in `"Could not read the current
figures"` from this release's own integration-list work, and the merge carried
**"Could not reach the storage endpoint"** onto it as a fuzzy match in all
seven locales — a wrong sentence, *served*, where an empty msgstr would have
fallen back to correct English.

**Fixed.** Full round trip (`extract` → `merge` → translate → `compile` →
`merge` again at 0/0/0 → `--check-up-to-date`). All seven msgids translated by
hand in de/es/et/fr/it/pl/ru, grounded in each catalogue's existing terms for
*annotation* and *toolbar* and its address form. `grep -rc fuzzy` is 0 in every
translated catalogue; the untranslated baseline is unchanged at 72 (69 in
et/ru), i.e. nothing new was added to the backlog.

## IMPROVEMENT — MEDIUM: the hook landed under the wrong banner

`window.PhoenixKitHooks.EtcherReset` was inserted *after* the
`FolderDropUpload Hook` banner comment, so that banner labelled the new hook
and `FolderDropUpload` itself had none. Cosmetic, but this file is navigated by
those banners.

**Fixed** — the `EtcherReset` block now sits above the `FolderDropUpload`
banner.

## IMPROVEMENT — MEDIUM: no `test/js` coverage for the hook

Every other non-trivial hook in the bundle has a `test/js/*.test.cjs` case, and
`mix precommit` runs them. The two ways this hook fails silently — listening
for a different event name than the server pushes, and writing a key Etcher no
longer uses — are exactly what a test catches, because both leave a success
message on screen with nothing reset.

**Fixed** — `test/js/etcher_reset.test.cjs`: the hook exists, it clears
`etcher:prefs` on the pushed event, a throwing storage does not propagate, and
the key is pinned against Etcher's own `_prefsKey` (the same discipline
`transport_cache.test.cjs` applies to `phoenix.js`).

## NITPICK: `:not_found` does not mean "already reset"

The handler's comment claimed a delete of a key that was never saved answers
`{:error, :not_found}`. It does not: `Auth.delete_user_custom_field/3` runs
`update_all` with `custom_fields - key`, which matches the row whatever it
holds, so an absent key returns `{:ok, user}` after a no-op write. `:not_found`
means the *user row* is gone.

**Fixed (comment only).** The `reduce` is left as-is deliberately: skipping a
key that looks absent in `socket.assigns.user` would trust assigns that can be
stale, and the cost of being wrong (a silently unreset preference) is worse
than the cost of being right (one redundant `UPDATE`).

Consequence, accepted: a reset always issues two `UPDATE`s and two
`Events.broadcast_user_updated/1`, the first carrying a half-cleared user.
Subscribers converge on the second, so this is noise rather than a bug; a
single query dropping both keys would need a new `Auth` function, which is more
API surface than the saving is worth.

## IMPROVEMENT — MEDIUM (not fixed): the section renders on hosts with no annotations

`:etcher` is in `default_sections/0`, so every host's `/profile/settings` grows
an "Annotation tools" section even where the Storage module is off and nobody
has ever seen an annotation tool.

Not fixed, and I don't think it should be fixed the obvious way:
`UserSettings` deliberately checks no module state anywhere (`:integrations` is
opt-in precisely *because* the component has no scope to check with), and
gating on `Storage.enabled?/0` would hide the reset from a host that annotates
boards rather than files. A caller that knows its own installation can already
drop `:etcher` from `sections`. Recording it so the choice is on file.

## Limitations worth knowing (no action)

- **A viewer open in another tab keeps its own copy.** Etcher caches prefs in
  memory (`this._prefs`) and does not listen for `storage` events, and
  `MediaCanvasViewer` seeds `@etcher_colors` / `@etcher_line_params` at mount.
  So a tab that was already open re-saves the old answers on its next change,
  undoing the reset for that tab. Fixing it needs Etcher to re-read on a
  storage event; the hook's comment ("picks them up on its next mount") is
  accurate as far as it goes.
- **`fill` is not covered by either half.** Etcher's line-params payload
  carries `fill`, but `sanitize_line_params/1` drops it and it is not in
  `etcher:prefs` either, so it is stored nowhere and there is nothing to reset.
  Pre-existing, unrelated to this PR.
- The success message never clears until the page remounts — consistent with
  `start_page_message` next to it.

## Gate

`mix precommit` (compile with warnings-as-errors, `deps.unlock --check-unused`,
`test.compile`, format-check, credo --strict, dialyzer, JS tests) and the
Elixir suite against a real PostgreSQL. See the release commit.
