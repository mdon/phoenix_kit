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

## What changed

A fifth store state, `{:shadowed, location}` — the store holds a secret, and it
is **not** the key in use. It costs no new read: `key_signals/0` already holds
the stored secret and the resolved key in the same pass, so the comparison is
made where both are in hand and the verdict stays a pure function of one map.

That yields a diagnosis of its own, `{:dedicated, :store_shadowed}`, at
**`:warn`** rather than `:ok`. The severity is the load-bearing part: the admin
banner is guarded on `severity != :ok`, so at `:ok` this state says nothing on
the page at all — which is how it stayed invisible on every surface.

Rendered, for a valid key in config and a different valid secret in the file:

```
a dedicated encryption key is in use, but the configured key store holds a different secret.
the key in use comes from configuration, and /…/app.key holds something else — so the store
  is NOT a copy of the key in use, and restoring from it would produce a key that decrypts
  nothing written under the current one.
Do NOT run `mix phoenix_kit.integrations.rotate_key` before you know what the stored secret
  is for. It stops for two things — a key store it cannot WRITE to, and any row it cannot
  decrypt under the active key, whatever the cause — and neither is a check on the stored
  secret. Where neither happens the rotation replaces it in every configured store with no
  copy kept. Save it elsewhere first, or make the store hold the key in use.
Fingerprint c20beb99bcaa (dedicated key).
Key store: /…/app.key (configured, holds a DIFFERENT secret — not a copy of the key in use)
```

Every sentence there is something the run established. The rotation clause in
particular says *when* it is refused, because "rotation will refuse" as an
unconditional promise is the exact defect round 6 removed from the neighbouring
clause.

The admin page learned the state in the same commit — its title, its banner text
and its fingerprint label — because the round 5 failure was precisely a new
diagnosis reaching three surfaces out of four.

## Mutation

Remove the comparison, so the store is "holding" whatever it holds:

```
left:  {:dedicated, :ok}
right: {:dedicated, :store_shadowed}
a store holding a different secret never showed up: [...]
```

Two named tests, one on the rendered verdict and one on the states the real
resolution produces. Both are the P012 symptom, not a side effect.

## Scope held

The signal space grew by one value on an existing axis (4 store states → 5), and
the enumerations grew with it: 48 → 60 renderings in the doctor's walk, the same
in the admin page's. No reachability rule was added; the verdict remains total,
so the new value is checked in every combination including the ones that cannot
occur.

What was NOT done, deliberately: nothing compares the stored secret against
anything for the weaker tiers beyond marking it shadowed. Where the tier is
`:legacy` or `:none` and the store holds a secret, that secret was rejected as
too short, and the `:key_too_short` clause already names the store as a possible
source of it (round 6). Adding a second voice there would be the mistake this
contract exists to stop.

## Suite

```
before P012: 43 doctests, 3939 tests, 0 failures, 1554 excluded
after  P012: 43 doctests, 3940 tests, 0 failures, 1554 excluded
```

Excluded unchanged; the added test is the end-to-end one for this state.

---

## Round 2 — verdict FIX, and the blocker was mine

`store_state/2` gained a comparison, and a state moved under a clause that was
reading it for a different question.

Before P012, `{:holding, _}` meant "the store has a secret". Round 6 used that
to answer "where does the rejected secret live?", because a store with a secret
is a store that could have supplied one. P012 redefined `{:holding, _}` as "the
store has THE KEY IN USE" — and *a short secret in the store with no config key*
became `{:shadowed, _}`, fell through to the other branch, and started rendering:

    Replace the rejected secret — integrations_encryption_key. Config wins when
    it is set, and while it holds a rejected value the key store is not
    consulted at all…

False three times over: there is no config key; the secret is in the store file;
and the store was not merely consulted, it is the only reason `too_short?` was
true at all. An operator is sent to edit a variable that does not exist.

This is the contract's own class, committed by the fix for it: **a claim resting
on a neighbour's classification, and the neighbour moved.** Round 6 avoided
carrying the source explicitly, on the grounds that the store signal already
settled it. It did settle it — until something else needed that signal to mean
something else.

### The fix: carry the fact, do not re-derive it

`too_short?: boolean()` is now `rejected_key: false | :config | :store`. The
source is a property of the RESOLUTION — `dedicated_candidate/2` takes config
first and only length-checks the store's secret when config does not answer — so
it is carried out of the resolution instead of being reconstructed downstream
from a signal that answers a different question.

Verified by running, all three states:

```
no config key, short secret in store  -> rejected_key: :store
  "…it is the secret in /…/k.key; no integrations_encryption_key is set, so the
   store is what the key is read from"

short config key, good secret in store -> rejected_key: :config
  "…it is integrations_encryption_key. Config wins while it is set, so the key
   store is not consulted at all and repairing or filling it changes nothing"

short config key, no store             -> rejected_key: :config
  (same, and correct — there is no store to mention)
```

Point 2 of the verdict resolves itself: the "either … or the secret in
`<location>`" phrase is gone, along with its comment. It existed to hedge a
source that could not be determined; the source is determined now.

## Round 2's real subject: the enumeration was synthetic

The verdict's third point, and the expensive one. The cross product was green
across 60 combinations while a real configuration rendered a falsehood. It could
not have failed: the space was **hand-built**. It contained a `{:holding, _}`
store because someone wrote one down, and no short stored secret because nobody
thought to. It enumerated our idea of the states, so a defect in the idea was
invisible to it — which is the same shape as a fixture that reproduces the model
of a bug rather than the bug, scaled up to the whole sweep.

Now there are two spaces and one set of invariants, in
`test/support/key_verdict_invariants.ex`:

* **synthetic** — 90 combinations of signal values, reachable or not. It proves
  the verdict is *total*: it renders anything without contradicting itself.
  That is all it can prove.
* **real** — 72 configurations driven through the real `key_signals/0`: a config
  key absent / short / valid; a store missing, empty, holding a short secret,
  holding another valid one, or holding the config key itself; with and without
  `secret_key_base`; encryption on and off. Whatever comes out is what gets
  checked.

`real ⊆ synthetic` is asserted, so the two cannot drift; and the states the six
rounds were each about are named individually, so a fixture change cannot
quietly drop one.

### Mutations

    remove the short-secret store from the fixture matrix
      -> "assert {:legacy, :store, :shadowed} in shapes"  and the count assertion

    forget that the store can be the source of a rejected key
      -> "no config key, store holding a SHORT secret, secret_key_base set,
          encryption on: the rejected secret is in the store, and the advice
          does not say so"

The second names the real configuration rather than a synthesized map, which is
the point of the round.

### The invariant that failed its own mutation first

Worth recording, because it is the class inside the checker again. The first
version of the advice invariant asserted `detail =~ location` — and the mutation
walked straight through it, because the storage line prints that same path a few
lines below the advice. "The advice names the location" was being satisfied by a
sentence that is not the advice.

Re-keyed on `report.action`, the field that IS the advice, it fails immediately.
An assertion resting on a coincidence elsewhere in the same string is exactly
what this contract is about, one level further in.

### Suite

```
before round 2: 43 doctests, 3940 tests, 0 failures, 1554 excluded
after  round 2: 43 doctests, 3941 tests, 0 failures, 1554 excluded
```

Excluded unchanged. The hand-built walk was replaced rather than added to, so the
net is one test: the two new enumeration tests minus the one they replace.

---

## Second opinion — three more, and one of them is about the mutation

### 4. The page clauses were held by nothing

Established by destruction, not by argument: delete both new clauses and the
page tests stay green. The catch-all answers, its strings are non-empty, and it
contains no forbidden phrase — every assertion passes.

The mutation I ran on this work was real, but it mutated `store_state/2`. That
guards the classification; it does not guard *the page knowing the diagnosis*.
So the page edit I made and reported was, in fact, held by nothing. Worth naming
precisely: not "there was no mutation" but "the mutation was aimed at the wrong
place". Mutation is the tool against fictional tests, and it can miss for the
same reason a test can — by checking the neighbour of the thing that broke.

The invariant now asks the page about a diagnosis that cannot exist, and requires
every real diagnosis to answer differently:

```elixir
assert title != catch_all_title()
```

The catch-all's own words are never written down, so rewording it cannot silently
disable the check. Scoped to `severity != :ok`, because the banner is guarded on
exactly that and the healthy verdict deliberately has no clause.

Destruction re-run with the check in place — both clauses removed:

    no page title clause for {:dedicated, :store_shadowed} — catch-all answered
    (synthetic space, and again from a real configuration)

### 5. The diagnosis did not go out after the remedy

`KeyStore.cached_read/0` memoises success, and the store's *contents* were being
described from it. An operator told "make the store hold the key in use" could do
precisely that and watch the warning persist until a restart — while
`mix phoenix_kit.doctor`, whose VM is new, showed it cleared. That makes the page
look wrong rather than stale, and a diagnosis that survives its own remedy
teaches people to ignore diagnoses.

