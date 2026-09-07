"use strict";

// Unit tests for `avatarCropLayout` / `clampAvatarCropFocal` in
// priv/static/assets/phoenix_kit.js — the geometry behind the AvatarCrop
// hook. The same math lives server-side in PhoenixKit.Users.AvatarCrop
// (layout/1), where its own tests pin the same cases: the preview must
// render exactly what the avatar component will later render.
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

const {
  avatarCropLayout,
  clampAvatarCropFocal,
} = require("../../priv/static/assets/phoenix_kit.js");

function near(actual, expected, message) {
  assert.ok(Math.abs(actual - expected) < 0.0001, `${message}: ${actual} vs ${expected}`);
}

test("zoom 1 centered is exactly the cover fit", () => {
  // A 3:2 landscape at zoom 1: height fills the frame, width overflows
  // symmetrically — what object-fit: cover with a centered position shows.
  const l = avatarCropLayout({ x: 0.5, y: 0.5, zoom: 1, ar: 1.5 });
  near(l.width, 150, "width");
  near(l.height, 100, "height");
  near(l.left, -25, "left");
  near(l.top, 0, "top");
});

test("portrait mirrors landscape", () => {
  const l = avatarCropLayout({ x: 0.5, y: 0.5, zoom: 1, ar: 0.5 });
  near(l.width, 100, "width");
  near(l.height, 200, "height");
  near(l.left, 0, "left");
  near(l.top, -50, "top");
});

test("zoom magnifies around the focal point", () => {
  const l = avatarCropLayout({ x: 0.5, y: 0.5, zoom: 2, ar: 1 });
  near(l.width, 200, "width");
  near(l.height, 200, "height");
  // The focal center stays at the frame center: 50 - 0.5*200 = -50.
  near(l.left, -50, "left");
  near(l.top, -50, "top");
});

test("the frame never sees past an edge", () => {
  // Focal point dragged all the way into a corner: the offsets clamp so the
  // image still covers the whole frame — no background peeking through.
  const l = avatarCropLayout({ x: 0, y: 0, zoom: 2, ar: 1 });
  near(l.left, 0, "left clamps at the leading edge");
  near(l.top, 0, "top clamps at the leading edge");

  const r = avatarCropLayout({ x: 1, y: 1, zoom: 2, ar: 1 });
  near(r.left, -100, "left clamps at the trailing edge");
  near(r.top, -100, "top clamps at the trailing edge");
});

test("focal clamping keeps the drag alive at the edges", () => {
  // A focal value that would render clamped snaps back into the reachable
  // range — otherwise dragging near an edge accumulates invisible distance
  // that must be dragged back before anything moves again.
  const c = clampAvatarCropFocal({ x: 0, y: 1, zoom: 2, ar: 1 });
  near(c.x, 0.25, "x snaps to the edge of the reachable range");
  near(c.y, 0.75, "y snaps to the edge of the reachable range");
});

test("an axis the image only just covers pins to center", () => {
  // Landscape at zoom 1: the height exactly fits the frame, so there is no
  // vertical freedom at all — y collapses to 0.5, x keeps its freedom.
  const c = clampAvatarCropFocal({ x: 0.9, y: 0.1, zoom: 1, ar: 2 });
  near(c.y, 0.5, "no vertical freedom");
  near(c.x, 0.75, "horizontal freedom is real but clamped");
});
