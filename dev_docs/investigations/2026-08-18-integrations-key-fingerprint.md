# Making integration key reuse between sites visible

2026-08-18. S004 part 2. Branch `security-integrations-encryption-key`.

## The problem

`PhoenixKit.Integrations.Encryption.derive_key/1` is
`sha256("phoenix_kit_integrations:" <> secret)` — a pure function of the secret.
With no dedicated key configured that secret is `secret_key_base`, so **two
installs sharing a `secret_key_base` hold a byte-identical integration key**.

That happens by accident more often than by design: a `config/dev.exs` copied
from a template, an environment cloned from a sibling, a value inherited when a
new site is stood up from an old one. Nothing anywhere told either site. One
compromise then exposes every site that shares it, and the operator has no way
to find out short of comparing secrets by hand — which means comparing the very
values you must not paste into a chat window.

## What was added

`Encryption.key_fingerprint/0` — a short, non-reversible, comparable identifier
of the key actually in use:

    sha256("phoenix_kit_integrations_fingerprint:v1:" <> key) |> hex |> first 12

Domain-separated from `derive_key/1` and truncated, so it is not the key and
cannot be turned back into one. **Two installs showing the same fingerprint are
using the same key** — that is the whole mechanism, and it is comparable across
sites without either side revealing anything.

Surfaced in two places, both of them where an operator already looks:

* `mix phoenix_kit.doctor` → a new "Integration Key" check reporting the tier
  and the fingerprint. On the legacy tier it is a WARN that spells out the
  consequence: *any other site sharing that secret_key_base has this same
  fingerprint and therefore the same key — one compromise exposes all of them.*
* `/admin/settings/integrations/website` → the fingerprint under the encryption
  banner, shown for **every** status rather than only the unhealthy ones: two
  sites can both be on a healthy dedicated key and still be sharing it (a copied
  key file, a cloned environment), and nothing else on that page would reveal it.

### What the fingerprint gives away, said honestly

It is not the key, but it *is* a verifier: someone holding it can test candidate
secrets offline. That matters precisely when the secret is weak — a
`secret_key_base` from a tutorial — which is the situation this exists to
expose. So it is shown on the admin-only system page and in operator tooling,
never on the personal integrations page a regular user can reach, and never in a
public response. The trade-off is stated in the function's own docs rather than
left for someone to discover.

## Review verdict FIX — what was wrong and what changed

### The one that mattered: the doctor check gave advice its own module forbids

The new check told anyone on the legacy tier to run
`mix phoenix_kit.integrations.rotate_key`. **Unconditionally.** Two functions in
the same module say that is wrong in specific states:

* `store_unreadable_warning/0` says *do NOT rotate — the stored key may be the
  one your data is encrypted under; repair the store first*;
* the too-short warning exists precisely because "no dedicated key is
  configured" is a falsehood told to someone who configured one.

The existing protection branched on those states. The new check did not, and did
not call `warn_if_insecure/0` either. Weight is not theoretical: **all four of
our sites run the legacy tier**, so this is the line every one of our operators
would have read. Rotation aborts if rows fail to decrypt, but that does not
cover the case where every row is already written under the fallback key — then
it runs, and overwrites the store.

This is the same defect closed twice already today, one layer out: a diagnostic
that is confident and wrong.

**Fix, and not a patch on the string.** `Encryption.key_diagnosis/0` now returns
the tier *and the reason for it*, and **both** `warn_if_insecure/0` and the
doctor check branch on that one value. They cannot give contradictory advice
because there is no longer a second place to derive it from. Reasons are ranked:
an unreadable store outranks "no dedicated key", because repairing the store may
restore the key the data is under, while rotating abandons it.

