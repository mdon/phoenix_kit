# PR draft — V161: payment-option linkage on billing orders

**Base:** `BeamLabEU/phoenix_kit` `main` ← **Head:** `mdon:main`
**Commits:** 1 · one new migration file + the version bump in the index

> Pairs with `phoenix_kit_billing` (Order schema + changeset) and
> `phoenix_kit_ecommerce` (checkout persists the link). **Merge and
> release this first** — both consumers guard the column's absence, so
> they degrade rather than crash on an older core, but neither can record
> the link until this ships.

---

## Summary

Adds a nullable `payment_option_uuid` FK (plus its index) to
`phoenix_kit_orders`, pointing at `phoenix_kit_payment_options`.

An order records HOW it is to be paid via `payment_method` — a small
closed vocabulary (`bank`, `stripe`, `paypal`, `razorpay`). What the
customer actually chose at checkout is a payment-option ROW: an
operator-configured method with its own name, instructions, provider and
billing-profile requirement. The two are not the same thing. Several
options can share one `payment_method` ("Bank transfer (EU)" and "Bank
transfer (UK)" are both `bank`), and an option can be renamed or
deactivated after the order is placed.

Without a link the choice was discarded at conversion: nothing on the
order said which option the customer picked, so an operator processing a
bank transfer could not tell which instructions the customer had been
shown, and payment reconciliation had to guess.

## Why `ON DELETE SET NULL`

Deactivating and deleting a payment option is an ordinary operator action.
It must not be blocked by historical orders, and it must not destroy them.
The order keeps `payment_method` and its metadata snapshot regardless, so
a deleted option degrades to "we know it was a bank transfer" rather than
to nothing.

## Verification

`add_if_not_exists` / `create_if_not_exists` and matching `down/1`, so the
migration is re-runnable and reversible. The table comment moves to '161'
on up and back to '160' on down, per the marker convention.
