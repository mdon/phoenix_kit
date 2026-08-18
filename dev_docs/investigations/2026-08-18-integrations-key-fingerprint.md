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
