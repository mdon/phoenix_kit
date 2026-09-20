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
