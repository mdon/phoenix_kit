# Review — Etcher 0.6.5 media-canvas wiring (line params, marker, full toolset)

**Reviewer:** Claude
**For:** Alex (Etcher author / `MediaCanvasViewer` owner)
**Commit:** `23d6a024` "Wire Etcher 0.6.5 into the Media viewer: line params, full toolset, marker"
(shipping in unreleased **1.7.131**; builds on PR #581's per-user color palette).
**Scope:** `lib/phoenix_kit_web/components/media_canvas_viewer.ex`,
`lib/phoenix_kit/annotations/annotation.ex`, V130 CHECK migration, the new
`annotation_kind_test.exs`.

## Verdict

**No release-blockers.** The work is solid — sanitize-on-read-and-write, server-side
marker byline (not the spoofable wire), and the schema+DB-constraint pair for the new
`marker` kind are all done right. Everything below is low-severity hardening or
duplication carried over from the colors pipeline. Most of it is **altitude**: the
line-params feature is a near-verbatim copy of the colors feature, so a single per-user
"Etcher prefs" mechanism would collapse the two and stop the next pref from becoming a
third copy.

Severity legend: `BUG - LOW` (real but rare/guarded), `IMPROVEMENT - MEDIUM`
(maintainability/efficiency), `NITPICK`.

---

## BUG - LOW — nil-uuid `current_user` raises `FunctionClauseError`

`media_canvas_viewer.ex` — `load_user_line_params/1` (~L482), `load_user_colors/1` (~L451),
and both `etcher:*-changed` handlers (~L184, ~L210).

All four match `%{uuid: uuid} = user` and then call `Auth.get_user(uuid)`, but
`Auth.get_user/1` is guarded `when is_binary(uuid)`:

```elixir
def load_user_line_params(%{uuid: uuid} = user) do   # matches uuid == nil too
  fresh = Auth.get_user(uuid) || user                # Auth.get_user(nil) → FunctionClauseError
```

If `current_user` is ever an **unpersisted** `%User{uuid: nil}` struct, the `%{uuid: uuid}`
clause matches with `uuid = nil`, `Auth.get_user(nil)` raises instead of returning `nil`,
and the viewer/handler crashes rather than falling through to the nil-tolerant catch-all.
Unreachable for a normal persisted session (real users always have a UUIDv7), so low
severity — but it's a latent crash inherited by the new code from the colors path.

**Fix (cheap):** add `when is_binary(uuid)` to the matching clauses so a nil-uuid user
falls to the existing default clause / `else` branch:

```elixir
def load_user_line_params(%{uuid: uuid}) when is_binary(uuid) do
```

---

## BUG - LOW (pre-existing) — non-marker shapes accept a client-supplied author

`media_canvas_viewer.ex` `put_marker_author/2` (~L580) + the EtcherAdapter create path.

`put_marker_author/2` correctly stamps the author **server-side** for `kind == "marker"`
and the adapter strips `creator_uuid` from the wire. But for **non-marker** kinds nothing
overrides `metadata.comment_author`, and the tooltip header reads that key. A crafted
`annotations-changed` payload for e.g. a rectangle with
`metadata: {"comment_author": "Admin"}` would persist and display the spoofed author after
reload.

Not introduced by this commit — the marker stamping is strictly *safer* than before — so
it's a residual class, flagged for completeness. **Fix:** have the adapter strip/override
`comment_author` for every kind (markers from the socket, others from the resolved
`creator_uuid`), so author display never trusts the wire.

---

## IMPROVEMENT - MEDIUM (altitude) — line-params is a verbatim twin of colors

`media_canvas_viewer.ex` — handler (~L209-228), loader (~L482-491), sanitizer (~L499-509)
each mirror their `colors` counterpart almost line-for-line. Only the storage key, the
sanitizer body, and the assign key differ.

The shared concept is **"a per-user Etcher pref stored in `custom_fields`, one set across
all viewers, merged into a freshly-read copy."** Adding the next pref (default font,
snap-grid, last-tool…) means hand-copying ~4 pieces (~50 lines) again — and if any copy
forgets the fresh-read/merge step, it reintroduces the stale-clobber bug the comments
warn about.

**Fix:** extract a pair, e.g.