Split by question, which is what it should have been from the start:

* the KEY comes from the memoised read — it is the key the running app is
  actually encrypting with, and reading it fresh would let a page mount hand the
  app a different key;
* the store's CONTENTS are read fresh on every gather, because a claim about
  what a file holds must not be served from a value cached at boot.

The one-pass property is untouched: it says everything deciding *which key is in
use* comes from a single resolution, and it still does. The fresh read decides
nothing about the key; it describes the file.

The clause also stopped asserting where the key came from. "The key in use comes
from configuration" was true only while the store's contents and the key came
from the same read — the moment they did not, an operator who had just replaced
a store-sourced key would have been told the opposite of their situation. It now
says what is checked, and names the restart.

Verified by running the operator's own sequence, with no restart and no cache
invalidation:

```
before the fix: {:dedicated, :store_shadowed}
after  the fix: {:dedicated, :ok}
store signal  : {:holding, "/…/k.key"}
```

Mutation — serve the store's contents from the cache again:

    the warning goes out when the operator does what it says, without a restart
    left:  {:dedicated, :store_shadowed}
    right: {:dedicated, :ok}

### 6. "Only" promised more than the mechanism gives

The advice said rotation "is refused only while this database still holds rows
under that secret". Two refusals exist, and neither is a check on the stored
secret: a key store that cannot be **written**, and any row that fails to decrypt
under the active key — corruption or a third key will do it, not just that
secret. Both are now named, and "only" is gone.

### Suite

```
before: 43 doctests, 3941 tests, 0 failures, 1554 excluded
after:  43 doctests, 3942 tests, 0 failures, 1554 excluded
```

Excluded unchanged; the added test is the one that watches the warning go out.

---

## Round 2 verdict — the seventh instance, and it was created by the fix

`encryption_status_detail({_status, :key_too_short})` matched any status and told
an operator whose short secret sits in the key store that *"while a rejected key
is set, the key store is not consulted at all, so repairing or filling the store
changes nothing"*. False three times over — the secret is in the store file, the
store is precisely what was consulted, and repairing it is the only thing that
helps — and the sentence argues against the one repair that works.

The shape is worth stating exactly, because it is not carelessness: **the state
did not exist when the clause was written.** In round 6 a rejected key could only
be `:config`, so "rejected ⇒ it is in config" was a true premise. Round 2 of
P012 made `:store` producible, corrected the doctor, and left the page on the old
premise. The premise rested on `dedicated_candidate/2`, and that is what changed.

Expanding a state space is therefore not a local edit. Whoever adds a value owes
a walk of everyone who consumes it.

### Structural cause: the page asserted a fact it was never given

The page's clause heads took `report.diagnosis` — `{status, reason}` — and
`:key_too_short` carries no source. So the page had no way to know where the
rejected key was, and said anyway. That is this contract's class in its purest
form, and no amount of new clauses keyed on the diagnosis would fix it.

Two changes, one structural and one local:

* the report carries `rejected_key`, for the same reason it already carries
  `key_store`: a surface that renders facts in its own translated words must be
  **given** the facts it puts in them;
* the page's three clause heads take the whole report instead of the diagnosis,
  and `:key_too_short` gained `rejected_key: :store` clauses for the title, the
  detail and the fingerprint label.

Rendered, in the state the verdict named:

```
signals.rejected_key : :store
title  : The secret in the key store was rejected as too short
detail : The secret in the key store (/…/k.key) was rejected as shorter than the
         minimum, so a weaker key is in use. No integrations_encryption_key is
         set, so the store is where the key is read from: put a longer secret
         there and restart.
label  : FALLBACK key — the secret in the key store was rejected as too short
```

### Mutation, aimed at the clause this time

The lesson from the previous round was that a mutation can guard the neighbour of
the thing that broke. So the mutation is the deletion of the new `:store` detail
clause, letting the generic one answer again:

    page argues against repairing the store that holds the rejected secret
      — from the synthetic space, and
      — from "no config key, store holding a SHORT secret, secret_key_base set,
        encryption on"

The second line is the real configuration, which is the whole point of the
enumeration built last round: the invariant fires on the operator's actual state,
not only on a map someone wrote down.

### Suite

```
43 doctests, 3942 tests, 0 failures, 1554 excluded — unchanged
```

No test added: the invariant lives in the shared module and fires from both
enumerations, so the count stays put while the coverage does not.
