# Issue #663 — post-release audit findings for 1.7.208–1.7.211

**Reporter:** timujinne (Tymofii Shapovalov)
**Investigated:** 2026-07-26, Claude Opus 5
**Outcome:** 2 of 4 fixed, 1 corrected (premise doesn't hold), 1 assessed as
largely already satisfied.

---

## 1. V157 `down/1` fails when `kind='image'` rows exist — CONFIRMED, fixed

Verified at `lib/phoenix_kit/migrations/postgres/v157.ex`. `down/1` re-adds the
narrower CHECK:

```sql
ADD CONSTRAINT phoenix_kit_annotations_kind_check
CHECK (kind IN (..., 'marker'))   -- no 'image'
```

Postgres validates a CHECK against every existing row on `ADD CONSTRAINT`, so a
single image annotation created after `up/1` makes the rollback raise `23514`
partway through the migration.

**Of the three options the issue offered, none is quite right as stated:**

- *Delete/convert image rows in `down`* — a rollback silently destroying user
  annotations is a worse outcome than a failed rollback.
- *`NOT VALID`* — makes `down` succeed by leaving a constraint that does not
  describe the rows already in the table. The next `VALIDATE CONSTRAINT`, or any
  tool that trusts the constraint, then hits the same problem with less context.
- *Document only* — honest, but leaves the operator with an opaque Postgres
  error at rollback time.

**Applied:** `down/1` now checks first and raises an actionable error naming the
row count and the two real ways forward (remove/convert the rows, or stay on
V157 — the widened CHECK is a superset of V156's and harmless). The check runs
before anything is queued, so no flush is needed and no half-applied DDL is left
behind when it raises. A `## down/1 is conditional, by necessity` moduledoc
section records the reasoning, matching the V156/V158 precedent for honest
one-way sections.

The underlying point is not really "the rollback has a bug" — it is that once a
user draws an image annotation, V156's constraint stops being a truthful
description of the data, and no schema migration can assert it. The fix makes
that legible rather than pretending otherwise.

## 2. V157 shipped without a migration test — CONFIRMED but narrower than reported, fixed

The suite does jump `v156_test.exs` → `v158_test.exs`. But the substantive
coverage the issue is worried about already exists:
`test/phoenix_kit/annotations/annotation_kind_test.exs` pins **both** layers
accepting `"image"` — the schema's `@kinds` and the DB CHECK — which is exactly
the V130/V157 regression class.

The genuine gap is one step removed: `annotation_kind_test.exs` asserts that the
kinds it names are present, not that nothing *else* disappeared. A later
migration re-stating the constraint while dropping a kind would leave it green
and silently break every annotation of the dropped kind.

**Applied:** `test/phoenix_kit/migrations/v157_test.exs` pins the CHECK's whole
vocabulary (all ten kinds), DB-level accept/reject, and the version marker, with
a moduledoc explaining why it is deliberately narrow rather than duplicating
`annotation_kind_test.exs`.

⚠️ **Not executed.** This environment has no PostgreSQL, so the integration tests
are auto-excluded (per `CLAUDE.md`, `mix precommit` is the bar here). The new
file follows `v158_test.exs`'s structure but has not been run green — it needs a
pass on a machine with the test DB before it can be trusted.

## 3. Stale Tessera CDN pin — PREMISE DOES NOT HOLD, no change made

The version-string observation is accurate: `priv/static/assets/phoenix_kit.js`
pins `tessera@v0.3.1` while `mix.lock` carries `tessera 0.3.4`. Two facts
undermine the conclusion:

**The recommended fix would break the loader.** `alexdont/tessera` has exactly
three tags — `v0.2.1`, `v0.3.1`, `v0.3.2`. There is no `v0.3.4`:

```
$ curl -o /dev/null -w '%{http_code}' -L .../gh/alexdont/tessera@v0.3.4/priv/static/tessera.js
404
```

Repinning to match `mix.lock` would make the lazy `<script>` 404, turning the
deep-zoom layer into exactly the silent no-op the in-file comment warns about.

**The pin is not serving stale JS.** The asset is byte-identical across the
CDN tags and the hex package:

```
7d0c1493a2b4b87b01aea3e20480e3be  cdn tessera@v0.3.1/priv/static/tessera.js
7d0c1493a2b4b87b01aea3e20480e3be  cdn tessera@v0.3.2/priv/static/tessera.js
7d0c1493a2b4b87b01aea3e20480e3be  deps/tessera/priv/static/tessera.js   (hex 0.3.4)
```

0.3.2 → 0.3.4 changed Elixir-side code only; `tessera.js` has not moved since
0.3.1. So the fallback currently serves the correct, current engine.

**Left alone deliberately.** Bumping to `v0.3.2` would be churn with no
behavioural effect and would still not match `mix.lock`. The real fix belongs
upstream — `alexdont/tessera` should tag its releases so the `gh@<tag>` fallback
can track the hex version. Worth raising there; not worth a local edit that
trades a cosmetic mismatch for a live 404 risk.

This one is a good illustration of why a version-string diff needs a content
check before it becomes a fix.

## 4. #652 / host `:browser` pipelines — largely already satisfied

Accurate that `3e40bc5c` added `fetch_live_flash` to the dev/test router only.
But the standard router `mix phx.new` scaffolds already carries
`plug :fetch_live_flash` in its `:browser` pipeline, so a conventionally
generated host is unaffected. The exposure is limited to hand-rolled pipelines
that dropped it.

**No change made.** If this is worth guarding, the right home is a
`mix phoenix_kit.doctor` check — doctor already reads the host's `application.ex`
and router — rather than an upgrade note that only reaches people who read it.
Recorded here as the open option rather than built speculatively.
