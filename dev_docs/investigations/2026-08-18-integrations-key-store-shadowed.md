# P012 — "Key store: /path" beside a key that is not stored there

2026-08-18. Contract P012, branch `security-integrations-encryption-key`.
Method: the round 6 premise circle — see
`2026-08-18-integrations-key-premise-audit.md`. Premises first, run before
edited, mutation before believed.

## The claims, and what each one rests on

| # | The claim, and where | What it assumes about other code | Verdict (by running) |
|---|---|---|---|
| A | `{:dedicated, :ok}` — "a dedicated encryption key is in use" | `resolve/3` resolved a dedicated key | **TRUE** |
| B | `Key store: /path`, printed directly under A | that the store has anything to do with the key in A | **UNVERIFIED, and read as more than it says** — the line asserts only "a store is configured"; under a healthy verdict it reads as "your key is saved here" |
| C | the verdict's chain: rotation is not refused in that state | `status/0` is a rotatable tier | **TRUE** — a short config key gives `:legacy_secret_key_base` |
| D | `write_verified/1` destroys the previous stored secret | the store keeps no copy | **TRUE** — the file is replaced in place; nothing in the directory holds the old value afterwards |
| E | the chain always destroys | rotation reaches the write | **FALSE — it depends, and the dependency inverts the intuition** (below) |

Run for A/B, with a valid key in config and a different valid secret in the
file:

```
diagnosis : {:dedicated, :ok}
severity  : :ok            -> the admin page renders NO banner at all
doctor    : a dedicated encryption key is in use.
            Fingerprint c20beb99bcaa (dedicated key).
            Key store: /tmp/…/app.key
store read: {:ok, "STORE-secret-well-over-minimum-xx"}   <- never compared to anything
```

Both secrets are in hand during one resolution. Nothing compares them.

## E — when the destruction actually happens

`KeyRotation.rotate/2` decrypts every row under the CURRENTLY active key first
and halts on the first failure, rolling back before any row is written. So
whether the store survives depends on what this database holds. The predicate
that decides it was evaluated on its own inputs with public functions (the real
call needs a repo, which this container does not have):

```
a row encrypted under the STORE's secret, active key = config -> aborts: true
a row encrypted under the ACTIVE key                          -> aborts: false
no rows carrying a sensitive field at all                     -> aborts: false
```

So:

* **the stored secret protects rows in THIS database** → rotation aborts, nothing
  is written, the store is untouched;
* **it protects nothing here** → rotation proceeds and the task stores the new
  secret, replacing it.

The condition inverts what one would guess. The store is overwritten **exactly
when this database has nothing under the stored secret** — which is the shape of
a secret that belongs to something else: another install, another environment,
an off-host spare copy. `KeyStore.S3`'s own moduledoc describes the store as an
off-host copy behind `KeyStore.Chain`, and `Chain.write/2` writes to **every**
member, so a rotation replaces the local file and the bucket in one go. There is
no member left holding the previous value.

Sharpening the verdict rather than softening it: the destructive path is not the
one where the operator can see something is wrong. It is the quiet one.

And one step the verdict did not name: the task stores the new secret after a
rotation that touched **zero** rows. `rotate/2` returning `{:ok, %{rotated: 0}}`
still reaches `store_and_report/3`, so an install with no integration
credentials at all still overwrites whatever the store held.

## The qualification dispute, settled by the mechanism

The contract records a disagreement: a NEW SIGNAL (mine) versus AN EXISTING
FALSE IMPRESSION (the checker's). The runs say the checker is right, and for a
reason neither side had:

the storage line is printed by a clause that had **already read the value that
would falsify it**. `key_signals/0` holds the stored secret and the key in use in
the same map-building pass. This is not new information being added to the
verdict; it is information the verdict already had and threw away before
printing a line the operator reads as a claim about it.

That places it inside the class this contract is about — an assertion resting on
something never checked — rather than beside it. My deferral was wrong, and the
argument I used to defer it ("comparing is cheap, and cheap is how five rounds
happened") was answering a question nobody asked: the cost was never the issue.
