"use strict";

// Unit tests for `backdropClick` and `textareaSizeChanged` in
// priv/static/assets/phoenix_kit.js.
//
// `backdropClick` decides whether a click on a PkDialog closes it: the press
// and the release must both land on the <dialog> element. `textareaSizeChanged`
// decides whether a press on a textarea was a resize.
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

const { backdropClick, textareaSizeChanged } = require("../../priv/static/assets/phoenix_kit.js");

const dialog = { id: "modal" };
const field = { id: "description" };

test("a press and release on the dialog itself is a backdrop click", () => {
  assert.equal(backdropClick(dialog, dialog, dialog), true);
});

test("a drag from a field out onto the backdrop is not", () => {
  // The browser reports the common ancestor — the dialog — as the click target.
  assert.equal(backdropClick(dialog, field, dialog), false);
});

test("a drag from the backdrop that ends inside the box is not", () => {
  assert.equal(backdropClick(dialog, dialog, field), false);
});

test("a click inside the box is not", () => {
  assert.equal(backdropClick(dialog, field, field), false);
});

test("a click with no recorded press does not close", () => {
  assert.equal(backdropClick(dialog, null, dialog), false);
});

test("a press that leaves the inline size alone is not a resize", () => {
  const size = { height: "", width: "" };
  assert.equal(textareaSizeChanged(size, { height: "", width: "" }), false);
});

test("a press that changes height or width is a resize", () => {
  const before = { height: "", width: "" };
  assert.equal(textareaSizeChanged(before, { height: "300px", width: "" }), true);
  assert.equal(textareaSizeChanged(before, { height: "", width: "420px" }), true);
});

test("a second drag from an already resized field is a resize too", () => {
  assert.equal(
    textareaSizeChanged({ height: "300px", width: "420px" }, { height: "180px", width: "420px" }),
    true
  );
});
