"use strict";

// Unit tests for `treePickerEnter` in priv/static/assets/phoenix_kit.js — the
// predicate behind TreePickerSearch's Enter (search at once, never submit the
// surrounding form, and leave an input method's composing Enter alone).
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
  cookie: "",
};

const storage = { getItem: () => null, setItem: noop, removeItem: noop };

global.window = {
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

const { treePickerEnter } = require("../../priv/static/assets/phoenix_kit.js");

test("Enter searches at once", () => {
  assert.equal(treePickerEnter({ key: "Enter" }), true);
});

test("an input method's composing Enter is left to confirm the composition", () => {
  assert.equal(treePickerEnter({ key: "Enter", isComposing: true }), false);
});

test("other keys are typing, not a search", () => {
  assert.equal(treePickerEnter({ key: "a" }), false);
  assert.equal(treePickerEnter(null), false);
});
