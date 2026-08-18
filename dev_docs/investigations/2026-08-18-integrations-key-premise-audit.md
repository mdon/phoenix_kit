# Round 6 — auditing the premises, not the states

2026-08-18. S004 part 2. Branch `security-integrations-encryption-key`.
Working log, written as the work happened.

## Why this round is shaped differently

Five rounds, five instances of one defect. The diagnosis reached at round 5:

> a claim about the state of the system, made in ONE place, rests on the
> behaviour of ANOTHER place — and that behaviour is assumed, not checked.

Enumerating states cannot catch this. The enumeration checks the *output*
against rules; the rules themselves are premises, and they were written by the
same reasoning that wrote the code. Round 5 proved it: the reachability rule
"an unreadable store cannot have supplied the key in use" was true, irrelevant,
and hid a reachable state.

So this round inverts the order. Nothing was edited until every claim the
diagnostics make had been written down as *a premise about another function's
behaviour*, and every premise checked **by running it**. Reading produced the
hypotheses below; only the run column decides.

Scripts: `/tmp/.../premises/*.exs`, run as
`MIX_ENV=test mix run --no-start <script>`. Each drives the real resolution
through `Application.put_env` and asks the real public functions.

## The premise table

| # | The claim, and where it is made | What it assumes about other code | Verdict (by running) |
|---|---|---|---|
| P1 | `{:dedicated, :store_unreadable}`: "the next rotation will **refuse at its pre-flight**" | `KeyStore.preflight/0` fails when the secret cannot be READ | **FALSE** — empty (unreadable) key file, writable dir: `cached_read → {:error, {:empty, …}}`, `preflight → :ok` |
| P2 | same sentence | `KeyRotation.rotate/2` runs a pre-flight at all | **FALSE** — with `preflight → {:error, {:inside_repository, …}}`, `rotate/2` walked straight past it into the repo lookup. Only the mix task checks, and only in `run_real` |
| P3 | `{too_short?: true, tier: :none}`: "`rotate_key` generates one, and stores it for you", `rotation_safe?: true` | `rotate/2` can run with no active key | **FALSE** — `rotate/2 → {:error, {:encryption_disabled, :disabled_no_key}}`. The advice names a command that refuses |
| P4 | `{_, :key_too_short}` advice: replace the short key | a too-short *config* key does not hide a working stored key | **CONFIRMED, and it does hide it** — store alone → `:dedicated`; add a short config key → `:legacy_secret_key_base`. `configured_dedicated_key/0` returns `:too_short` without ever consulting the store |
| P5 | the design "keeps the two absences apart": `{:no_secret_yet, loc}` vs `{:holding, loc}` | `store_state/0` produces `{:no_secret_yet, _}` | **FALSE** — a configured store whose file does not exist yet reads `:not_configured`, and `store_state/0` maps it to `{:holding, loc}`. `{:no_secret_yet, _}` is never produced in production |
| P7 | enumeration rule: `too_short? ∧ tier: :dedicated` unreachable | a rejected key never reaches the dedicated tier | **TRUE** — short key in config → `:legacy`; short secret in the store → `:legacy` |
| P8 | round 5's fix reached every surface | admin page keys on the same diagnosis | **FALSE** — `status/0 → :dedicated` (banner hidden entirely) while `key_diagnosis/0 → {:dedicated, :store_unreadable}` labels the healthy key "FALLBACK key — the configured key store could not be read" |
| P9 | `enabled?: false` → "written in PLAINTEXT" | `encrypt_fields/1` skips encryption | **TRUE** — value stored verbatim |
| P10 | `tier: :none` → "written in PLAINTEXT" | same | **TRUE** — stored verbatim, round-trips verbatim |
| P11 | shared action: "repairing it later will NOT make anything written in the meantime readable" | values written meanwhile are ciphertext | **FALSE in the no-key branch** — they are plaintext, i.e. readable by anyone. The sentence understates it into the opposite |
| P12 | `Key store: <loc>` implies the key in use is backed up there | config key and stored key agree | **FALSE** — an explicit config key shadows a different stored secret (`b1222f8ed9a6` → `119d8e27f303`), reported as `{:dedicated, :ok}` with no mention |
| P20 | `key_signals/0`: "everything … is read here, **once**" | the gather makes one pass | **FALSE** — up to four resolutions per call, and read failures are deliberately not memoised. A store that fails one read and answers the next produced 2 reads in one call |

## What P20 actually produced

The decisive one, because it breaks the invariant round 4 introduced to make
this family structurally impossible — "the fingerprint and the tier that
produced it are one term".

A store that fails its first read and succeeds afterwards (a mount that blips, a
network secrets store, a file being rewritten):

```
store reads during ONE key_signals/0: 2
signals:   %{tier: :legacy, store: {:holding, "/flaky/store.key"},
             too_short?: false, fingerprint: {:ok, "2395aad025c3"}}
diagnosis: {:legacy_secret_key_base, :no_dedicated_key}
summary:   "integration credentials are encrypted with a key DERIVED from secret_key_base"
label:     {:ok, "2395aad025c3", "derived from secret_key_base"}

fp(secret_key_base)  = 826f21f672e5
fp(STORED secret)    = 2395aad025c3   <- the number that was printed
```

The report says the key is derived from `secret_key_base` and prints the
fingerprint of the **stored dedicated key** under that label. Two operators
comparing sites would be comparing unlike things while both pages claim the same
tier — the exact failure the fingerprint exists to prevent.

It also yields `{:holding, _} ∧ tier: :legacy`, which the enumeration declares
unreachable. Round 4 moved the contradiction out of the verdict and into the
gather; nothing was watching there because the gather was assumed to be atomic.

## Findings, in the order they will be fixed

* **F7 (root)** the gather is not one pass → fingerprint/tier/store can disagree.
* **F1** `{:dedicated, :store_unreadable}` promises a pre-flight refusal that
  neither `rotate/2` nor the pre-flight itself performs.
* **F2** `{too_short?, tier: :none}` advises a rotation that refuses, and marks
  it safe.
* **F3** `store_state/0` collapses "no secret yet" into "holding" — the exact
  collapse `KeyStore.read/0`'s own docs forbid.
* **F4** the enumeration's reachability rule excludes `{:holding} ∧ ¬dedicated`,
  which F3 and F7 both produce. Third false reachability rule in three rounds.
* **F5** the admin page never received round 5's fix: no banner, FALLBACK label.
* **F6** the shared repair action tells the no-key case its plaintext writes
  will be unreadable.
* **F8** the branch left the suite red: `test/phoenix_kit_test.exs:130` pins a
  boot phrase this branch replaced. Baseline full run: **3932 tests, 1 failure**.
* **F10** (recorded, lower severity) a short config key silently shadows a
  working stored key, and nothing says so.
