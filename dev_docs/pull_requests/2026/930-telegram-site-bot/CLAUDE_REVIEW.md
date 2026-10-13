# PR #930 — Website Telegram bot that users link their own chat to

**Author:** timujinne · **Merged:** 2026-10-13 (b67ef01ac) · **Reviewer:** Claude · **Released in:** 2.62.1

## Summary

Adds a site-wide Telegram bot (`SiteBot`, setting `telegram_notifications_connection`) that delivers user notifications.
Users link a chat from their notification settings with a one-time `t.me/<bot>?start=<token>` deep link
(`Telegram.Linking`); the card polls `getUpdates` while a link is pending. The notification channel falls back to the
site bot when the user has no personal bot, and treats site-bot failures that are not about the chat as transient.

Verdict: sound design. Token is 48 random bytes, hashed at rest, single-use (spent by the delete that reads it), bound to
the bot connection, private-chat only; the DB half of a batch runs under an advisory lock with Telegram I/O outside it;
the delivery bot always comes from the site setting, never from the user's config.

## Findings

- **BUG - MEDIUM (fixed):** `TelegramNotificationsCard` `disconnect` matched `:ok = Linking.unlink(...)`, so a failed
  `ChannelConfig.update` crashed the LiveView instead of showing an error. Now handled with a flash message.
- **BUG - MEDIUM (fixed):** `Linking.create_token/2` used `repo.insert!` inside a transaction whose `{:error, _}` branch
  was therefore unreachable; an insert failure raised through the Connect click. Now `insert` + `rollback`, so the
  caller's `{:error, _}` path (the card's "not available" message) actually runs.
- **IMPROVEMENT - MEDIUM (not changed):** every open card with a pending link polls every 3 s, so N waiting users means
  ~N/3 `getUpdates` calls per second against one bot. Safe in practice (links are 15-minute, throttled, one timer per
  card), but a per-bot single-flight (or a short result cache) would bound it. Left alone — over-engineering for the
  current scale.
- **NITPICK:** `link_one/4` swallows a `link_chat` failure after the token was spent; the chat is told "expired" and the
  user must press Connect again. Acceptable (rare, self-healing), noted for the record.
- **NITPICK:** unused `telegram_link` token rows are only removed by the user's next `create_token/2` (one row per user
  at most), not by a pruner. Bounded, harmless.
- **NITPICK:** `already_linked?/2` filters `users.custom_fields` by JSON path with no index; it runs once per failed chat
  per batch, behind an authenticated poll. Fine until the users table is very large.

## Checked

- Group chats and `/start@other_bot` cannot burn a token; a token minted for another bot stays unspent.
- Site-bot link honoured only while it is still the site's bot (`site_targets/1` re-checks `SiteBot.connection_uuid/0`).
- `classify/2` keeps bot-level failures (revoked token, deleted connection) transient for `:system`, so nobody is switched off.
- Deleting the connection turns the feature off through `connection_uuid/0` validation; the delete confirm warns about it.
