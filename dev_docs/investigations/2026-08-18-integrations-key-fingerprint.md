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
