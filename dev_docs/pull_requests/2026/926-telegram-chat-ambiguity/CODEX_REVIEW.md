# PR #926 — Telegram chat ambiguity

Reviewer: Codex · Date: 2026-10-13 · Status: reviewed and fixed, unreleased

Reviewed chat selection, personal/system instruction filtering, owner threading,
the LiveView capture path, and Claude's empty-instructions-card fix.

## Findings

- **BUG - MEDIUM (fixed): the client's default update peek discarded older updates.**
  `get_updates_with_token/2` defaulted to `offset: -1`, contrary to its promise
  to leave another update consumer undisturbed. Telegram explicitly forgets
  older queued updates on a negative offset. The default now omits `offset`;
  callers can still request one explicitly.
- **BUG - MEDIUM (fixed): the peek changed the bot's update subscription.**
  Defaulting `allowed_updates` to `["message"]` changes Telegram's remembered
  subscription, affecting a bot's separate consumer. This option is now omitted
  unless requested. ChatLink already filters returned updates locally.

Both effects are documented by the [Telegram Bot API](https://core.telegram.org/bots/api#getupdates).
Req.Test request assertions cover the default body and explicit overrides.

The PR's ambiguity rule refuses multiple distinct private chats and preserves
already-linked ids. The UI's capture is owner-scoped and requests no offset.
Claude's instruction-card condition uses the filtered instruction list correctly.

## Tradeoffs

Kept the narrow `telegram_req_options` configuration seam. It permits only `:plug`,
is empty by default, and lets actual request/LiveView behavior be tested without
network traffic. Replacing it would require threading a transport through the
integration validator and asynchronous LiveView work for little practical gain.

Single-mode automatic linking establishes uniqueness within the pending update
batch, not cryptographic ownership of the chat. Verified ownership would require
a separate challenge/linking protocol; the PR does not introduce one. Manual
chat-id entry remains the explicit choice when auto-capture is ambiguous.