Verified by running the real task in each state:

    legacy, nothing configured   → "Run mix phoenix_kit.integrations.rotate_key ..."  (correct here)
    store configured, unreadable → "Do NOT run mix phoenix_kit.integrations.rotate_key —
                                    the stored key may be the one your data is encrypted
                                    under. Repair the store first: /path/to.key"
    dedicated key too short      → "a dedicated key IS configured but was REJECTED as
                                    shorter than 20 characters ... This is not the same as
                                    having none configured."

### The fingerprint reached CI logs

The task printed it on every run, including `:pass`. `mix phoenix_kit.doctor` is
meant as a deploy gate, so its output settles in build logs — a wider readership
than a page gated on `integrations_system`. The docstring promised "never on a
page a regular user can reach" and said nothing about that.

Now hidden unless `--fingerprint` is passed; otherwise the check prints
"(fingerprint hidden — pass --fingerprint to show)". The docstring says where it
can appear and why the flag exists.

### A bare number invites a false comparison

Three states make one site fingerprint a key that is not "its own": an
unreadable store, a dedicated key rejected as too short, and encryption
disabled. None were marked, so an operator comparing two sites could conclude
their keys differ when the comparison was never like-for-like.

The number now always carries its tier — `fingerprint abc… (dedicated key)`,
`(FALLBACK key — the configured key store could not be read)` — on both the
admin page and in the task.

The related environment trap is now written down rather than left to be
discovered: `mix phoenix_kit.doctor` resolves the key in the **task's**
environment, so a key delivered by an env var read in `runtime.exs` can make a
task and an admin page on the *same site* disagree. Compare page with page, or
task with task.

### No KDF: a guess cost two hashes

There is no salt and there cannot be one — a per-install salt gives two installs
holding the same key different numbers, destroying the only thing this is for.
What could be raised is the price per guess. The digest is now
PBKDF2-HMAC-SHA256 at 100 000 iterations instead of two plain SHA-256s, measured
at 109 ms, paid on an admin mount and in a mix task — neither a hot path.

The prefix stays global, so a table over common `secret_key_base` values still
works against every install at once; it now costs 100 000 times more to build,
and nothing more. The docstring states the limit plainly: **the fingerprint is
no stronger than the secret behind it.** Domain version bumped `v1` → `v2`, so
fingerprints from before this change do not match ones after it; nothing
persisted them.

### Acknowledged, not fixed

The checker's own closing point: this feature does not *answer* whether our
sites share a key — it only makes the answer obtainable. Getting it needs a run
on each site, which is the head's step, not a code change.

## Second FIX round — the same lie on a third and fourth surface

The branching was unified last round; the **wording** was not, and that is where
the defect reappeared.

### The doctor claimed a weaker key where none exists

Both the "store unreadable" and "key too short" branches said *a weaker key is in
use*. Those states are reachable **paired with** "no key at all", and then there
is no weaker key — credentials go to disk in plain text. This module had already
grown a function specifically against that sentence, with a live regression test
saying both messages must say PLAINTEXT and neither may claim a fallback. The
doctor was a third surface breaking that invariant. Both branches also reported
at warning level, so unintended plaintext did not surface as a fact at all.

Then a fourth was found while fixing it: `dedicated_key_too_short_warning`
carried "Falling back to whatever weaker tier would otherwise apply" — same
blindness, same module.

**Fixed at the source.** `Encryption.key_advice/0` now returns the facts —
severity, summary, consequence, action, and whether rotation is safe — and the
four prose builders are gone. The boot log and the mix task render that one
value; they no longer have wording of their own to drift. Unintended plaintext
is `:fail`, not `:warn`, so `--exit-code` stops a deploy for it; encryption
switched off deliberately stays a warning, because the operator already knows.

Verified on the exact pair that used to lie:

    store unreadable, legacy present  → WARN, "encryption fell back to the
                                        secret_key_base-derived key …"
    store unreadable, no key at all   → FAIL, "NO key resolved at all —
                                        integration credentials are being
                                        written in PLAINTEXT"

### The task had silently dropped the part that matters most

