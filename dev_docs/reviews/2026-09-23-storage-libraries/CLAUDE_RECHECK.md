# Storage libraries phase 1 — recheck of Grok's unfinished pass (2026-09-23)

Grok reviewed the 2.38.0 work (V202 storage libraries, the Settings →
Libraries tab, #865's burn refresh), ran out of credits, and left its fixes
uncommitted with no review notes. Claude read the whole diff, checked each
change, finished the parts it had left undone, and committed it all.

Grok found five real bugs. Each one has a test that fails without its fix;
all four new tests were run against the tree with the fixes stashed.

| Finding | Fix | Test |
|---|---|---|
| **BUG - MEDIUM.** The V202 slug backfill ranked full slugs and then truncated them. `Foo`, `Foo!` and `Foo-2`, or two long names that only differ past character 58, got the same slug, so the unique index aborted the migration. | Slugs are assigned one library at a time, each checked against the slugs already written for that owner. | `v202_test.exs` "a re-run does not give two libraries the same slug" |
| **BUG - MEDIUM.** The Libraries tab offered Delete on a library whose only contents were in the trash (or were system-managed). `delete_library/1` and the foreign key refuse that delete. | `list_system_libraries_with_stats/0` returns `holds` (any row at all), and Delete is disabled on it. | `settings_libraries_test.exs` "a library whose only folder is in the trash…" |
| **BUG - MEDIUM.** The media browser's upload summary was set with `put_flash` on a LiveComponent. A component's flash reaches the page only when the component also navigates, so the summary never showed. | `parent_flash/3` sends the flash to the parent, and `handle_parent_info/2` puts it. | `media_library_upload_test.exs` |
| **BUG - MEDIUM.** Uploading bytes that already sit in another library (dedup is per uploader, install-wide) was counted as an ordinary upload error. The summary blamed storage buckets. | An `{:postpone, :in_other_library}` upload gets its own pluralised `:warning`. | same |
| **IMPROVEMENT - MEDIUM.** After a viewer's own burn, `burn_stored` records the bytes' checksum while the poke (#865) names the drawing's fingerprint. The two never matched, so the canvas remounted for the same picture. | `showing_burn?/2` treats either id as the picture already on screen. | `burned_copy_test.exs` "a poke while the burned copy is showing" |

Left unfinished by Grok and done here:

- Translations for the new plural message in all seven locales (three forms
  for pl and ru).
- The `chain_hash` restamp for the edited `v202.ex`.
- A CHANGELOG line under 2.38.0.
- The full suite and the release gate.

Not changed, noted: the media browser's other `put_flash` calls (folder
created, renamed, …) have the same component-flash limit. Most follow a
navigation, which carries the flash. They were not audited one by one.
