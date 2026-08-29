# A place for the integrations encryption key to land

2026-08-18. S004 part 1. Branch `security-integrations-encryption-key`.

Written to be read cold.

## The hole

`mix phoenix_kit.integrations.rotate_key` generated a new secret, printed it
once, and said so plainly: *"copy it now, this task does not save it anywhere"*.
It wrote no config and no file. An operator who lost that one line lost every
stored integration credential with it — the ciphertext stays in the database
and nothing can read it again.

This is not a thought experiment. On 2026-08-18 an account key was lost exactly
this way, and the shape of the loss matters: **the file looked intact and the
value inside was empty.** Nothing reported a problem until the credentials were
needed.

## What was built

### 1. `PhoenixKit.Integrations.KeyStore` — a behaviour

Four callbacks: `read/1`, `write/2`, `preflight/1`, `describe/1`. A host that
owns Vault or AWS Secrets Manager implements it and configures its own module.

    config :phoenix_kit, integrations_key_store: PhoenixKit.Integrations.KeyStore.File
    # or {PhoenixKit.Integrations.KeyStore.File, path: "/etc/phoenix_kit/app.key"}

### 2. `PhoenixKit.Integrations.KeyStore.File` — the default, deliberately boring

One file, mode `0600`, in a directory created `0700`, outside the repository.
Chosen because it works for *every* PhoenixKit user: no account, no network, no
credentials of its own. A cloud secrets manager is a better vault and a worse
default — most people running PhoenixKit on one box have no reason to own one.
The owner's framing was explicit: the solution must suit all users, not
configure our four sites.

Path resolution: `:path` option → `PHOENIX_KIT_INTEGRATIONS_KEY_FILE` →
`~/.config/phoenix_kit/<app>-integrations.key`. The default carries the host
application's name so two sites on one machine get separate keys rather than
silently sharing one.

Three properties worth naming:

* **Atomic write.** Written to `<path>.tmp`, `chmod`ed, then renamed. A rename
  within a filesystem is atomic, so a reader never sees half a secret and a
  crash mid-write cannot truncate the existing one — the failure mode from the
  incident above.
* **Refuses to write inside a git working tree.** Walks up from the target
  directory looking for `.git` (a directory in a clone, a *file* in a linked
  worktree — both are checked). "The operator will remember to gitignore it" is
  not a guarantee; a secret committed once is compromised even after deletion,
  because history keeps it.
* **An empty file is an error, not "nothing stored yet".** `:not_configured` is
  reserved for a file that does not exist. A file that exists and holds nothing
  is `{:error, {:empty, path}}` — precisely the state that was mistaken for
  healthy on 2026-08-18.

### 3. Rotation now stores the secret, and proves it

Order of operations, and the reason for it:

1. **Pre-flight the store before touching any data.** Rotation is the dangerous
   moment: once rows are re-encrypted, a store that then refuses the write
   leaves an operator holding a database no key opens. Checking first turns
   that disaster into an abort that changed nothing.
2. Re-encrypt (unchanged, still all-or-nothing in one transaction).
3. Write the secret, **then read it back and compare** before reporting
   success. A write that returns `:ok` and did not land is the exact failure
   being defended against, so it is not trusted on its own word.

Three outcomes, three different messages:

* **stored** — says where the file is and that it was read back to confirm; the
  secret is *not* printed, because it does not need to be.
* **no store configured** — the old print-once behaviour, plus an explicit
  "THIS TASK SAVED IT NOWHERE", what is lost if the line is lost, and the
  one-line config that makes future rotations safe.
* **store failed after re-encryption** — prints the secret as the only copy in
  existence, then raises. Withholding it to keep secrets off stdout would
  destroy the credentials it was protecting.

### 4. The app reads the key without a config edit

`Encryption`'s tier resolution gained one step: explicit
`:integrations_encryption_key` still wins, then the key store, then the legacy
`secret_key_base` fallback, then nothing. A stored key reports as the same
healthy `:dedicated` tier — it *is* a dedicated key, just one nobody had to
paste by hand. Reads are memoised in `:persistent_term` (encryption runs once
per credential field; an unmemoised read would open a file every time) and
invalidated when a rotation stores a new secret. Failures are never cached: a
file briefly unreadable during a deploy must not become permanently unreadable
for the life of the VM.