Rewriting its own text, the check lost the clause saying that repairing the store
**later** does not recover anything written in the meantime. The reader of a mix
task's output is exactly the operator who needs to know that every write right
now is becoming unrecoverable. It is back, because the task no longer writes its
own sentences.

### And the admin page was a fourth voice

Keyed on the status alone, it told an operator whose store is merely unreadable
that "no dedicated encryption key is configured" — false, they configured one —
and then advised the rotation that would abandon the key their data may be under.
It now branches on the diagnosis, with separate clauses for "a weaker key is in
use" and "there is no key at all", and its strings stay `gettext`-wrapped
because they are translated UI. So: **one source for the facts everywhere, one
source for the words in the log and the task, and the page renders the same
facts in its own translated voice** — not a claim of one string for all three,
which `gettext` cannot honour.

### The tests were guarding the wrong layer

The previous round's tests covered `key_diagnosis/0` and would have stayed green
had the doctor branch kept advising rotation — the defect lived in the
rendering, where nothing reached it. `Mix.Tasks.PhoenixKit.Doctor.integration_key_result/3`
is now a pure, public seam, for the same reason `exit_code/1` is one.

**Proven by mutation, not by assertion.** With the pre-fix rendering pasted back
in — its own wording, "a weaker key is in use", the unconditional rotation
advice — exactly the three guarding tests go red:

    1) where rotation is unsafe, the only mention of it is the prohibition
    2) it never claims a weaker key when the advice says plaintext
    3) the advice is rendered verbatim — the check adds no wording of its own
    25 tests, 3 failures

Restored: 25 tests, 0 failures. That is the check that the guard sits where the
break happened.

### Tests that pinned phrases, not invariants

Four of my own assertions broke when the wording moved to one source — they were
matching sentences. Rewritten to assert what must be true (both messages agree;
an operator who configured a short key is not told none is configured) rather
than how it is phrased, which is what should survive the wording living in one
place.

## Round 4 — the assembly itself, not another branch

Three rounds of per-branch fixes produced three instances of one defect. The
verdict on that was not "be more careful": the message was assembled by
concatenating independent pieces, each aware only of its own condition, so the
next edit was always going to add a fourth. This round changes the assembly.

### The shape

Adopted from `git_hooks_verdict/1`, written for I035 and shipped in PR #736 —
one place gathers raw signals, one ordered set of clauses answers everything at
once. Worth stating plainly, since it reached me as "an example already in this
file, written by someone else": it lives on the `feature/tracked-git-hooks`
branch, not in this file on this branch, and I wrote it. The form stands on its
merits and on having passed an independent review, not on being somebody
else's.

    Encryption.key_signals/0  ->  %{enabled?, tier, too_short?, store, fingerprint}
    Encryption.key_report/1   ->  one clause per reachable state, whole report out

The verdict consults **nothing** outside the map it is given. That is the
property that matters: the third instance happened because a later step went
back to the environment for one more fact and got a different answer than the
step before it — a report built for the legacy tier asked the environment, was
told there was no secret, and announced "NO key resolved at all" directly above
a fingerprint of the key that had in fact resolved.

Two things can no longer be paired wrongly because they are no longer separate:

* the fingerprint and the tier that produced it are one term, `{:ok, value,
  label}`, absent together;
* `:key_store` is `nil` unless a store is configured, so no location can be
  printed for a key stored nowhere.

### The store distinction the reviewer asked for

`:absent`, `{:empty, loc}`, `{:unreadable, loc}` and `{:holding, loc}` are four
signals, not one absence, because the advice differs: set one up / put a secret
in the one you have / repair it and write nothing meanwhile / it is working.

### The enumeration

25 combinations of the signal space; **16 reachable, 9 not**. The unreachable
ones have no clause deliberately, and the reasons are mechanical:

