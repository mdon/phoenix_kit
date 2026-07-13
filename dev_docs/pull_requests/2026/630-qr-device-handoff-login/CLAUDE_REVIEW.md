# PR #630 — Add QR device-handoff login ("scan to sign in")

**Author:** Sasha Don (`alexdont`) · **Base:** `main` · **Merge:** `0da52166` · **Reviewer:** Claude (Sonnet 5)
**Scope:** new auth flow wrapping the [`keyfob`](https://hex.pm/packages/keyfob) 0.1.0 library — a signed-out browser shows a QR code, an already-signed-in phone scans + approves it, the browser signs in with no password. Off by default (`qr_login_enabled` setting).

Reviewed post-merge against `main`, with the full `keyfob` dependency source read alongside the integration to verify the library's own guarantees (single-use token, TTL enforcement, PubSub topic scoping) rather than assuming them from the PR description.

---

## BUG — CRITICAL / HIGH / MEDIUM

None found. The properties that matter most for an unauthenticated credential-granting flow all check out:

- **Single-use / TOCTOU:** `Keyfob.consume/2` uses an atomic `take/1` (GenServer-serialized) as the single-use gate — a second consume of the same login token deterministically returns `{:error, :not_found}`. Double-approve is blocked the same way via a `%Request{state: :pending}` guard inside a GenServer-serialized update.
- **Approval authorization:** the approving `user_ref` is derived server-side from `socket.assigns.phoenix_kit_current_user.uuid` (never from client params), and the confirm route sits inside the `:phoenix_kit_authenticated` live_session with the standard `:browser` pipeline's CSRF/session protections.
- **Open redirect:** the confirm page's pre-login `?return_to=` is built server-side from the actual request URI — pre-existing shared machinery, not new in this PR.
- **PubSub scoping:** `Keyfob.topic/1` is keyed by a hash of the (256-bit random) request token — unique per request, never global or guessable.
- **TTL enforcement:** enforced server-side in `approve/3`, `fetch_live/2`, and `consume/2` — not merely a client-side "show a new code" affordance.
- **Race conditions:** the token-keyed expiry timer correctly no-ops against a stale token after a refresh, matching the PR description's claim.
- **mount/3 discipline (desktop side):** the mutating `Keyfob.Live.init_panel` mint is correctly gated behind `connected?(socket)`, avoiding a double-mint on the dead HTTP render.
- **XSS / session fixation:** the QR SVG escapes its embedded title before splicing; `QrLoginComplete` reuses `UserAuth.log_in_user/2`, which renews the session before writing the new token — the same vetted path as password/magic-link login.

## IMPROVEMENT — MEDIUM (fixed)

- **`qr_login_enabled` wasn't an immediate kill switch.** Only the desktop entry point checked `QrLoginContext.enabled?()`; the phone-side confirm LiveView and the completion controller didn't. A request minted while the feature was on could still be approved and consumed after an admin disabled it mid-incident. **Fixed:** `QrLoginConfirm.mount/3` now redirects with a flash when disabled, `handle_event("keyfob_approve", ...)` re-checks at approval time (covers a toggle flip while the confirm page is already open), and `QrLoginComplete.complete/2` refuses to consume when disabled.
- **No rate limiting on QR request creation.** `keyfob`'s own moduledoc says rate-limiting request creation is left to the host, matching how PhoenixKit already guards password/magic-link/registration via `PhoenixKit.Users.RateLimiter` — but the QR desktop page (public, pre-auth, mints a live ETS entry on every connect) never called it. **Fixed:** added `RateLimiter.check_qr_login_rate_limit/1` (10 requests/minute per IP, mirroring the existing per-action config shape) and wired it into `QrLogin.mount/3`'s mint branch.
- **`mount/3` did a store `peek/2` lookup instead of gating it behind `connected?/1`.** Cheap today (a direct ETS lookup), but `keyfob` explicitly documents that clustered deployments need a shared (DB/Redis) store — if that swap ever happens, this becomes a real duplicated round-trip on every load. **Fixed:** gated behind `connected?(socket)`, matching the idiom already used by the sibling desktop LiveView's mint call.

## IMPROVEMENT — MEDIUM (not fixed, recorded)

- **No test coverage.** `git grep -l "Keyfob\|QrLogin" test/` returns nothing. This is a new, unauthenticated-entry-point credential-granting flow with no unit or integration tests. Not fixed here: a meaningful integration test (mint → approve → consume → double-consume-fails cycle) needs the Keyfob ETS store manually started (`PhoenixKit.Application.start/2` deliberately does not start `PhoenixKit.Supervisor` — the parent app does, per this repo's testing model) plus `:phoenix_kit_internal_pubsub`, and the pure-function surface (`device_meta/1`'s UA sniffing) isn't cheaply testable without a hand-rolled `Phoenix.LiveView.Socket` connect_info mock that risks being fragile/version-coupled. Flagging as a known gap rather than shipping a low-confidence test.

## NITPICK (not fixed — inherent to keyfob's API, not phoenix_kit-side)

- **`deny/2` has no ownership check.** Any authenticated user holding the (documented-as-semi-public) request token can deny someone else's pending/approved-but-unconsumed request. Not an auth bypass — worst case is griefing a login attempt if the token leaks (shoulder-surfed QR, browser history) — and there's no way to bind "intended approver" ahead of a device-handoff scan in keyfob's current API. Recorded for awareness, not actionable here.

## Testing

Ran the affected unit-testable surface: `mix test test/phoenix_kit/users/rate_limiter_test.exs` (new `check_qr_login_rate_limit/1` describe block: allow-within-limit, block-after-exceeding, per-IP isolation) — 35/35 passing, no PostgreSQL required. No DB-backed tests exist for the QR flow itself (see gap above).

## Gate

`mix compile --warnings-as-errors` clean after the fixes. Full `mix precommit` run alongside PR #631's fixes — see that review doc / the release commit for the combined gate result.
