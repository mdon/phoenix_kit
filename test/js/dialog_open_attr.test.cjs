"use strict";

// Unit tests for PkDialog's `open`-attribute guard in
// priv/static/assets/phoenix_kit.js. A <dialog> that showModal() put in the
// top layer but whose `open` attribute has gone missing still LOOKS open and
// yet behaves as closed: Escape's close steps and close() both return early,
// so no `close` event fires and the hook never pushes the server's close event
// — the modal leaves the screen while the server still believes it is open,
// and comes back on the next patch. The guard restores the attribute first.
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

const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: noop,
  key: () => null,
  length: 0,
};

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

const { isDialogOpenInBrowser } = require("../../priv/static/assets/phoenix_kit.js");
const PkDialog = global.window.PhoenixKitHooks.PkDialog;

// A <dialog> stub: `modal` is what the browser's `:modal` answers, `open` is
// the attribute a LiveView patch can strip off it.
function dialog({ modal, open }) {
  const el = {
    open: open,
    matches: (selector) => (selector === ":modal" ? modal : false),
    setAttribute: (name, value) => {
      if (name === "open") el.open = true;
      el.attrs = Object.assign(el.attrs || {}, { [name]: value });
    },
  };
  return el;
}

test("a top-layer dialog whose open attribute was stripped gets it back", () => {
  const el = dialog({ modal: true, open: false });
  PkDialog._restoreOpenAttr.call({ el: el });
  assert.equal(el.open, true);
  assert.deepEqual(el.attrs, { open: "" });
});

test("a dialog that still has the attribute is left alone", () => {
  const el = dialog({ modal: true, open: true });
  PkDialog._restoreOpenAttr.call({ el: el });
  assert.equal(el.attrs, undefined);
});

test("a dialog the browser does not consider open is NOT forced open", () => {
  const el = dialog({ modal: false, open: false });
  PkDialog._restoreOpenAttr.call({ el: el });
  assert.equal(el.open, false);
  assert.equal(el.attrs, undefined);
});

test("isDialogOpenInBrowser falls back to the attribute when :modal is unsupported", () => {
  const legacy = {
    open: true,
    matches: () => {
      throw new SyntaxError("unknown pseudo-class :modal");
    },
  };
  assert.equal(isDialogOpenInBrowser(legacy), true);
  assert.equal(isDialogOpenInBrowser(Object.assign({}, legacy, { open: false })), false);
});

// Escape's `cancel` must push the server's close event by itself. Chromium
// dismisses a close-watcher dialog without ever firing `close`, so a hook that
// only pushes from `_onClose` leaves the server believing the modal is open —
// and it re-opens on the next patch (measured on a live page, 2026-09-20).
//
// These drive the REAL handler `mounted()` installs: mount the hook over a
// stub element that records its listeners, then invoke the `cancel` one. A
// re-implementation here would pass no matter what the bundle does.
function mountDialog({ closeable = true, children = [] } = {}) {
  const listeners = {};
  const pushed = [];
  const el = {
    open: true,
    id: "d",
    dataset: { closeEvent: "card_close", closeable: String(closeable) },
    attributes: [],
    matches: (selector) => selector === ":modal",
    setAttribute: () => {},
    removeAttribute: () => {},
    querySelectorAll: () => children,
    addEventListener: (name, fn) => { listeners[name] = fn; },
    removeEventListener: () => {},
    close: () => { el.open = false; },
  };
  const hook = Object.create(PkDialog);
  hook.el = el;
  hook.pushEvent = (event) => pushed.push(event);
  hook.pushEventTo = (_cid, event) => pushed.push(event);
  hook.handleEvent = () => {};
  hook.mounted();
  return { el, hook, pushed, cancel: listeners.cancel, close: listeners.close };
}

function cancelEvent() {
  const e = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  return e;
}

test("Escape on a plain dialog pushes the close event", () => {
  const d = mountDialog();
  d.cancel(cancelEvent());
  assert.deepEqual(d.pushed, ["card_close"]);
  assert.ok(d.el._pkStackClosePushedAt, "stamps so a close() echo is skipped");
});

test("a close() echo right after Escape does not push twice", () => {
  const d = mountDialog();
  d.cancel(cancelEvent());
  d.close();
  assert.deepEqual(d.pushed, ["card_close"], "the stamp suppressed the echo");
});

test("a dialog that is not closeable pushes nothing", () => {
  const d = mountDialog({ closeable: false });
  const e = cancelEvent();
  d.cancel(e);
  assert.equal(e.defaultPrevented, true);
  assert.deepEqual(d.pushed, []);
});

test("a stacked child relays instead of pushing the parent's close", () => {
  let childClosed = false;
  const child = {
    open: true,
    matches: (s) => s === ":modal",
    dataset: { closeEvent: "child_close" },
    attributes: [],
    close: () => { childClosed = true; },
  };
  const d = mountDialog({ children: [child] });
  const e = cancelEvent();
  d.cancel(e);
  assert.equal(e.defaultPrevented, true, "the parent stays open");
  assert.deepEqual(d.pushed, ["child_close"], "only the child's close is pushed");
  assert.equal(childClosed, true);
});

test("a child that already pushed its own close is not pushed again by the parent", () => {
  // Chromium fires `cancel` on every dialog in a grouped chain. When the
  // child's handler runs first it pushes and stamps; the parent relaying the
  // same close would double-fire a non-idempotent event (a toggle).
  const child = {
    open: true,
    matches: (s) => s === ":modal",
    dataset: { closeEvent: "child_close" },
    attributes: [],
    close: () => {},
    _pkStackClosePushedAt: Date.now(),
  };
  const d = mountDialog({ children: [child] });
  d.cancel(cancelEvent());
  assert.deepEqual(d.pushed, [], "the child's own push stands");
});

test("a stale stamp on a child does not swallow its close", () => {
  const child = {
    open: true,
    matches: (s) => s === ":modal",
    dataset: { closeEvent: "child_close" },
    attributes: [],
    close: () => {},
    _pkStackClosePushedAt: Date.now() - 5000,
  };
  const d = mountDialog({ children: [child] });
  d.cancel(cancelEvent());
  assert.deepEqual(d.pushed, ["child_close"]);
});

test("a backdrop close still pushes through the close event", () => {
  const d = mountDialog();
  d.close();
  assert.deepEqual(d.pushed, ["card_close"]);
});