```
- store=:absent tier=:dedicated too_short?=true — a key rejected as too short cannot have produced the dedicated tier
- store={:empty, "/srv/keys/app.key"} tier=:dedicated too_short?=true — a key rejected as too short cannot have produced the dedicated tier
- store={:unreadable, "/srv/keys/app.key"} tier=:dedicated too_short?=false — an unreadable store cannot have supplied the key
- store={:unreadable, "/srv/keys/app.key"} tier=:dedicated too_short?=true — a key rejected as too short cannot have produced the dedicated tier
- store={:holding, "/srv/keys/app.key"} tier=:dedicated too_short?=true — a key rejected as too short cannot have produced the dedicated tier
- store={:holding, "/srv/keys/app.key"} tier=:legacy too_short?=false — a store holding a secret supplies the dedicated tier
- store={:holding, "/srv/keys/app.key"} tier=:legacy too_short?=true — a store holding a secret supplies the dedicated tier
- store={:holding, "/srv/keys/app.key"} tier=:none too_short?=false — a store holding a secret supplies the dedicated tier
- store={:holding, "/srv/keys/app.key"} tier=:none too_short?=true — a store holding a secret supplies the dedicated tier
```

Every reachable state, rendered whole, at `--fingerprint=true` (the `false`
variant differs by exactly one line — the fingerprint — and by nothing at all
where there is no key):

### store=:absent tier=:none short?=false enabled?=false | warn | {:disabled_explicit, :turned_off}

```
encryption is switched off (integration_encryption_enabled: false).
integration credentials are being written in PLAINTEXT, readable by anyone with read access to the database.
If that is unintentional, set integration_encryption_enabled: true
```

### store=:absent tier=:dedicated short?=false enabled?=true | pass | {:dedicated, :ok}

```
a dedicated encryption key is in use.
Fingerprint abc123def456 (dedicated key)
```

### store=:absent tier=:legacy short?=false enabled?=true | warn | {:legacy_secret_key_base, :no_dedicated_key}

```
integration credentials are encrypted with a key DERIVED from secret_key_base.
secret_key_base is shared with session signing and CSRF tokens, so anyone who can read it (environment, a config file, git history) can decrypt every stored credential — and any other site sharing that secret_key_base holds the same key.
Run `mix phoenix_kit.integrations.rotate_key` for a key of this site's own, then restart.
Fingerprint abc123def456 (derived from secret_key_base)
```

### store=:absent tier=:legacy short?=true enabled?=true | warn | {:legacy_secret_key_base, :key_too_short}

```
a dedicated key IS configured but was rejected as shorter than 20 characters, which is not the same as none being configured.
encryption fell back to the secret_key_base-derived key, so values written under the stored key will not decrypt, and anything written now is encrypted under the fallback instead.
Replace it with a real secret — `mix phoenix_kit.integrations.rotate_key` generates one, and stores it for you if a key store is configured.
Fingerprint abc123def456 (FALLBACK key — the configured key was rejected as too short)
```

### store=:absent tier=:none short?=false enabled?=true | fail | {:disabled_no_key, :no_key_material}

```
no encryption key resolves at all.
integration credentials (API keys, OAuth tokens, bot tokens) are being written in PLAINTEXT, readable by anyone with read access to the database.
Configure integrations_encryption_key, or a key store, and restart
```

### store=:absent tier=:none short?=true enabled?=true | fail | {:disabled_no_key, :key_too_short}

```
a dedicated key IS configured but was rejected as shorter than 20 characters, which is not the same as none being configured.
NO key resolved at all — integration credentials are being written in PLAINTEXT.
Replace it with a real secret — `mix phoenix_kit.integrations.rotate_key` generates one, and stores it for you if a key store is configured
```

### store={:empty, "/srv/keys/app.key"} tier=:dedicated short?=false enabled?=true | pass | {:dedicated, :ok}

```
a dedicated encryption key is in use.
Fingerprint abc123def456 (dedicated key).
Key store: /srv/keys/app.key
```

