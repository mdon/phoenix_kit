# If `secret_key_base` changes, what happens to encrypted integration credentials

2026-08-18. Written for the owner's decision, and **decided**: encryption of
bucket credentials proceeds, the repository gets cleaned later, it is private.
Sites are not held up for this. Kept because the mechanics below stay true and
the options still have to be picked from eventually.

Prompted by a live question from decor pre-prod: 2.13.0 encrypts
`secret_access_key` with a key derived from `secret_key_base`, and the question
was what that means for real buckets.

## Correction to an earlier framing of this document

An earlier version of this page described losing the key as though every
consequence were equally grave. It is not, and the distinction changes which
option is worth paying for.

**Most of what is stored here is re-issuable.** A bucket `secret_access_key` can
be regenerated in the provider's console: the worst case of losing the
encryption key is **downtime plus issuing a new pair**, not irreversible loss.
The same is broadly true of API keys and bot tokens.

What is *not* freely re-issuable is anything that required a human to consent —
an OAuth refresh token means asking every affected user to reconnect, which is
cheap in a pre-prod site and expensive in a live one with real users.

So the honest severity is: **operational, not existential**, for the storage
case that prompted this. A backup of the key is still worth taking; stopping
work over it is not.

## The mechanism, stated plainly

`PhoenixKit.Integrations.Encryption.derive_key/1` is
`sha256("phoenix_kit_integrations:" <> secret)`. With no dedicated key
configured, that secret is `secret_key_base`. So:

* **the encryption key is a pure function of `secret_key_base`** — change one,
  the other changes;
* **two sites sharing a `secret_key_base` hold the same integration key**, byte
  for byte, and until now nothing told them. `key_fingerprint/0` now makes that
  visible: same fingerprint, same key.

## What happens the moment `secret_key_base` changes

Every stored credential was encrypted under the old derived key and cannot be
decrypted under the new one. The behaviour is **fail-closed, not silent**:

* each undecryptable field is logged at `:error` and **dropped**, so callers see
  the credential as absent rather than receiving `enc:v1:...` as if it were a
  bearer token;
* an object-storage integration therefore stops working with "not configured"
  rather than authenticating wrongly against a real bucket;
* nothing is corrupted or overwritten — the ciphertext stays in the database and
  becomes readable again if the old `secret_key_base` is restored.

**The data is not destroyed by the change.** The ciphertext becomes unreadable
if the old `secret_key_base` is lost afterwards — but for a re-issuable secret
that means re-issuing it, not losing something unrecoverable. Weigh it as
downtime, and reserve "unrecoverable" for credentials that needed a human to
grant them.

## The trap worth naming first

**Rotating AFTER the change does not work.**
`mix phoenix_kit.integrations.rotate_key` decrypts every row under the key that
is active *now*. Once `secret_key_base` has changed, the active key is already
the new one and the old rows cannot be read, so rotation refuses (correctly) and
nothing is recovered. Rotation is a **before** action, not a repair.

## The options

### A. Rotate to a dedicated key first, then change `secret_key_base` freely

Configure a key store, run `mix phoenix_kit.integrations.rotate_key`, restart.
The credentials are then encrypted under a key of this site's own, independent
of `secret_key_base`, which can afterwards be changed whenever you like.

* **Price:** one rotation and one restart, a few minutes. Requires the key store
  to be configured first, or the printed secret to be captured.
* **Also buys:** the site stops sharing its key with any sibling that has the
  same `secret_key_base`, and `secret_key_base` stops being a credential-grade
  secret for this purpose.
* **Risk:** the window between rotating and restarting — reads fail until the
  app picks up the new key.

### B. Change `secret_key_base` and re-enter the credentials by hand

* **Price:** proportional to how many real credentials exist. On decor pre-prod
  **right now that price is close to zero** — it is on the legacy tier and has
  no real secrets stored yet. The same choice made after production buckets,
  Shopify keys and OAuth tokens are entered costs a day of coordinated work and
  a window where integrations are down.
* **Risk:** none to the data; the old ciphertext simply becomes dead rows.

### C. Keep `secret_key_base` as it is, indefinitely

* **Price:** `secret_key_base` also signs sessions and CSRF tokens. It appears
  in environments, config files and — as we found on Hydroforce — in git
  history. Anyone who can read it can decrypt **every** stored integration
  credential, and any sibling site sharing it holds the same key.
* **Risk:** you cannot rotate `secret_key_base` for a session-security reason
  without paying option A or B at that moment, under time pressure.

### D. Do nothing yet, deliberately, and revisit before real secrets land

* **Price:** zero today, and the cost of A or B rises the longer it waits.
* Worth pairing with a marker: once a real bucket credential is entered, the
  cheap moment has passed.

## What this looks like for decor pre-prod specifically

It is on 2.13.0, on the legacy tier, with no real secrets stored. That is the
cheapest possible moment to pick A or B — both cost almost nothing now, and both
cost real work later. The question "what happens to real buckets" therefore has
a better answer than a description of the failure: **decide before the real
bucket credentials are entered**, and the failure never happens.

## How to see where any site stands, without asking anyone

    mix phoenix_kit.doctor        # "Integration Key" — tier plus fingerprint

and the same fingerprint appears on `/admin/settings/integrations/website`.
Two sites showing the same fingerprint are using the same key. A site on the
legacy tier is told so, with the reuse consequence spelled out.

One caveat found while building it: copying `secret_key_base` into
`integrations_encryption_key` does **not** change the key — same secret, same
derivation, same fingerprint. It looks like a migration and is not one. The
fingerprint is what reveals it.
