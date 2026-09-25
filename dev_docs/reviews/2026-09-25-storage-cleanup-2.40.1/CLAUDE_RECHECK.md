# 2.40.1 storage cleanup: recheck of Grok's review (2026-09-25)

Grok reviewed the unpublished 2.40.1 cleanup (`837bae24`, `f12d0518`) and
left notes only (`GROK_REVIEW.md`, copied here from its scratch file). All
seven points hold; all are addressed before publishing.

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | bug | An IPv6 endpoint's public URL had no brackets (a dead link); ExAws presigns it unbracketed too; a zone id truncated the host. | `public_url` brackets a host containing `:`; `signed_download_url` refuses an IPv6 endpoint, so the bucket is proxied; an endpoint with `%` is refused. | `s3_endpoint_test.exs` |
| 2 | bug | Every custom endpoint was path style; Tigris refuses path style for buckets made after 2025-02-19. | `S3.virtual_host?/1` (Tigris): ExAws `virtual_host: true` for requests and presigns, and `bucket.host/key` public URLs. The others stay path style. | same |
| 3 | bug | The bucket form offered only public/private, so saving a signed bucket made it public; the moduledoc still said "future"; the test never checked the 300 s cap. | "Signed (short-lived link)" option; moduledoc; the test asserts `expires_in: 300` for plain and download opts. | `manager_bucket_access_test.exs` |
| 4 | suggestion | A set but unparseable endpoint (or one with a path) fell through to real AWS. | `S3.endpoint/1` returns `{:error, :invalid_endpoint}` (bad scheme, path, query, zone id); `aws_config/1` raises it into each operation's error; `Bucket.changeset/2` makes it a form error for cloud buckets. | `s3_endpoint_test.exs`, `bucket_endpoint_test.exs` |
| 5 | suggestion | R2's API host is not anonymously readable, so a public R2 bucket without `cdn_url` redirected to a 401; a nil provider URL made the bucket look empty. | R2 has no public URL without `cdn_url`; `Manager.bucket_access/4` proxies a public bucket whose provider has no URL instead of skipping it. CHANGELOG no longer claims R2 URLs work without a public domain. | `manager_bucket_access_test.exs`, `s3_endpoint_test.exs` |
| 6 | nit | A stale §11 bullet in the plan. | Removed; the status list says what is still open. | |
| 7 | nit | Two comments narrated history. | Trimmed. | |

Also in this release: #875 merged from `main` (review in
`dev_docs/pull_requests/2026/875-admin-header-descriptions/`).
