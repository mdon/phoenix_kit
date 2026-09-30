"use strict";

// Unit tests for the PkChartCrosshair hook in priv/static/assets/phoenix_kit.js
// — the client half of `line_chart hover={:crosshair}`: which entry the
// pointer is over, which side the readout goes, and what the readout says.
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

const pk = require("../../priv/static/assets/phoenix_kit.js");
const { crosshairPick, crosshairTipSide } = pk;
const Hook = global.window.PhoenixKitHooks.PkChartCrosshair;

// Three step slots over the left 75% of the chart; the last runs to the edge.
const STEP = [
  [25, 50, 25, 80, "06:00", "€0.10", "1st cheapest of 3", []],
  [50, 75, 50, 20, "12:00", "€0.30", "3rd cheapest of 3", [["Boiler", "#f00"]]],
  [75, 100, 75, 50, "18:00", "€0.20", "2nd cheapest of 3", []],
];

test("picks the band under the pointer", () => {
  assert.equal(crosshairPick(STEP, 30), 0);
  assert.equal(crosshairPick(STEP, 50), 1, "a band is left-closed");
  assert.equal(crosshairPick(STEP, 99.9), 2);
});

test("no datum left of a step series' first point", () => {
  assert.equal(crosshairPick(STEP, 10), -1);
});

test("the right edge belongs to the last band, nothing beyond it", () => {
  assert.equal(crosshairPick(STEP, 100), 2);
  assert.equal(crosshairPick(STEP, 100.5), -1);
  assert.equal(crosshairPick([], 50), -1);
  assert.equal(crosshairPick(null, 50), -1);
});

test("the readout flips to the left past the middle", () => {
  assert.equal(crosshairTipSide(20), "right");
  assert.equal(crosshairTipSide(80), "left");
});

function fakeEl() {
  const el = {
    style: {},
    dataset: {},
    hidden: true,
    children: [],
    className: "",
    textContent: "",
    listeners: {},
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    replaceChildren() {
      this.children = [];
    },
    addEventListener(name, fn) {
      this.listeners[name] = fn;
    },
    removeEventListener(name) {
      delete this.listeners[name];
    },
  };
  return el;
}

function mount(points) {
  const line = fakeEl();
  const dot = fakeEl();
  const tip = fakeEl();
  const host = fakeEl();
  host.getBoundingClientRect = () => ({ left: 100, width: 400 });
  const el = fakeEl();
  el.dataset.points = JSON.stringify(points);
  el.parentElement = host;
  el.querySelector = (sel) =>
    ({ "[data-crosshair-line]": line, "[data-crosshair-dot]": dot, "[data-crosshair-tip]": tip })[sel];

  global.document.createElement = () => fakeEl();
  global.document.createTextNode = (text) => ({ textContent: text });

  const hook = Object.assign(Object.create(Hook), { el });
  hook.mounted();
  return { hook, host, line, dot, tip };
}

test("a pointer over a slot places the crosshair and writes the readout", () => {
  const { host, line, dot, tip } = mount(STEP);
  // 100 + 0.6 * 400 = 340 -> 60% -> the second slot
  host.listeners.pointermove({ clientX: 340 });

  assert.equal(line.hidden, false);
  assert.equal(line.style.left, "50%");
  assert.equal(dot.style.top, "20%");
  assert.deepEqual(
    tip.children.map((c) => c.textContent || c.children.map((n) => n.textContent).join("")),
    ["12:00", "€0.30", "3rd cheapest of 3", "Boiler"],
  );
  assert.equal(tip.children[3].children[0].style.background, "#f00");
  assert.match(tip.style.transform, /translateX\(8px\)/);
});

test("leaving the chart, or a pointer where no datum stands, hides it", () => {
  const { host, line, tip } = mount(STEP);
  host.listeners.pointermove({ clientX: 340 });
  host.listeners.pointerleave();
  assert.equal(line.hidden, true);
  assert.equal(tip.hidden, true);

  host.listeners.pointermove({ clientX: 340 });
  host.listeners.pointermove({ clientX: 110 });
  assert.equal(tip.hidden, true);
});

test("new data drops the cached payload", () => {
  const { hook, host, tip } = mount(STEP);
  hook.el.dataset.points = JSON.stringify([[0, 100, 50, 50, null, "7", null, []]]);
  hook.updated();
  host.listeners.pointermove({ clientX: 120 });
  assert.deepEqual(tip.children.map((c) => c.textContent), ["7"]);
});

test("the listeners come off on destroy", () => {
  const { hook, host } = mount(STEP);
  hook.destroyed();
  assert.deepEqual(Object.keys(host.listeners), []);
});