### store={:empty, "/srv/keys/app.key"} tier=:legacy short?=false enabled?=true | warn | {:legacy_secret_key_base, :no_dedicated_key}

```
integration credentials are encrypted with a key DERIVED from secret_key_base.
secret_key_base is shared with session signing and CSRF tokens, so anyone who can read it (environment, a config file, git history) can decrypt every stored credential — and any other site sharing that secret_key_base holds the same key.
Run `mix phoenix_kit.integrations.rotate_key` for a key of this site's own, then restart.
Fingerprint abc123def456 (derived from secret_key_base).
Key store: /srv/keys/app.key
```

### store={:empty, "/srv/keys/app.key"} tier=:legacy short?=true enabled?=true | warn | {:legacy_secret_key_base, :key_too_short}

```
a dedicated key IS configured but was rejected as shorter than 20 characters, which is not the same as none being configured.
encryption fell back to the secret_key_base-derived key, so values written under the stored key will not decrypt, and anything written now is encrypted under the fallback instead.
Replace it with a real secret — `mix phoenix_kit.integrations.rotate_key` generates one, and stores it for you if a key store is configured.
Fingerprint abc123def456 (FALLBACK key — the configured key was rejected as too short).
Key store: /srv/keys/app.key
```

### store={:empty, "/srv/keys/app.key"} tier=:none short?=false enabled?=true | fail | {:disabled_no_key, :no_key_material}

```
no encryption key resolves at all.
integration credentials (API keys, OAuth tokens, bot tokens) are being written in PLAINTEXT, readable by anyone with read access to the database.
A key store is configured at /srv/keys/app.key but holds no secret yet. Set integrations_encryption_key and restart; rotation cannot help while no key is active.
Key store: /srv/keys/app.key
```

### store={:empty, "/srv/keys/app.key"} tier=:none short?=true enabled?=true | fail | {:disabled_no_key, :key_too_short}

```
a dedicated key IS configured but was rejected as shorter than 20 characters, which is not the same as none being configured.
NO key resolved at all — integration credentials are being written in PLAINTEXT.
Replace it with a real secret — `mix phoenix_kit.integrations.rotate_key` generates one, and stores it for you if a key store is configured.
Key store: /srv/keys/app.key
```

### store={:unreadable, "/srv/keys/app.key"} tier=:legacy short?=false enabled?=true | warn | {:legacy_secret_key_base, :store_unreadable}

```
a key store is configured (/srv/keys/app.key) but its secret could not be read.
encryption fell back to the secret_key_base-derived key, so values written under the stored key will not decrypt, and anything written now is encrypted under the fallback instead.
Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this — the stored key may still be the one your data is encrypted under. Repair the store first; repairing it later will NOT make anything written in the meantime readable.
Fingerprint abc123def456 (FALLBACK key — the configured key store could not be read).
Key store: /srv/keys/app.key
```

### store={:unreadable, "/srv/keys/app.key"} tier=:legacy short?=true enabled?=true | warn | {:legacy_secret_key_base, :store_unreadable}

```
a key store is configured (/srv/keys/app.key) but its secret could not be read.
encryption fell back to the secret_key_base-derived key, so values written under the stored key will not decrypt, and anything written now is encrypted under the fallback instead.
Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this — the stored key may still be the one your data is encrypted under. Repair the store first; repairing it later will NOT make anything written in the meantime readable.
Fingerprint abc123def456 (FALLBACK key — the configured key store could not be read).
Key store: /srv/keys/app.key
```

### store={:unreadable, "/srv/keys/app.key"} tier=:none short?=false enabled?=true | fail | {:disabled_no_key, :store_unreadable}

```
a key store is configured (/srv/keys/app.key) but its secret could not be read.
NO key resolved at all — integration credentials are being written in PLAINTEXT.
Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this — the stored key may still be the one your data is encrypted under. Repair the store first; repairing it later will NOT make anything written in the meantime readable.
Key store: /srv/keys/app.key
```

