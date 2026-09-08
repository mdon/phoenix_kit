"use strict";

// Unit tests for the pure `fitPageSize` helper behind the PageSizeAutoFit
// hook in priv/static/assets/phoenix_kit.js. Same global stubbing as
// push_to_owner.test.cjs — the bundle is browser code.
//
// Run: mix test.js

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
global.window = {
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, addListener: noop }),
  location: { href: "http://localhost/", origin: "http://localhost" },
  localStorage: { getItem: () => null, setItem: noop, removeItem: noop },
  document: global.document,
};
// Node >= 21 defines a global `navigator` as a getter-only accessor
// property, so a plain assignment throws; redefine it instead.
Object.defineProperty(global, "navigator", {
  value: { userAgent: "node" },
  configurable: true,
  writable: true,
});
global.localStorage = global.window.localStorage;
global.MutationObserver = class { observe() {} disconnect() {} };
global.IntersectionObserver = class { observe() {} disconnect() {} };

const { fitPageSize } = require("../../priv/static/assets/phoenix_kit.js");

const OPTIONS = ["10", "25", "50", "100"];

test("picks the largest option that fits", () => {
  assert.equal(fitPageSize(40 * 30, 30, OPTIONS), 25); // 40 rows fit → 25
  assert.equal(fitPageSize(60 * 30, 30, OPTIONS), 50);
  assert.equal(fitPageSize(500 * 30, 30, OPTIONS), 100); // clamped to max
});

test("never goes below the smallest option", () => {
  assert.equal(fitPageSize(3 * 30, 30, OPTIONS), 10);
  assert.equal(fitPageSize(-100, 30, OPTIONS), 10);
});

test("degenerate row height falls back to the smallest option", () => {
  assert.equal(fitPageSize(1000, 0, OPTIONS), 10);
  assert.equal(fitPageSize(1000, NaN, OPTIONS), 10);
});

test("unsorted or junk options are tolerated", () => {
  assert.equal(fitPageSize(30 * 30, 30, ["50", "10", "x", "25"]), 25);
  assert.equal(fitPageSize(1000, 30, []), null);
});
