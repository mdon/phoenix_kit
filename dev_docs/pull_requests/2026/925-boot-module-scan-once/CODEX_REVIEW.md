# PR #925 — reuse the boot module scan

Reviewer: Codex · Date: 2026-10-13 · Status: reviewed, unreleased

No additional defect found in the merged change or Claude's review.

Checked the inventory, fingerprint, per-directory assembly, registry callers,
fallbacks, and tests. Configured modules remain part of the fingerprint and
result; code-path ordering is reapplied without another beam scan. Adding or
removing a directory changes the fingerprint, and a recent write prevents
remembering an unsafe scan. The old memo tuple becomes a cache miss.

The documented same-size/same-mtime replacement limitation remains explicit;
`refresh_cache/0` is the unconditional rescan escape hatch. Runtime cache reads
still share the existing cold-scan lock, and boot's sequential reads reuse the
remembered scan. The longer registry timeout covers a genuine cold scan.