### store={:unreadable, "/srv/keys/app.key"} tier=:none short?=true enabled?=true | fail | {:disabled_no_key, :store_unreadable}

```
a key store is configured (/srv/keys/app.key) but its secret could not be read.
NO key resolved at all — integration credentials are being written in PLAINTEXT.
Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this — the stored key may still be the one your data is encrypted under. Repair the store first; repairing it later will NOT make anything written in the meantime readable.
Key store: /srv/keys/app.key
```

### store={:holding, "/srv/keys/app.key"} tier=:dedicated short?=false enabled?=true | pass | {:dedicated, :ok}

```
a dedicated encryption key is in use.
Fingerprint abc123def456 (dedicated key).
Key store: /srv/keys/app.key
=== ТЕСТЫ ===
Finished in 1.3 seconds (0.5s async, 0.7s sync)
70 tests, 0 failures
1) test encryption_key/0 fallback to host endpoint secret_key_base falls back to the host endpoint's secret_key_base when the flat key is unset (PhoenixKit.Integrations.EncryptionTest)
55 tests, 1 failure
```

### Checked mechanically, then by mutation

All 32 renderings (16 states x 2 flag positions) were scanned for
self-contradiction — a fingerprint beside "no key", a fallback claimed off the
legacy tier, a storage line with no store, a rotation suggested where the report
calls it unsafe. **0 contradictions.**

The test walks the same space rather than listing branches, asserts the count
(16) so a new signal value cannot silently shrink coverage, and derives
reachability from stated rules.

Both mutations are caught:

    consequence read from the environment again
      -> "{:unreadable, ...} tier: :legacy ... the PLAINTEXT claim does not match the tier"

    a fingerprint fabricated while building the report
      -> "enabled?: false ... report invented a fingerprint"

The second is worth recording: it passed the first time. The invariant was keyed
on the *report*, which only checks that the rendering agrees with itself — and a
report that invents a fingerprint agrees with itself perfectly. Keyed on the
**signals**, which are the ground truth, it fails immediately. A guard written
against the thing under test is not a guard.

### A wrong recommendation the enumeration found

With a configured-but-empty store and no key at all, the report marked rotation
unsafe and its own action advised running it. Beyond the contradiction the
advice was useless: `KeyRotation.rotate/2` refuses outright while no key is
active, so it would have sent an operator to a command that cannot help. It now
says to set a key and restart, and says the store is configured but empty —
which is the part they could not have known.

## Round 5 — the ordering carried its own version of the same error

The rebuild removed the concatenation, and ordered clauses brought the fault
back in a new place: **clause priority**. The store-unreadable clause sat above
the dedicated-key clause, and that state is reachable — a valid key set in
CONFIG while a key store is configured and broken. Config is read first and the
store is never consulted when it answers, so the key works; the store being
unreadable says nothing about it.

Reproduced against the real resolution before touching anything:

    диагноз: {:legacy_secret_key_base, :store_unreadable}

So the message said encryption had fallen back to secret_key_base, labelled the
real dedicated key's fingerprint as a FALLBACK, warned instead of passing, and
the admin banner — keyed on the same diagnosis — announced a weaker key while
encryption was working perfectly.

After the reorder and a clause of its own:

    диагноз: {:dedicated, :store_unreadable}

    a dedicated encryption key is in use, but the configured key store could not be read.
    encryption itself is fine — the key in use comes from configuration. What is broken
    is the spare copy: nothing is backing that key up, and the next rotation will refuse
    at its pre-flight.
    Repair the store at /srv/keys/app.key; until it reads back, assume the key is saved nowhere.