### Secrets never travel in error terms

Every failure carries a path and a cause, never the secret. A secret in an error
tuple reaches a log, a crash report or a support ticket, and a secret in a log
is compromised in the only sense that matters. There is a test that asserts no
failure path contains the secret.

## Verification

### Unit — 46 tests, 0 failures (2 added this round)

Round-trip; `0600`/`0700`; trailing newline tolerated; no `.tmp` left behind;
missing file vs empty file vs whitespace-only file; refusal inside a clone and
inside a linked worktree; pre-flight refuses the same and does not disturb an
existing secret; caching and invalidation; failures not cached; both config
shapes; two deliberately broken stores — one whose `write` returns `:ok` while
storing nothing, one that stores something else — to prove the read-back catches
them; a store module that does not exist, one that raises, and one missing a
callback, each asserted to produce an error that does **not** contain the
secret; the umask window; the permission warning; and `--new-key` length
refusal.

### Live, end-to-end, three separate BEAM processes

A real PostgreSQL database, the real mix task, and a genuine restart (separate
OS processes), not a simulated one.

**Seed** — an install on the `:dedicated` tier with a real encrypted credential:

    tier: :dedicated
    seeded uuid=01a014eb-702f-7257-a267-0272faf9be3f api_key="sk-s004-live-secret-value"

Confirmed on disk, straight from psql — ciphertext, not plaintext:

    {"name": "s004-live-check", "api_key": "enc:v1:GKrrMeVpDJdE/sPdh9k3DGurDZJvwhV2zyn3VnRBsQjxvqz06YOJ3hgPn1eARTssGOLYkmM=", ...}

**Rotate** — the real task, store configured:

    Rotated 1 connection(s).

    The new secret was written to /root/.config/phoenix_kit/s004-check.key (mode 0600) and read back to confirm
    it landed. Nothing else to copy: PhoenixKit reads the key from there.

    -rw------- 1 root root 44   /root/.config/phoenix_kit/s004-check.key

The secret was never printed, because it did not need to be.

**Restart** — a brand new process, no explicit key anywhere:

    explicit key configured? nil
    tier after restart: :dedicated
    decrypted api_key: "sk-s004-live-secret-value"
    RESULT: MATCH

