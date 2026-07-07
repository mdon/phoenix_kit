# PR #622 — Fix jobs admin crash on scheduled-job fields (uuid, resource_uuid)

**Author:** alexdont (`fix/jobs-scheduled-job-uuid`)
**Merge:** `4e60fb99` · **Reviewer:** Claude · **Date:** 2026-07-07

## Summary

Three-line fix in `lib/phoenix_kit_web/live/modules/jobs/index.html.heex`:

- `phx-value-id={job.id}` → `phx-value-id={job.uuid}`
- `String.slice(job.resource_id || "", …)` → `String.slice(job.resource_uuid || "", …)`
- `@selected_scheduled_job.resource_id` → `@selected_scheduled_job.resource_uuid`

## Verdict

**Correct.** No issues.

The `PhoenixKit.ScheduledJobs.ScheduledJob` schema uses
`@primary_key {:uuid, UUIDv7, autogenerate: true}` and `field :resource_uuid, UUIDv7`
— there is **no** `id` or `resource_id` field. The old template referenced those
non-existent struct keys, which `KeyError`s at render → the jobs admin scheduled-jobs
tab crashed. The rename aligns the template with the schema.

The round-trip is consistent end to end:
- `phx-value-id={job.uuid}` now supplies the uuid to the `"show_scheduled_job"`
  handler (`index.ex:154`, `%{"id" => id}`), which calls
  `load_scheduled_job(id)` → `repo.get(ScheduledJob, id)`. `Repo.get/2` keys on the
  schema primary key (`:uuid`), so passing the uuid is exactly right (passing the
  old `job.id` would have looked up a non-existent PK).
- `job.resource_uuid` is a `UUIDv7`-typed string when loaded, so
  `String.slice(… || "", 0, 8)` is safe, and the `|| ""` guards the nil case.

## Findings

None.
