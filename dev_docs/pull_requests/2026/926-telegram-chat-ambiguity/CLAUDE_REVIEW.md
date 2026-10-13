# PR #926 — Telegram "Only me" no longer links whoever messaged the bot last

**Author:** timujinne · **Merged:** 2026-10-13 (0188e1d77) · **Reviewer:** Claude · **Released in:** unreleased

## Summary

`ChatLink.capture/4` in `"single"` mode links a private chat only when it is the ONLY private chat in the peek; with several it
links nothing and reports `ambiguous?` (the personal form shows a warning, offers no strangers' chats). Provider instructions
gain per-section `:scopes` (`Providers.instructions_for/2`) so the website form no longer promises chat linking it cannot do.
A `:telegram_req_options` seam lets tests route Bot API calls through `Req.Test`.

Verdict: closes a real account-takeover-shaped hole (a stranger messaging the bot after the owner used to win the single slot).

## Findings

- **IMPROVEMENT - MEDIUM (fixed)** — `setup_instructions/1` and the system integration form still gated the card on the
  provider's *unfiltered* instruction list, so a provider whose sections are all for the other surface rendered an empty
  "Setup instructions" card. Both now gate on the filtered list; test added.
- **NITPICK (open)** — `Telegram.req_options/0` reads app env in production code (only `:plug` is taken). Harmless unset, but
  it is a test seam living in `lib/`.

## Checked

- "The notification channel reads personal connections only" is true: `Notifications.Channels.Telegram` lists connections with `owner: {:user, uuid}`.
- Ambiguity does not leak: candidates stay groups-only, the flash names no chat, metadata is recorded for linked chats only.
- With a private chat already linked, newcomers are refused as before and `ambiguous?` stays false (nothing to tell the owner).