**Negative control** — same database, same fresh process, store *not*
configured. Without this, the run above would prove nothing:

    store configured? nil
    tier: :disabled_no_key
    RESULT: could not read the secret, as expected —
      {:ok, %{"api_key" => "enc:v1:bGe0oJVQ38DU9UmZEn+y9YzIKsaLB0BxOIj7qHxKOstTmT/ey+fdlvewmVCdj7t0m+Z3Xuw=", ...

Probe data and the probe key file were removed afterwards; the settings table
holds no rows from this exercise.

## Review round (independent Opus reviewer) — verdict FAIL, then fixed

The first implementation was reviewed independently and came back **FAIL**: one
critical, six major. The reviewer verified its claims with local probes rather
than reading alone, and it was right on every substantive point. What changed:

### Critical — a configured-but-unreadable store fell through in silence

`stored_dedicated_key/0` collapsed `{:error, _}` into `:unset`, so an unreadable
key file resolved to the legacy tier with **no log line anywhere** — while this
module's own docs say those two states must never be collapsed. The damage is
two-way: old rows stop decrypting, new rows get written under the legacy key,
and repairing the file later leaves those new rows unreadable forever.

Fixed: the failure is now logged once per VM at `:error`, and the boot warning
no longer tells the operator to run `rotate_key` — which would have been exactly
the wrong advice. Verified live:

    store read: {:error, {:empty, "/root/.config/phoenix_kit/s004-broken.key"}}
    tier: :legacy_secret_key_base
    [error] A key store IS configured but its secret could not be read
            ({:empty, ...}). Falling back to a weaker key tier: ... repairing the
            store later will not make those rows readable.
    [warning] A key store is configured (...) but its secret could not be read ...
              Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this —
              the stored key may still be the one your data is encrypted under.

The fallback itself was kept deliberately. Refusing would resolve to no key at
all, and a nil key makes writes store **plaintext** — worse than the weaker key.

### Major — the secret reached disk at 0644 before the chmod

`File.write/2` creates by umask. The temp file is now created empty with
`:exclusive`, chmod'ed to 0600, and only then written. The test that checks this
asserts the right invariant — not "never 0644" (it briefly is, while empty) but
never *readable by others while holding anything*.

### Major — "atomic" was not durable

`File.write` + rename without `:file.sync` can survive a crash as a file that
exists and is empty — literally the incident shape this module exists for, and
read-back verification cannot catch it because that read comes from page cache.
Now: sync the file before the rename, sync the directory after.

### Major — the secret could reach a crash report

`module.write(secret, opts)` on a mistyped or unloaded store module raises
`UndefinedFunctionError`, and Erlang formats such reports **with the arguments**.
All store calls now go through a wrapper that checks the module is loaded and
exports the callback, and rescues anything else keeping only the exception's
struct name. Tested.

### Major — `--new-key` was not length-checked

A short key was accepted, every row re-encrypted under it, and the secret
reported as safely stored — then `Encryption` rejected it as too weak on the
next boot and everything rotated became unreadable. Now refused at parse time,
before anything runs. One pre-existing test asserted the old behaviour and was
updated with the reason.

### Major — an explicit key silently outranks the store

With both `:integrations_encryption_key` and a store set, the rotation stores a
key the app will never read.

**I first fixed this by refusing to rotate, and that was wrong.** Migrating from
an explicit key to a store *requires* the explicit key during the rotation — it
is what decrypts the current rows — and it can only be removed afterwards.
Refusing left no migration path at all. Replaced with a loud ACTION REQUIRED
block printed on success, telling the operator to remove the setting before
restarting. Confirmed in the live run below.

### Major — multi-host claim was too broad

"Nothing else to copy" is true on one host and false on a cluster: the file store
is per-host, and `:persistent_term` is per-node. The success message now says so.

### Minor, also fixed

Symlink bypass of the repository guard (a symlinked parent directory defeated
the lexical check — now resolved per component, without `File.cd`, which is
VM-global); `false`/`true` accepted as a store module; permission warning
repeating on every read (5 lines per run → 1 per path per VM, measured);
`status/0` docstring no longer promising a pure, IO-free, non-raising call; the
"too short" warning naming a config key the operator may never have set; the
task's moduledoc, which still said "this task does NOT write any config file".

Left as noted, not fixed: the reviewer's point that a `preflight` creates
directories even if the rotation later aborts, and that `--new-key` with
surrounding whitespace would mismatch on read-back (the store trims). Both are
real and neither can lose data.

## Independent review round (Pi) — SHIP, with follow-ups applied

An independent checker returned **SHIP**, and separately flagged residual
vectors. Notably it found **none** of the seven defects the internal Opus review
had produced, which is evidence the earlier fixes actually landed rather than
being declared. What it raised, and what happened:

### Its highest-priced question: does the broken-store advice send you to rotate_key?

It could not check — that branch is outside the diff — and said so instead of
guessing. Checked here, and the answer is **no**: the `:disabled_no_key` branch
prints `plaintext_warning/1`, which advises `integration_encryption_enabled` and
`integrations_encryption_key` and never mentions rotation
(`encryption.ex:529-534`). Even if run, `KeyRotation.rotate/2` refuses outright
when encryption is inactive, so the catastrophic path does not exist.

The finding was still right, just cheaper than feared. In that state the message
was wrong twice: it never mentioned that a store is configured and broken — the
actual cause — and it recommended setting `integrations_encryption_key`, which
would then permanently **shadow** the store. The store-unreadable branch, added
for `:legacy_secret_key_base`, was missing here. Now present, verified:

    tier: :disabled_no_key
    [warning] A key store is configured (...) but its secret could not be read:
              NO key resolved at all — integration credentials are being written
              in PLAINTEXT. Do NOT run `mix phoenix_kit.integrations.rotate_key`
              to fix this ... Repair the store first.

Writing that fix produced a smaller version of the same defect and it is worth
recording: the reused message said *"encryption fell back to the
secret_key_base-derived key"* — false in this branch, where nothing was fallen
back to. The wording is now chosen per tier, and both were checked:

    tier: :legacy_secret_key_base  -> "...fell back to the secret_key_base-derived key,
                                       so values written under the stored key will not decrypt"
    tier: :disabled_no_key         -> "NO key resolved at all — ... written in PLAINTEXT"

### The `inspect/1` fallback could carry a third-party store's secret

`describe_store_error/1` and the store-failure log ended in `inspect(reason)`.
Reasons produced here are safe, but a host-supplied store returns whatever it
likes — plausibly an error quoting the value it failed to store. Replaced with
`KeyStore.describe_error/1`, which formats only recognised shapes and reduces
anything else to its outermost tag. Tested: an unknown `{:some_custom_failure,
secret}` yields the tag plus "details withheld", and the secret is absent.

### The "failures not cached" test tested the wrong thing

It primed the cache with `:not_configured`, which is not a failure, so it
asserted nothing about the branch it named. Now uses a genuine
`{:error, {:empty, _}}`, asserts it is re-read rather than cached, and that
recovery is picked up. The `:not_configured` case kept as its own test.

### Breaking changes, stated plainly

Two, neither previously called out:

* `--new-key` now **refuses** a secret shorter than
  `Encryption.min_dedicated_key_length/0` (20). Previously accepted, and the
  result was silent data loss on the next boot — but a script passing a short
  key will now fail where it used to "succeed".
* The no-store success text changed (it now says the secret was saved nowhere).
  Anything scraping that output will see different wording.

### Left as noted, not fixed

`ensure_dir/1` chmods a pre-existing directory 0700 best-effort and does not
fail if it cannot — tightening someone else's directory is not this code's call,
and refusing to store the key over it would be worse. `preflight` creates
directories even if the rotation later aborts. `--new-key` with surrounding
whitespace mismatches on read-back because the store trims. None can lose data.

### Still open: the existing suite

Three further attempts to run the DataCase-based tests in this container, all
unsuccessful: `MIX_ENV=test mix compile --force`, `mix test --no-compile`, and
loading the module directly. The last is the informative one —
`MIX_ENV=test mix run -e 'Code.ensure_loaded(PhoenixKit.DataCase)'` returns
`{:module, PhoenixKit.DataCase}` from `_build/test/.../Elixir.PhoenixKit.DataCase.beam`,
so the module exists and is loadable; only `mix test` fails to see it. Whatever
this is, it is not in this change's diff, and the regression status of the
existing rotation and encryption tests remains **unknown, not green**.

**Resolved as environmental, 2026-08-18 (contract I054).** Another line ran the
same file on a clean clone of core merged to upstream 2.13.1: 49 tests, 0
failures — including the endpoint-fallback test that fails here — and a full
suite run of 3949 tests, whose 12 failures were each shown to pre-exist on clean
`upstream/main`. That a 3949-test run happened at all also answers the open
question about `DataCase`: those tests compile there and do not here, which is
the same root seen from the second angle.

So the blocker is `/app`'s environment, not this code and not upstream. What it
does **not** establish is that this branch regresses nothing: the clean clone
ran upstream, not this work. The branch's own regression status stays unmeasured
until `/app` can run a suite — which is what I054 is for.

## Review round 2 (Pi) — SHIP, one new defect in the fixes themselves

The follow-up round found something the first did not: **the fix for one message
left its sibling behind.** `store_unreadable_warning/1` was made tier-aware;
`log_store_failure_once/1` was not. In a single run an operator could get two
messages contradicting each other about whether a fallback key even existed —
one saying encryption fell back to the `secret_key_base`-derived key, the other
that no key resolved at all.

This is worth recording as a pattern, not just a bug: a verdict-driven fix is
exactly where one thing gets repaired and the thing next to it is disturbed.

Both messages now derive their wording from **one** function,
`store_unreadable_consequence/0`, so they cannot diverge again. It reads
`secret_key_base/0` rather than `status/0` — status resolves the tier, which
consults the store, which is what called it; asking for status there would
recurse. Verified in both directions, in one run each:

    tier: :legacy_secret_key_base
      [error]   ... could not be read (... exists but is empty): encryption fell back ...
      [warning] ... could not be read: encryption fell back ...

    tier: :disabled_no_key
      [error]   ... could not be read (... exists but is empty): NO key resolved at all ...
      [warning] ... could not be read: NO key resolved at all ...

Two tests in `encryption_test.exs` pin it: with a legacy secret neither message
may say PLAINTEXT; with no key at all both must, and neither may claim a
fallback. They clear the once-per-VM latch in setup — deliberately white-box,
because the alternative is a test that passes silently because the message had
already been emitted.

Not changed: `describe_error/1` handles a three-element
`{:verification_failed, path, reason}` through its generic clause. No code here
produces that shape, and the generic clause already withholds an unknown
payload, so the behaviour is correct — it was raised as a nitpick, not a defect.

### A second symptom of the same environment breakage

While adding those tests, one **pre-existing** test in `encryption_test.exs`
turned out to fail here: "falls back to the host endpoint's secret_key_base when
the flat key is unset". Established as not caused by this work:

* the committed version of the file, without the new tests, fails identically;
* it fails in isolation too, so it is not test-order pollution;
* with no store configured — the case in that test — the new tier is a no-op:
  `KeyStore.configured()` returns `nil` and `stored_dedicated_key/0` returns
  `:unset`, exactly as before this change existed.

The likely root is the one already recorded: `test_helper.exs` does not complete
in this container (`PhoenixKit.Test.Repo is not available`), and it is what
starts `PhoenixKitWeb.Endpoint` — the endpoint this test reads its
`secret_key_base` from. Same cause as the DataCase compile failure, now visible
from a second angle.

## Three things found on the way

### 1. With no key at all, credentials come back as ciphertext (NOT fixed here)

The negative control above is also a finding. `Encryption.decrypt_fields/1`
returns its input unchanged when no key resolves
(`lib/phoenix_kit/integrations/encryption.ex:117-120`), so
`Integrations.get_credentials/2` hands back `"enc:v1:..."` **as if it were the
credential**. A caller would send that string to a third-party API as a bearer
token.

An earlier PR fixed exactly this shape one level down — a decrypt *failure* now
logs and drops the field rather than returning ciphertext
(`encryption.ex:303-323`). The no-key branch above was not covered by that fix,
and it is reached by precisely the scenario this task is about: the key was
lost.

Left alone deliberately — it is outside this task's boundary, and the fix needs
care, because write paths use `decrypt_fields_with_failures/1` to restore
untouched ciphertext and must not start erasing fields. Flagged for the owner.

### 2. ExUnit's own `tmp_dir` is inside the repository

The first version of the tests used `@tag :tmp_dir` and every write was refused
— ExUnit puts that directory at `<project>/tmp/...`. The guard was right and the
test was wrong. Worth knowing before someone "fixes" the guard to make a test
pass. (The tests now use a directory outside the checkout; the stray key files
that first run left behind were deleted.)

### 3. Pre-existing: DataCase tests cannot compile in this container

`mix test` fails to compile any test using `PhoenixKit.DataCase`
("module PhoenixKit.DataCase is not loaded and could not be found"), although
the beam exists in `_build/test`. Established as pre-existing by bisection: with
both new files moved out of `lib/`, an untouched test
(`test/phoenix_kit/integrations/providers_test.exs`) fails identically. Not
investigated further — it belongs to whoever owns the test environment.

## What was NOT verified

* **No rotation was run against the live Hydroforce stand.** Its server is down,
  another line is working in its directory, and — the substantive reason — it
  has *no* `integrations_encryption_key` configured, so it runs on the legacy
  tier. Rotating it would only be safe once `integrations_key_store` is set in
  its own config permanently; configured only through this session's
  environment, the next real restart would find no store, fall back to
  `secret_key_base`, and fail to decrypt everything just rotated. That is a
  deployment decision for the stand's owner, not something to do to a live site
  from a neighbouring session. The end-to-end evidence above is a real database
  and a real restart, but it is not that stand.
* **The DataCase-based integration suite did not run** — see finding 3. The
  affected files include the existing rotation and encryption-write-safety
  tests, so their regression status is unknown, not green. (Since established as
  an environment fault in `/app` rather than a code fault — see the resolution
  note above and contract I054. The status of *this branch* under a working
  suite is still unmeasured.)
