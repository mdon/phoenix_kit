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

test("popupFeatures: a popup larger than the window sits at the window origin", () => {
  const features = popupFeatures(1200, 1000, {
    screenLeft: 0,
    screenTop: 0,
    outerWidth: 400,
    outerHeight: 300,
  });

  assert.match(features, /left=0/);
  assert.match(features, /top=0/);
});

test("popupFeatures: honours a monitor left of, or above, the primary one", () => {
  // Negative screen coordinates are legitimate on a multi-monitor desktop.
  // Clamping them to 0 threw the popup back onto the primary display.
  const features = popupFeatures(480, 680, {
    screenLeft: -1920,
    screenTop: -200,
    outerWidth: 1600,
    outerHeight: 1000,
  });

  assert.match(features, /left=-1360/); // -1920 + (1600-480)/2
  assert.match(features, /top=-40/); // -200 + (1000-680)/2
});

test("popupFeatures: tolerates the string dataset values it is actually given", () => {
  // el.dataset.* is always a string.
  const features = popupFeatures("500", "700", { screenLeft: 0, screenTop: 0 });

  assert.match(features, /width=500/);
  assert.match(features, /height=700/);
});

test("popupFeatures: garbage or missing sizes fall back to sane defaults", () => {
  for (const bad of [undefined, null, "", "abc"]) {
    const features = popupFeatures(bad, bad, {});
    // Assert the actual defaults — /width=\d+/ was satisfied by width=1.
    assert.match(features, /width=480/, `for ${String(bad)}`);
    assert.match(features, /height=680/, `for ${String(bad)}`);
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

// ---------------------------------------------------------------------------
// The hook itself. The blocked-popup branch IS the bug this component was
// rewritten to fix — the old inline onclick cancelled navigation even when the
// popup never opened, leaving a dead button — and it had no coverage at all.
// ---------------------------------------------------------------------------

const hook = window.PhoenixKitHooks.PopupLink;

function mountHook({ open, href = "https://app.example/oauth/start" }) {
  const listeners = {};
  const el = {
    href,
    dataset: { windowName: "test", windowWidth: "480", windowHeight: "680" },
    addEventListener(type, fn) {
      listeners[type] = fn;
    },
    removeEventListener(type) {
      delete listeners[type];
    },
  };

  window.location = { href: "https://app.example/settings" };
  window.open = open;

  const ctx = Object.create(hook);
  ctx.el = el;
  ctx.mounted();

  return {
    el,
    listeners,
    click(overrides = {}) {
      let prevented = false;
      const event = {
        button: 0,
        preventDefault() {
          prevented = true;
        },
        ...overrides,
      };
      listeners.click(event);
      return prevented;
    },
    destroy() {
      ctx.destroyed();
      return listeners;
    },
  };
}

test("hook: a successful popup cancels the navigation", () => {
  let focused = false;
  const h = mountHook({ open: () => ({ closed: false, focus: () => (focused = true) }) });

  assert.equal(h.click(), true, "should preventDefault when the popup opened");
  assert.equal(focused, true, "the popup should be focused");
});

test("hook: a BLOCKED popup falls through to normal navigation", () => {
  // The whole point of the rewrite. Cancelling here left a dead button.
  assert.equal(mountHook({ open: () => null }).click(), false, "null");
  assert.equal(mountHook({ open: () => ({ closed: true }) }).click(), false, "already closed");
  assert.equal(mountHook({ open: () => ({}) }).click(), false, "closed undefined");
});

test("hook: window.open throwing falls through instead of breaking the click", () => {
  const h = mountHook({
    open: () => {
      throw new Error("blocked");
    },
  });

  assert.equal(h.click(), false);
});

test("hook: a popup that cannot be focused still counts as opened", () => {
  const h = mountHook({
    open: () => ({
      closed: false,
      focus() {
        throw new Error("denied");
      },
    }),
  });

  assert.equal(h.click(), true, "focus is best-effort and must not break the flow");
});

test("hook: a cross-origin href is never popped up", () => {
  let opened = false;
  const h = mountHook({
    href: "https://evil.example/start",
    open: () => {
      opened = true;
      return { closed: false, focus() {} };
    },
  });

  assert.equal(h.click(), false);
  assert.equal(opened, false, "window.open must not even be called");
});

test("hook: modifier clicks are left to the browser", () => {
  let opened = false;
  const h = mountHook({
    open: () => {
      opened = true;
      return { closed: false, focus() {} };
    },
  });

  assert.equal(h.click({ metaKey: true }), false);
  assert.equal(opened, false);
});

test("hook: destroyed unbinds the listener", () => {
  const h = mountHook({ open: () => ({ closed: false, focus() {} }) });

  assert.equal(typeof h.listeners.click, "function");
  h.destroy();
  assert.equal(h.listeners.click, undefined);
});
