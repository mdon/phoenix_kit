"use strict";

// Unit tests for the gallery-mode hand-off in priv/static/assets/phoenix_kit.js.
// In gallery mode (`ViewerGallery`) a swipe slides between pictures itself and
// `ViewerSwipe` stands down — but only where `Fresco.gallery` exists. A host
// still serving an older fresco.js mounts no gallery, and a swipe there must
// keep stepping the viewer instead of doing nothing.
//
// These drive the REAL handler `ViewerSwipe.mounted()` installs.
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


require("../../priv/static/assets/phoenix_kit.js");
const { ViewerSwipe, ViewerGallery } = global.window.PhoenixKitHooks;

// Mount ViewerSwipe over stubs; returns the pushed events and the swipe handler.
function mountSwipe({ galleryHook }) {
  let handler = null;
  const pane = {
    addEventListener: (name, fn) => {
      if (name === "fresco:swipe") handler = fn;
    },
    removeEventListener: noop,
    querySelector: () => null,
  };
  const pushed = [];
  const hook = Object.create(ViewerSwipe);
  hook.el = { parentElement: pane, dataset: { hasNext: "true", hasPrev: "true", target: "#mb" } };
  hook.pushEventTo = (target, event, payload) => pushed.push({ target, event, payload });

  const realQuery = global.document.querySelector;
  global.document.querySelector = (sel) =>
    sel === '[phx-hook="ViewerGallery"]' && galleryHook ? {} : null;
  hook.mounted();
  global.document.querySelector = realQuery;

  return {
    pushed,
    swipe: (direction) => {
      global.document.querySelector = (sel) =>
        sel === '[phx-hook="ViewerGallery"]' && galleryHook ? {} : null;
      try {
        handler({ detail: { direction } });
      } finally {
        global.document.querySelector = realQuery;
      }
    },
  };
}

test("without gallery mode a swipe steps the viewer", () => {
  global.window.Fresco = undefined;
  const { pushed, swipe } = mountSwipe({ galleryHook: false });
  swipe("left");
  assert.deepEqual(pushed, [{ target: "#mb", event: "step_viewer", payload: { dir: "next" } }]);
});

test("with gallery mounted on a fresco that has it, the swipe is left to the gallery", () => {
  global.window.Fresco = { gallery: noop };
  const { pushed, swipe } = mountSwipe({ galleryHook: true });
  swipe("left");
  assert.deepEqual(pushed, []);
});

test("a gallery hook on an older fresco.js (no Fresco.gallery) does not swallow the swipe", () => {
  global.window.Fresco = {};
  const { pushed, swipe } = mountSwipe({ galleryHook: true });
  swipe("right");
  assert.deepEqual(pushed, [{ target: "#mb", event: "step_viewer", payload: { dir: "prev" } }]);
});

test("ViewerGallery mounts and tears down quietly without Fresco.gallery", () => {
  global.window.Fresco = {};
  const hook = Object.create(ViewerGallery);
  hook.el = { id: "g", dataset: {}, parentElement: {} };
  assert.doesNotThrow(() => hook.mounted());
  assert.doesNotThrow(() => hook.updated());
  assert.doesNotThrow(() => hook.destroyed());
});
