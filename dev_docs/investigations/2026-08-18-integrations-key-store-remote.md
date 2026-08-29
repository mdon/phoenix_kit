# An optional off-host copy of the encryption key

2026-08-18. S004 part 3. Branch `security-integrations-encryption-key`.

Frame set by the owner and not up for revision: the solution must suit **every**
PhoenixKit user, not configure our four sites. AWS is an addition, not a
foundation. A design that makes someone open an AWS account before they can use
integrations at all would be the wrong answer, so this one does not.

## The owner's idea, weighed seriously

The suggestion was to send the key to AWS **through the integrations mechanism
itself** rather than by a separate path. It is the right instinct — one
configuration surface, visible in the admin UI, no second concept — and it
cannot carry the read path. The reason is structural, and it is in this
repository rather than in general principle:

* `secret_key` is listed in `Encryption.sensitive_fields/0`
  (`encryption.ex:68-72`);
* `validators.ex:433` maps an object-storage connection's `data["secret_key"]`
  to its `secret_access_key`;
* therefore those credentials are stored **encrypted with the integration key**.

Reading the key out of a bucket whose credentials are encrypted under that same
key requires the key you are trying to fetch.

The dangerous part is that **writing works**. During a rotation the old key is
live, so the credentials decrypt and the backup is written and verified. It is
only on recovery — the local copy gone, which is the entire reason the backup
exists — that it turns out to be unreachable. That is a backup that cannot be
restored from, which is worse than having none, because you stop looking for a
real one.

So credentials come from `ExAws`'s own resolution: environment variables, an
instance role, or an explicit `:ex_aws_config`. On AWS with an instance role
there is no stored secret at all and the circularity disappears entirely.

What the integrations system *can* usefully hold is the part that is not secret
— which bucket, which region, which object. That keeps the spirit of the idea
and is a separate, later step; nothing here needs it.

## What was built

### `KeyStore.Chain` — the piece that makes remote storage an addition

Composes stores. Reads are answered by the first that has the secret; writes go
to **all** of them.

    config :phoenix_kit,
      integrations_key_store:
        {PhoenixKit.Integrations.KeyStore.Chain,
         stores: [
           PhoenixKit.Integrations.KeyStore.File,
           {PhoenixKit.Integrations.KeyStore.S3, bucket: "my-ops-bucket"}
         ]}

Two decisions worth stating:

* **A write that fails anywhere fails.** A partial success reported as `:ok`
  produces exactly the belief this area exists to prevent — that the secret is
  safe in a place it is not. A backup that quietly stopped being written is not
  a backup.
* **A read answered by anything other than the first store is logged at
  `:warning`.** That is the recovery case: the local copy is gone and the site
  is running on a spare. Silence there lets a site run for months on its last
  remaining copy.

### `KeyStore.S3` — optional, and free of new dependencies

`ex_aws` and `ex_aws_s3` are already core dependencies, so this adds none. It
talks to anything S3-compatible — AWS S3, Cloudflare R2, Backblaze B2, Tigris,
MinIO — which matters for the "suits every user" frame: the feature is not tied
to one vendor's account.

One object, the secret as its body, written with `AES256` server-side
encryption. Every callback fails on a missing bucket **before** any network
call. Errors are reduced to something actionable (`{:http_error, 404}`) rather
than passed through: `ExAws` error terms carry response bodies and request
details, and these values end up in logs.

### Visible in `mix phoenix_kit.doctor`

The "Integration Key" check from part 2 now also reports where the key is kept:

    PASS Integration Key
         dedicated key, fingerprint c13d1d7147da — compare it against your other
         sites; the same fingerprint means the same key.
         Stored in: /root/.config/phoenix_kit/p3.key, then s3://ops-backup/phoenix_kit/integrations-encryption.key

With nothing configured it says so plainly — "no key store configured — nothing
here holds a copy of this key" — rather than leaving the field blank.

## Found while writing the tests

`Chain`'s moduledoc promised a warning whenever a store other than the first
answered. The code only warned when an earlier store had **errored**, so the
most important case — the primary simply being *empty*, i.e. the local file
lost — passed in silence. The doc was right and the code was wrong; the code was
changed. The test for it is the second one in the Chain block.

## Verification

47 tests in `key_store_test.exs`, 0 failures, including: first-store-wins with
nothing logged; a spare answering an empty primary is reported; a spare
answering after a failure is reported; nothing anywhere is `:not_configured`
(which invites a first write) while a failure with nothing found is an error
(which must not); a write reaching every store; one member failing failing the
whole write and naming which; pre-flight aggregation; and for S3 — every
callback refusing a missing bucket before any network call, and no failure path
containing the secret.

Live: `mix phoenix_kit.doctor` against a configured two-member chain, output
above.

## Not done

* **No real bucket was written to.** There are no S3 credentials in this
  container and no bucket to use. The S3 store is covered for its configuration
  and error paths; its request path is exercised only through `ExAws`'s own
  interface, not against a live endpoint. Someone with a bucket should run one
  rotation against it before relying on it.
* **The "no dedicated key" warning was left alone.** It will keep appearing in
  the logs of all four sites until a key is actually configured. The owner's
  decision covered encryption and the private repository; it did not cover this,
  so nothing here widens it. What part 3 changes is the cost of removing the
  cause: setting a key no longer risks losing it.
* **Nothing was configured on any live site.** These are library capabilities;
  turning them on is a per-site decision.
