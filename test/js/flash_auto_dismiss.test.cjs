"use strict";

// Regression test for the FlashAutoDismiss hook in
// priv/static/assets/phoenix_kit.js.
//
// `@flash` is ONE Phoenix assign covering all three kinds (info/warning/
// error). Putting or clearing a DIFFERENT kind's flash — or even the same
// kind with the same text — marks the whole `@flash` assign dirty, so
// LiveView re-diffs and patches every currently-shown flash node, not just
// the one that logically changed. `updated()` used to treat every such
// patch as "a new message landed, restart the timer", so a flash on a page
// where anything else touched flash state could sit forever without
// counting down. `data-flash-message` fingerprints the actual text so the
// timer only restarts for a genuinely new message.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

function stubElement() {
  return {
    style: {},
    dataset: {},
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute: noop,
    getAttribute: () => null,
    removeAttribute: noop,
    appendChild: noop,
    remove: noop,
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
}

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: noop,
  removeEventListener: noop,
  readyState: "complete",
};

const storage = { getItem: () => null, setItem: noop, removeItem: noop, key: () => null, length: 0 };

global.window = {
  PhoenixKitHooks: {},
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage,
  sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  setTimeout,
  clearTimeout,
};

global.localStorage = storage;
global.sessionStorage = storage;

require("../../priv/static/assets/phoenix_kit.js");

const hook = window.PhoenixKitHooks.FlashAutoDismiss;

function mountHook({ message, dismissAfter = "30" }) {
  const el = {
    style: {},
    dataset: { flashMessage: message, dismissAfter: dismissAfter, flashKind: "info" },
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
  };

  const ctx = Object.create(hook);
  ctx.el = el;
  ctx.pushEvent = noop;
  ctx.mounted();

  return { ctx, el };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test("dismisses on its own after the configured delay", async () => {
  const { el } = mountHook({ message: "Saved" });
  await sleep(60);
  assert.equal(el.style.opacity, "0");
});

test("a patch carrying the SAME message does not push the deadline out", async () => {
  // Simulates the real trigger: some OTHER flash kind changed (or the same
  // kind was cleared and reset), which dirties the whole `@flash` assign
  // and re-diffs this node too, even though its own message is unchanged.
  // The patch lands well before the original deadline, so a buggy restart
  // would still be mid-flight at the assertion below.
  const { ctx, el } = mountHook({ message: "Saved", dismissAfter: "30" });
  await sleep(20);
  ctx.updated();
  ctx.updated();
  await sleep(20);
  assert.equal(el.style.opacity, "0", "the original deadline was honored, not pushed out");
});

test("a patch carrying a genuinely NEW message restarts the timer", async () => {
  const { ctx, el } = mountHook({ message: "Saved" });
  await sleep(20);
  el.dataset.flashMessage = "Saved again";
  ctx.updated();
  await sleep(20);
  assert.notEqual(
    el.style.opacity,
    "0",
    "restarted from the second message, not still counting down from the first"
  );
  await sleep(20);
  assert.equal(el.style.opacity, "0");
});

test("destroyed() cancels the pending timer so dismiss() never fires after unmount", async () => {
  const { ctx, el } = mountHook({ message: "Saved", dismissAfter: "10" });
  ctx.destroyed();
  await sleep(30);
  assert.notEqual(el.style.opacity, "0");
});