```elixir
defp put_user_etcher_pref(socket, key, sanitized)      # the fresh-read + merge + update + assign
defp load_user_etcher_pref(user, key, sanitizer, default)
```

Each new pref then collapses to: one sanitizer + one registration in `update/2`. The
`colors-changed` and `line-params-changed` handlers both delegate, so the concurrency-safe
write lives in exactly one place.

---

## IMPROVEMENT - MEDIUM (efficiency) — two `get_user` SELECTs per mount

`media_canvas_viewer.ex` `update/2` (~L144-145).

```elixir
|> assign(:etcher_colors, load_user_colors(assigns[:current_user]))        # Auth.get_user(uuid)
|> assign(:etcher_line_params, load_user_line_params(assigns[:current_user])) # Auth.get_user(uuid) again
```

Both read the **same** user row to pull two keys out of the same `custom_fields` map, so
every mount — and every modal prev/next, since the LiveComponent remounts per file — does
2 identical SELECTs where 1 suffices. Folds naturally into the extraction above: read the
user once and pass the struct to both sanitizers (or return `{colors, line_params}`).

---

## IMPROVEMENT - MEDIUM (altitude) — byline logic is a third copy

`media_canvas_viewer.ex` `user_display_name/1` (~L597) is a hand-copy of the private
`PhoenixKit.Annotations.author_display/1` (and overlaps `User.full_name/1`) — the comment
even says *"Mirror of …"*. The "First Last / first / email-local-part" ladder now lives in
three places, kept in sync by hand.

The moment one is fixed (e.g. `full_name/1` honoring `account_type: "organization"`, or
trimming whitespace) a marker byline and the comment-thread byline on the **same file**
silently diverge — exactly the inconsistency this copy was meant to avoid.

**Fix:** promote `Annotations.author_display/1` to public (or add a shared
`PhoenixKit.Users.display_name/1`) and call it from the viewer.

---

## IMPROVEMENT - MEDIUM (altitude) — "skip the composer" / "stamp author" are per-kind lists

`media_canvas_viewer.ex` `etcher:shape-drawn` (~L239) gates the composer with a literal
`kind in ["text", "marker"]`, and author-stamping is a separate `put_marker_author/2`
clause keyed on `"marker"`. Two disjoint edit sites encode one idea ("this kind has no
composer, so stamp who drew it").

Each future composer-less tool must be appended to the list **and** (if it should show a
byline) separately added to `put_marker_author`'s guard — easy to update inconsistently
(skips the composer but shows no author, or vice-versa).

**Fix:** a small kind-metadata predicate, e.g. `kind_meta(kind) => %{composer?: bool,
author_stamp?: bool}`, so both branches are data-driven from one declaration per kind.

---

## IMPROVEMENT - MEDIUM — adding a kind is a 3-file, hand-retyped edit

`annotation.ex` `@kinds` (~L26) + the V130 migration's `CHECK (kind IN (...))` literal +
the viewer branches above. The SQL CHECK list duplicates `@kinds` as a string with no
compile-time link, so a new kind means a fresh `Vxxx` migration that **re-types the entire
enum** by hand — miss one existing value and you silently drop it from the constraint, or
`@kinds` and the DB constraint drift (schema allows a kind the DB rejects).

**Fix:** generate the CHECK body from `@kinds` in the migration helper (or drive validation
from `@kinds` alone), so a kind addition is a one-line list edit. The new
`annotation_kind_test.exs` is good — it pins the constraint accepts `marker` — keep that
pattern for whatever generates the list.

---

## Considered and dismissed (so you don't re-chase them)

- **opacity 0 → invisible strokes** — *not a bug.* `clamp_number(o, 0, 1)` faithfully
  matches Etcher's own `0..1` slider range; `0` is a legitimate value the Etcher UI itself
  allows, and `custom_fields` is per-user, so the worst case is a user setting their own
  default to transparent and dragging it back. Faithful-to-spec.
- **per-slider-tick DB writes** — *not a bug.* `etcher:*-changed` is Etcher's **save hook**
  (fires on commit, not on every intermediate tick), same as the existing colors hook, so
  it's one write per change, not per drag-pixel.
- **`<.select>` field errors / 429 retry / V129 down asymmetry** — separate (AI + billing
  migration) work, reviewed elsewhere; not Etcher.
