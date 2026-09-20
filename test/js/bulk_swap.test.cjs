"use strict";

// Unit tests for BulkSelectScope's `data-bulk-swap` in
// priv/static/assets/phoenix_kit.js — the toolbar a scope REPLACES while it
// holds a selection.
//
// Revealing the action bar without hiding anything pushes every row down, so
// the next click lands on the wrong checkbox (boss via Max, 2026-09-20;
// measured at 52px on the catalogue's category list, more than one row).
//
// The subtle part is a page with SEVERAL scopes over one toolbar: it must
// stay hidden while ANY of them has a selection, so clearing one list does
// not restore a toolbar the other list's bar is still standing in for.
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

const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: noop,
  key: () => null,
  length: 0,
};

// A tiny document the hook can query: scopes by [data-bulk-swap], and one
// toolbar reachable by its selector.
const registry = { scopes: [], targets: {} };

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: (selector) => {
    if (selector === "BAD[") throw new SyntaxError("bad selector");
    return registry.targets[selector] || null;
  },
  querySelectorAll: (selector) =>
    selector === "[data-bulk-swap]" ? registry.scopes : [],
  addEventListener: noop,
  removeEventListener: noop,
  readyState: "complete",
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

require("../../priv/static/assets/phoenix_kit.js");
const BulkSelectScope = global.window.PhoenixKitHooks.BulkSelectScope;

// A scope element whose rows report their own checked state.
function scope(selector, checkedCount) {
  const rows = Array.from({ length: 3 }, (_v, i) => ({ checked: i < checkedCount }));
  return {
    dataset: { bulkSwap: selector },
    querySelectorAll: (sel) => (sel === '[data-bulk-role="row"]' ? rows : []),
    rows,
  };
}

function setup(scopes, selector = "#toolbar") {
  const target = { style: {} };
  registry.scopes = scopes;
  registry.targets = { [selector]: target };
  return target;
}

function sync(el, count) {
  BulkSelectScope._syncSwap.call({ el }, count);
}

test("a selection hides the toolbar it replaces", () => {
  const only = scope("#toolbar", 1);
  const toolbar = setup([only]);

  sync(only, 1);
  assert.equal(toolbar.style.display, "none");
});

test("clearing the selection restores the toolbar", () => {
  const only = scope("#toolbar", 0);
  const toolbar = setup([only]);

  sync(only, 0);
  assert.equal(toolbar.style.display, "");
});

test("a second scope's selection keeps the shared toolbar hidden", () => {
  // The categories list clears while the items list still has rows selected:
  // its action bar is still on screen, standing in for this toolbar.
  const categories = scope("#toolbar", 0);
  const items = scope("#toolbar", 2);
  const toolbar = setup([categories, items]);

  sync(categories, 0);
  assert.equal(
    toolbar.style.display,
    "none",
    "restoring here would put the toolbar back under the other list's bar"
  );
});

test("the toolbar returns only once every scope is clear", () => {
  const categories = scope("#toolbar", 0);
  const items = scope("#toolbar", 0);
  const toolbar = setup([categories, items]);

  sync(categories, 0);
  assert.equal(toolbar.style.display, "");
});

test("a scope naming a different toolbar does not hold this one hidden", () => {
  const mine = scope("#toolbar", 0);
  const other = scope("#other-toolbar", 3);
  const toolbar = setup([mine, other]);

  sync(mine, 0);
  assert.equal(toolbar.style.display, "");
});

test("a scope with no swap target does nothing at all", () => {
  const toolbar = setup([]);
  sync({ dataset: {} }, 2);
  assert.deepEqual(toolbar.style, {}, "an untouched toolbar keeps its own display");
});

test("a missing target is survivable", () => {
  registry.scopes = [];
  registry.targets = {};
  assert.doesNotThrow(() => sync({ dataset: { bulkSwap: "#gone" } }, 1));
});

test("a malformed selector never takes the page down", () => {
  registry.scopes = [];
  registry.targets = {};
  assert.doesNotThrow(() => sync({ dataset: { bulkSwap: "BAD[" } }, 1));
});