> **Superseded — the last sentence of that consequence was false, and this
> report repeated it as fact.** "The next rotation will refuse at its pre-flight"
> was checked in round 6 by running it, and fails twice over:
> `KeyStore.preflight/0` writes a probe file next to the secret and never reads
> it, so an unreadable secret in a writable directory answers `:ok`; and
> `KeyRotation.rotate/2` does not call a pre-flight at all — with `preflight/0`
> returning an error it walked straight past into the row scan. The clause was
> rewritten in round 6; see `2026-08-18-integrations-key-premise-audit.md`.
> Read the rest of this section knowing that a round which fixed a false
> promise shipped another one in the fix, and the report carried it forward
> because nobody ran the thing being promised.

### The enumeration had inherited the blindness

This is the part worth keeping. The test excluded that state by a rule I wrote:
*an unreadable store cannot have supplied the key in use*. True, and irrelevant
— the key came from config. The enumeration was supposed to be the guard
against exactly this kind of miss, and it could not be, because its list of
states was reasoned out by the same person who reasoned out the code.

The reachability rules are now derived from what the functions actually read:

* `configured_dedicated_key/0` takes the explicit config key first and never
  consults the store when it finds one — so a broken store does not prevent the
  dedicated tier;
* a key rejected as too short is by definition not the one in use;
* a readable store holding a usable secret IS a dedicated key source, so it
  cannot coexist with a weaker tier unless that secret was itself rejected.

25 combinations, **19 reachable, 6 not** (was 16/9 — the three states the old
rules wrongly excluded are all `{:unreadable}` paired with a working tier):

```
- store=:absent tier=:dedicated too_short?=true — a key rejected as too short is not the one in use, so it cannot be the dedicated tier
- store={:no_secret_yet, "/srv/keys/app.key"} tier=:dedicated too_short?=true — a key rejected as too short is not the one in use, so it cannot be the dedicated tier
- store={:unreadable, "/srv/keys/app.key"} tier=:dedicated too_short?=true — a key rejected as too short is not the one in use, so it cannot be the dedicated tier
- store={:holding, "/srv/keys/app.key"} tier=:dedicated too_short?=true — a key rejected as too short is not the one in use, so it cannot be the dedicated tier
- store={:holding, "/srv/keys/app.key"} tier=:legacy too_short?=false — a readable store holding a usable secret IS a dedicated key source
- store={:holding, "/srv/keys/app.key"} tier=:none too_short?=false — a readable store holding a usable secret IS a dedicated key source
```

All 38 renderings scanned for self-contradiction: **0**. Reverting the clause
order turns the new test red with the exact wrong diagnosis:

    left:  {:legacy_secret_key_base, :store_unreadable}
    right: {:dedicated, :store_unreadable}

### A signal that was named for something it never is

`{:empty, loc}` suggested "the key file is empty". It never means that: an empty
file reads as an ERROR and lands in `:unreadable`. The signal is produced when
the store has no secret **yet** — no file at all — so it is now
`{:no_secret_yet, loc}`. Verified by reproduction rather than by reading:

    файла нет:        :not_configured
    файл пустой:      {:error, {:empty, "…/k.key"}}
    файл с секретом:  {:ok, "kkkk…"}

## Found while writing the tests

The test asserting that a dedicated key and a legacy secret *of the same text*
differ **failed**, and the code was right:

    test "moving the SAME secret to the dedicated setting does not change the key"

The key is derived identically whichever tier the secret came from. So copying
`secret_key_base` into `integrations_encryption_key` does **not** change the key
— it only changes which config line it is read from. An operator doing that
believes they have migrated off the shared key; they have not, and every sibling
site still holds their key. The fingerprint is what reveals the fake migration,
which makes it more useful than the original design assumed.

## Verification

Five tests in `encryption_test.exs`: same secret → same fingerprint (the claim
part 2 rests on); different secret → different; the same secret moved between
tiers → unchanged, with the reason recorded; shape is 12 lowercase hex and
contains neither the key nor is contained by it; no key at all → `:none`, so
nothing is displayed to compare.

