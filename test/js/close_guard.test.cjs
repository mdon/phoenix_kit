"use strict";

// Unit tests for `guardedInput` in priv/static/assets/phoenix_kit.js — the
// predicate behind PkDialog's `data-close-guard="input"`: an input event
// counts only when its target sits in a submittable form of THIS dialog.
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

const { guardedInput } = require("../../priv/static/assets/phoenix_kit.js");

// A target whose `closest` answers from a fixed map: selector → element.
function target(map) {
  return { closest: (selector) => (selector in map ? map[selector] : null) };
}

const dialog = { id: "outer" };
const nested = { id: "inner" };
const submitForm = { id: "save-form" };

test("a keystroke in a submittable form of this dialog trips the guard", () => {
  const t = target({ dialog: dialog, "form[phx-submit]": submitForm });
  assert.equal(guardedInput(dialog, t), true);
});

test("a filter form (phx-change only) does not count", () => {
  const t = target({ dialog: dialog });
  assert.equal(guardedInput(dialog, t), false);
});

test("typing inside a nested dialog leaves the outer one alone", () => {
  const t = target({ dialog: nested, "form[phx-submit]": submitForm });
  assert.equal(guardedInput(dialog, t), false);
});

test("missing pieces never throw", () => {
  assert.equal(guardedInput(null, target({})), false);
  assert.equal(guardedInput(dialog, null), false);
  assert.equal(guardedInput(dialog, {}), false);
});
