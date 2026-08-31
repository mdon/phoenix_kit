"use strict";

// Unit tests for the component-routing helper behind PkDialog's close push and
// InfiniteScroll's load-more push in priv/static/assets/phoenix_kit.js. The
// bundle is browser code (IIFEs that assign onto `window`), so stub the globals
// it touches at load time; the DOM-using hook methods are not invoked here.
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

const {
  ownerComponentCid,
  pushToOwner,
} = require("../../priv/static/assets/phoenix_kit.js");

// A minimal `closest`: `attrs` is what the nearest matching ancestor carries,
// or null for "nothing above me matches".
function elementWithAncestor(attrs) {
  return {
    closest(selector) {
      if (!attrs) return null;
      const wanted = selector.split(",").map((s) => s.trim().slice(1, -1));
      if (!wanted.some((name) => name in attrs)) return null;
      return {
        hasAttribute: (name) => name in attrs,
        getAttribute: (name) => (name in attrs ? attrs[name] : null),
      };
    },
  };
}

function fakeHook() {
  const calls = [];
  return {
    calls,
    pushEvent: (event, payload) => calls.push(["lv", event, payload]),
    pushEventTo: (target, event, payload) => calls.push([target, event, payload]),
  };
}

test("ownerComponentCid: a LiveComponent ancestor gives its numeric cid", () => {
  const el = elementWithAncestor({ "data-phx-component": "7" });
  assert.equal(ownerComponentCid(el), 7);
});

test("ownerComponentCid: nothing but the LiveView above means no cid", () => {
  assert.equal(ownerComponentCid(elementWithAncestor(null)), null);
  assert.equal(
    ownerComponentCid(elementWithAncestor({ "data-phx-session": "abc" })),
    null
  );
});

test("ownerComponentCid: a nested LiveView root stops the search", () => {
  // The nearest boundary is the nested view — a component ancestor beyond it
  // belongs to a different view, and its cid means nothing to this socket.
  const el = elementWithAncestor({ "data-phx-session": "abc" });
  assert.equal(ownerComponentCid(el), null);
});

test("ownerComponentCid: a junk cid is not pushed as NaN", () => {
  const el = elementWithAncestor({ "data-phx-component": "" });
  assert.equal(ownerComponentCid(el), null);
});

test("ownerComponentCid: survives an element without closest()", () => {
  assert.equal(ownerComponentCid(null), null);
  assert.equal(ownerComponentCid({}), null);
});

test("pushToOwner: routes to the owning component by cid", () => {
  const hook = fakeHook();
  pushToOwner(hook, elementWithAncestor({ "data-phx-component": "3" }), "close", {});

  assert.deepEqual(hook.calls, [[3, "close", {}]]);
});

test("pushToOwner: falls back to the LiveView with no component ancestor", () => {
  const hook = fakeHook();
  pushToOwner(hook, elementWithAncestor(null), "load_more", {});

  assert.deepEqual(hook.calls, [["lv", "load_more", {}]]);
});

test("pushToOwner: a missing payload still pushes an object", () => {
  const hook = fakeHook();
  pushToOwner(hook, elementWithAncestor({ "data-phx-component": "1" }), "close");

  assert.deepEqual(hook.calls, [[1, "close", {}]]);
});