Live, against the real task:

    WARN Integration Key
         key is DERIVED from secret_key_base, fingerprint 292e853388e9.
         Any other site sharing that secret_key_base has this same fingerprint and
         therefore the same key — one compromise exposes all of them. Run
         `mix phoenix_kit.integrations.rotate_key` to give this site a key of its own.

and two different secrets producing two different fingerprints
(`292e853388e9` vs `9506301f7534`).

## Not done

* **No gettext extraction.** Two new user-facing strings on the admin page are
  wrapped in `gettext/1` but the manifest was not re-extracted; they render in
  English for other locales until it is. Extraction is a maintainer-run step
  here, and running it writes `#, fuzzy` entries across unrelated messages.
* **The pre-existing `encryption_test.exs:163` failure** (host endpoint
  fallback) is still failing, still unrelated: it fails on the committed tree
  without these changes and in isolation, and its cause is the container's
  incomplete `test_helper.exs`, which is what starts the endpoint it reads.
* **No cross-site comparison was performed for real** — that needs two live
  sites, and Hydroforce's server is not up. The mechanism is proven by
  construction and by test; the act of comparing two real fingerprints is an
  operator step.

## Companion document

`2026-08-18-secret-key-base-change-fork.md` — for the owner: what happens to
encrypted credentials if `secret_key_base` changes, the four options with their
prices, and the trap that rotating *afterwards* recovers nothing.

## Round 6 — the premises, checked by running

The full working log is `2026-08-18-integrations-key-premise-audit.md`. In
summary: five rounds produced five instances of one defect, so round 6 did not
start from the states at all. Every claim the diagnostics make was written down
as *a premise about another function's behaviour*, and each was checked by
running it. Twelve premises; six false.

What the false ones cost, and what changed:

* **The gather was not one pass.** `key_signals/0` resolved the environment up
  to four times, and `KeyStore.cached_read/0` deliberately does not memoise
  failures — so a store that failed one read and answered the next produced a
  map contradicting itself: `tier: :legacy` beside `store: {:holding, _}` and
  the fingerprint of the STORED key, printed under the label "derived from
  secret_key_base". Round 4 moved the contradiction out of the verdict and into
  the gather, where nothing was watching. One read of each input now, and the
  five signals are derived from those.
* **`{:dedicated, :store_unreadable}` promised a pre-flight refusal** that
  neither the pre-flight nor `rotate/2` performs (above).
* **The clause set is ordered by TIER first, then fault.** Three rounds ordered
  by fault and each found a fault clause firing over a working tier. The tier is
  which key is protecting the data; a fault is a modifier on it. The verdict is
  now total over the signal space, so no reachability argument is needed
  anywhere.
* **`store_state/0` collapsed "no secret yet" into "holding"** — the collapse
  `KeyStore.read/0`'s own doc forbids, in the opposite direction from the one it
  warns about. `{:no_secret_yet, _}` was a signal production could never emit
  while the tests enumerated it as one of four.
* **The enumeration's reachability rule** excluded `{:holding} ∧ ¬dedicated`,
  which both of the above produced. Third false reachability rule in three
  rounds; the rules are gone rather than corrected.
* **The admin page never received round 5's fix**: with a working dedicated key
  and a broken store it showed no banner at all (guarded on `status !=
  :dedicated`) and labelled that key "FALLBACK". It now renders from one report,
  and its clause heads are public seams a test can walk.
* **The boot log claimed a fallback on the dedicated tier** — the one caller
  documented as unable to know the tier. That exemption ended when the
  resolution became a pure function of three reads.
* **The advice for "a short key and no key at all"** recommended a rotation that
  refuses (`{:error, {:encryption_disabled, :disabled_no_key}}`, verified), and
  marked it safe.

Every fix was mutation-checked: reverting each one turns a named test red, and
the rotation invariant was rewritten after the first mutation walked through it
— it had been keyed on `rotation_safe?`, a claim by the code under test, so
flipping that flag disabled the assertion meant to catch the flip.
