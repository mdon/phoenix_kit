"use strict";

// Unit tests for `backdropClick`, `textareaSizeChanged` and `strayFieldClick`
// in priv/static/assets/phoenix_kit.js.
//
// `backdropClick` decides whether a click on a PkDialog closes it: the press
// and the release must both land on the <dialog> element, whatever the click's
// own target says. `textareaSizeChanged` decides whether a press on a textarea
// was a resize. `strayFieldClick` decides whether a click is the tail of a
// selection dragged out of a text field.
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

const { backdropClick, textareaSizeChanged, strayFieldClick, discardAttempt } = require("../../priv/static/assets/phoenix_kit.js");

const dialog = { id: "modal" };
const field = { id: "description" };

test("a press and release on the dialog itself is a backdrop click", () => {
  assert.equal(backdropClick(dialog, dialog, dialog, dialog), true);
});

test("a drag from a field out onto the backdrop is not", () => {
  // The browser reports the common ancestor — the dialog — as the click target.
  assert.equal(backdropClick(dialog, field, dialog, dialog), false);
});

test("a drag from the backdrop that ends inside the box is not", () => {
  // Same common ancestor, so the click target is the dialog here too.
  assert.equal(backdropClick(dialog, dialog, field, dialog), false);
});

test("a click inside the box is not", () => {
  assert.equal(backdropClick(dialog, field, field, field), false);
});

test("a click with no recorded press or release does not close", () => {
  assert.equal(backdropClick(dialog, null, dialog, dialog), false);
  assert.equal(backdropClick(dialog, dialog, null, dialog), false);
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

// A node whose `contains` answers from a fixed list of descendants.
function node(tagName, extra, descendants) {
  const el = Object.assign({ tagName: tagName }, extra || {});
  el.contains = (other) => other === el || (descendants || []).indexOf(other) !== -1;
  return el;
}

const textarea = node("TEXTAREA");
const emailInput = node("INPUT", { type: "email" });
const checkbox = node("INPUT", { type: "checkbox" });
const paragraph = node("P");
const wrapper = node("DIV", {}, [textarea, emailInput, checkbox, paragraph]);
const elsewhere = node("DIV");

test("a selection dragged out of a textarea is not a click on its wrapper", () => {
  assert.equal(strayFieldClick(textarea, wrapper, 1), true);
  assert.equal(strayFieldClick(emailInput, wrapper, 1), true);
});

test("an ordinary click on the field itself goes through", () => {
  assert.equal(strayFieldClick(textarea, textarea, 1), false);
});

test("a press on something that is not a text field goes through", () => {
  assert.equal(strayFieldClick(checkbox, wrapper, 1), false);
  assert.equal(strayFieldClick(paragraph, wrapper, 1), false);
});

test("a keyboard activation is never stopped", () => {
  assert.equal(strayFieldClick(textarea, wrapper, 0), false);
});

test("a click on an element that does not contain the field goes through", () => {
  assert.equal(strayFieldClick(textarea, elsewhere, 1), false);
});

test("a click with no recorded press goes through", () => {
  assert.equal(strayFieldClick(null, wrapper, 1), false);
});

// `discardAttempt` — the verdict on one Escape / backdrop click against a
// modal holding typed input, given when the last attempt was refused.

test("the first attempt on unsaved input is refused", () => {
  assert.equal(discardAttempt(0, 10_000), "refuse");
  assert.equal(discardAttempt(undefined, 10_000), "refuse");
});

test("a second attempt soon after goes through", () => {
  assert.equal(discardAttempt(10_000, 11_000), "allow");
});

test("the same key reaching a stacked dialog twice is one attempt", () => {
  assert.equal(discardAttempt(10_000, 10_020), "same");
});

test("an attempt long after the refusal is a first attempt again", () => {
  assert.equal(discardAttempt(10_000, 30_000), "refuse");
});
