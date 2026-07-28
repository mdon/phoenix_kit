"use strict";

// Unit tests for the pure decision logic behind the PopupLink hook
// in priv/static/assets/phoenix_kit.js. The bundle is browser code (IIFEs that
// assign onto `window`), so stub the globals it touches at load time; the
// DOM-using hook methods themselves are not invoked here.
//
// Run: node --test test/js

const test = require("node:test");
const assert = require("node:assert/strict");

// The bundle does real work at load: injects a <style>, registers page-loading
// listeners, reads storage. Stub just enough of a browser for it to load; no
// DOM-touching hook method is invoked by these tests.
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
// `globalThis.navigator` is getter-only on modern Node, so leave it be — the
// bundle reads `window.navigator`, which is stubbed above.

const {
  shouldOpenPopup,
  popupFeatures,
  sameOrigin,
} = require("../../priv/static/assets/phoenix_kit.js");

test("shouldOpenPopup: a plain left click opens the popup", () => {
  assert.equal(shouldOpenPopup({ button: 0 }), true);
  assert.equal(shouldOpenPopup({}), true);
});

test("shouldOpenPopup: leaves the user's own new-tab gestures alone", () => {
  // Intercepting these would break cmd-click / middle-click, which users
  // reasonably expect to open the OAuth start route in a tab of their own.
  assert.equal(shouldOpenPopup({ button: 1 }), false, "middle click");
  assert.equal(shouldOpenPopup({ button: 2 }), false, "right click");
  assert.equal(shouldOpenPopup({ button: 0, metaKey: true }), false, "cmd-click");
  assert.equal(shouldOpenPopup({ button: 0, ctrlKey: true }), false, "ctrl-click");
  assert.equal(shouldOpenPopup({ button: 0, shiftKey: true }), false, "shift-click");
  assert.equal(shouldOpenPopup({ button: 0, altKey: true }), false, "alt-click");
});

test("shouldOpenPopup: yields to a handler that already claimed the event", () => {
  assert.equal(shouldOpenPopup({ button: 0, defaultPrevented: true }), false);
});

test("shouldOpenPopup: a missing event never opens anything", () => {
  assert.equal(shouldOpenPopup(null), false);
  assert.equal(shouldOpenPopup(undefined), false);
});

test("popupFeatures: centres on the browser window, not the primary display", () => {
  // A window sitting on a second monitor at x=2000 must put its popup there
  // too; centring on size alone would fling it back to the primary screen.
  const features = popupFeatures(480, 680, {
    screenLeft: 2000,
    screenTop: 100,
    outerWidth: 1000,
    outerHeight: 900,
  });

  assert.match(features, /width=480/);
  assert.match(features, /height=680/);
  assert.match(features, /left=2260/); // 2000 + (1000-480)/2
  assert.match(features, /top=210/); // 100 + (900-680)/2
});

test("popupFeatures: falls back to screenX/screenY when screenLeft is absent", () => {
  const features = popupFeatures(400, 400, {
    screenX: 50,
    screenY: 60,
    outerWidth: 800,
    outerHeight: 800,
  });

  assert.match(features, /left=250/); // 50 + (800-400)/2
  assert.match(features, /top=260/); // 60 + (800-400)/2
});

test("popupFeatures: never positions the popup off the left/top edge", () => {
  // A browser window narrower than the requested popup would compute a
  // negative offset, which some platforms treat as "off-screen".
  const features = popupFeatures(1200, 1000, {
    screenLeft: 0,
    screenTop: 0,
    outerWidth: 400,
    outerHeight: 300,
  });

  assert.match(features, /left=0/);
  assert.match(features, /top=0/);
});

test("popupFeatures: tolerates the string dataset values it is actually given", () => {
  // el.dataset.* is always a string.
  const features = popupFeatures("500", "700", { screenLeft: 0, screenTop: 0 });

  assert.match(features, /width=500/);
  assert.match(features, /height=700/);
});

test("popupFeatures: garbage or missing sizes fall back to sane defaults", () => {
  for (const bad of [undefined, null, "", "abc", 0, -50]) {
    const features = popupFeatures(bad, bad, {});
    assert.match(features, /width=\d+/);
    assert.match(features, /height=\d+/);
    assert.doesNotMatch(features, /NaN|Infinity|width=-|height=-|left=-|top=-/);
  }
});

test("popupFeatures: an empty view object still yields a usable string", () => {
  const features = popupFeatures(480, 680, undefined);

  assert.match(features, /^width=480,height=680,left=\d+,top=\d+,/);
  assert.doesNotMatch(features, /NaN|undefined/);
});

test("sameOrigin: accepts same-origin links, absolute or relative", () => {
  const base = "https://app.example/settings";

  assert.equal(sameOrigin("/oauth/start", base), true);
  assert.equal(sameOrigin("https://app.example/oauth/start", base), true);
  assert.equal(sameOrigin("oauth/start", base), true);
});

test("sameOrigin: refuses another origin, scheme or port", () => {
  // The popup keeps window.opener, so a cross-origin target would hand that
  // reference away. The Elixir component enforces this too, but the bundle is
  // copied into hosts and the hook name is public.
  const base = "https://app.example/settings";

  assert.equal(sameOrigin("https://evil.example/start", base), false);
  assert.equal(sameOrigin("//evil.example/start", base), false);
  assert.equal(sameOrigin("http://app.example/start", base), false, "scheme differs");
  assert.equal(sameOrigin("https://app.example:8443/start", base), false, "port differs");
});

test("sameOrigin: an unparseable href is refused, not thrown on", () => {
  assert.equal(sameOrigin("http://[bad", "https://app.example/"), false);
  assert.equal(sameOrigin(undefined, "https://app.example/"), false);
  assert.equal(sameOrigin("/ok", "not-a-url"), false);
});
