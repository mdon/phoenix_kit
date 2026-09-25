## Summary

The patch does what it claims for the common cases: `list_files(bucket_uuid:)` filters through active location rows (and still drops trashed and system-managed files, without multiplying rows), a bare host, `host:port`, or `http(s)` URL is read once for both ExAws and `public_url` in path style, and `access_type: "signed"` presigns for 300 seconds or proxies instead of redirecting at the plain object URL. Private and signed buckets are skipped by `Manager.public_url/2`, and `FileController` still refuses a plain redirect for a user-library file. Gettext catalogues only drop the five unused Default Bucket strings; no msgstr changed and no fuzzy flag was added. The holes are in the new URL builder (IPv6, and path-style for Tigris) and in the fact that the admin form still cannot keep a bucket on `"signed"`.

## Issues

### Issue 1 -- Severity: bug
- File: lib/modules/storage/providers/s3.ex:90
- Description: `endpoint/1` accepts an IPv6 URL (`http://[::1]:9000` parses as host `"::1"`, port 9000) but `public_url/2` interpolates the host with no brackets, producing `http://::1:9000/photos/a/b.jpg`. `URI.parse/1` reads that as host `nil`, port 80, so a browser never connects. ExAws request URLs go through `URI.to_string/1` and are correct (`http://[::1]:9000/...`), which breaks the "requests and public URLs name the same host" claim in `endpoint/1`. Presigned URLs are built the same unbracketed way (`ExAws.S3` concatenates `config[:host]`), so a signed bucket on that endpoint redirects at the same dead URL while HEAD/PUT succeed. A link-local zone id is worse: `http://[fe80::1%eth0]:9000` is parsed as host `"fe80"`. A bare `::1` does not parse and is then treated as plain AWS (see issue 4).
- Suggestion: Bracket any host that contains `:` when building `public_url/2` (`"[#{host}]"`). For presigns, either post-process only the URL's host (the signed host header must stay unbracketed, matching what ExAws signed) or proxy IPv6 endpoints instead of redirecting. Reject or preserve a zone id instead of truncating at `%`.
- Status: open

### Issue 2 -- Severity: bug
- File: lib/modules/storage/providers/s3.ex:90
- Description: Every custom endpoint is published path-style (`https://host/bucket/key`), and `aws_config/1` never sets ExAws `:virtual_host`, so presigned URLs are path-style too. That matches MinIO, B2 (Backblaze's own public samples are path-style), and Wasabi. It does not match Tigris, which is a first-class provider whose form placeholder is `fly.storage.tigris.dev`. Tigris rejects path-style for buckets created on or after 2025-02-19: `https://fly.storage.tigris.dev/<bucket>/<key>` is 403, including presigned URLs; the working form is `https://<bucket>.fly.storage.tigris.dev/<key>`. `FileController` redirects `access_type: "public"` straight at `public_url/2`, so a new Tigris bucket still does not serve. `bucket_access/4` will not fall back to the proxy, because ExAws returns `{:ok, url}` for a URL Tigris then refuses.
- Suggestion: For provider `"tigris"`, set `virtual_host: true` on the ExAws config (so requests and presigns match) and build `public_url/2` as `scheme://#{bucket_name}.#{host}#{port}/#{key}`. Leave path-style in place for MinIO, B2, and Wasabi. Add a test that the two shapes stay in lockstep.
- Status: open

### Issue 3 -- Severity: bug
- File: lib/modules/storage/web/bucket_form.html.heex:308
- Description: `"signed"` is now a real serving mode (`Manager.bucket_access/4` presigns or proxies, and `Manager.public_url/2` will not hand out the object URL), but the bucket form still offers only `"public"` and `"private"`. `Phoenix.HTML.Form.options_for_select/2` cannot mark `"signed"`, and a single `<select>` with no selected option submits its first value. Saving any edit of a signed bucket (keys, priority, endpoint) casts `access_type` back to `"public"`, which is the redirect this release says it removed. Nothing in the admin UI can turn the mode on. `Bucket`'s moduledoc still calls signed a "future implementation" (`lib/modules/storage/schemas/bucket.ex:45`). The new unit test only checks that the mock URL starts with `https://signed/k`; it never reads `:expires_in`, so dropping the 300-second cap would still pass.
- Suggestion: Add a "Signed (presigned URL)" option to that select, and fix the schema blurb. In `manager_bucket_access_test.exs`, assert the signer is called with `expires_in: 300` for both `nil` and download opts.
- Status: open

### Issue 4 -- Severity: suggestion
- File: lib/modules/storage/providers/s3.ex:118
- Description: A non-blank endpoint that `URI.parse/1` does not accept (`ftp://…`, `s3://…`, bare `::1`, `//host`) returns `nil`, and both `public_url/2` and `aws_config/1` treat `nil` as "no custom endpoint": requests are signed against real AWS and public URLs are `*.amazonaws.com`. Previously any non-empty `endpoint` was passed through as the host, so a typo failed to connect instead of talking to Amazon. A path is also dropped while the parse still succeeds (`http://minio.local:9000/s3` becomes host `minio.local`), so a gateway prefix is stored as a healthy endpoint and both requests and URLs hit the host root. The `ftp://nope` example in `s3_endpoint_test.exs` locks in the `nil` return.
- Suggestion: Distinguish "field blank" from "field set but unusable". If the trimmed value is non-empty and the parse fails, or the URL has a non-empty path other than `/`, do not fall through to AWS — fail the bucket operation (and the connection test) with a reason. Keep blank/`nil` as plain AWS.
- Status: open

### Issue 5 -- Severity: suggestion
- File: lib/modules/storage/providers/s3.ex:88
- Description: For Cloudflare R2 the new URL is the S3 API host (`https://<account>.r2.cloudflarestorage.com/<bucket>/<key>`). That host is not anonymously readable; public reads are only an `r2.dev` subdomain or a custom domain, which this code already prefers when `cdn_url` is set (and that branch was already correct before this patch). With `cdn_url` nil and `access_type: "public"`, `FileController` still redirects the browser at the API URL, which 401s. The changelog lists R2 among the providers that now get working public URLs; only the `cdn_url` case actually does, and it did not depend on this change. Path-style itself is fine for signed R2 API calls.
- Suggestion: When the provider cannot serve an anonymous GET on the API host (R2), do not redirect at `public_url/2` unless `cdn_url` is set — proxy, or return nil from `Manager.public_url/2` and make `bucket_access/4` proxy instead of treating a nil provider URL as "not found" (`check_bucket_for_file/4` currently skips a nil `bucket_access` result and can end in `{:error, :not_found}`).
- Status: open

### Issue 6 -- Severity: nit
- File: dev_docs/plans/2026-09-22-storage-libraries.md:1230
- Description: The new status list correctly marks endpoint normalization and signed buckets as fixed, then leaves the old bullet in place. That bullet still says `aws_config/1` does not normalize the endpoint, which this patch does, and it repeats the integration-ownership item already called out as still open on the previous line.
- Suggestion: Delete the stale bullet. Leave only the "still open" credential-ownership / SSRF line.
- Status: open

### Issue 7 -- Severity: nit
- File: lib/modules/storage/services/manager.ex:519
- Description: Two new comments narrate the change rather than a constraint that is still true: "It used to fall through to the public redirect" (`manager.ex:519`) and "It used to filter on `f.bucket_uuid`, a column files never had, so the option raised" (`storage.ex:5193`). The why is already in the function docs and the changelog.
- Suggestion: Drop the history sentences. Keep the comment that a signed bucket must not be given its plain object URL, and the one that a file is in a bucket when an instance has an active location there.
- Status: open
