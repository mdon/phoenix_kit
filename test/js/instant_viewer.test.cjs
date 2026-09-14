// Pins the instant stand-in for the media viewer.
//
// Opening the viewer is a server round trip: the modal does not exist in
// the DOM until LiveView sends it back. The server's part of that is ~2ms,
// so the wait is the network — and the thing being opened is a picture the
// browser ALREADY HAS, because the grid painted it.
//
// So the stand-in shows that bitmap full-size on the click and gets out of
// the way when the real viewer mounts. It talks to no one and changes what
// gets opened not at all.
//
//   node --test test/js/instant_viewer.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

// Lift the hook out of the bundle and run it against a stand-in DOM.
function loadHook() {
  const start = src.indexOf("  window.PhoenixKitHooks.InstantViewer = {");
  assert.notStrictEqual(start, -1, "could not find the InstantViewer hook");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  const listeners = { document: {}, window: {} };

  const doc = {
    addEventListener: (n, fn, capture) => (listeners.document[n] = { fn, capture }),
    removeEventListener: () => {},
  };
  const win = {
    addEventListener: (n, fn) => (listeners.window[n] = { fn }),
    removeEventListener: () => {},
  };
  const hooks = {};
  const fn = new Function(
    "window", "document", "setTimeout", "clearTimeout",
    "window.PhoenixKitHooks = window.PhoenixKitHooks || {};" +
      src.slice(start, end) + "; return window.PhoenixKitHooks.InstantViewer;"
  );
  const timers = [];
  const hook = fn(
    Object.assign(win, { PhoenixKitHooks: hooks }),
    doc,
    (cb, ms) => { timers.push({ cb, ms }); return timers.length; },
    () => {}
  );
  return { hook, listeners, timers };
}

function fakeEl(armed) {
  const img = {
    attrs: { "data-base-class": "max-w-full max-h-full object-contain" },
    className: "",
    getAttribute: (k) => img.attrs[k] ?? null,
    setAttribute: (k, v) => (img.attrs[k] = v),
    removeAttribute: (k) => delete img.attrs[k],
    dataset: { baseClass: "max-w-full max-h-full object-contain" },
  };
  return {
    img,
    style: {},
    dataset: { armed: String(armed) },
    querySelector: () => img,
  };
}

function cardClick(srcUrl, cls) {
  const cardImg = {
    className: cls || "",
    getAttribute: (k) => (k === "src" ? srcUrl : null),
  };
  const card = { querySelector: () => cardImg };
  return { target: { closest: (sel) => (sel.includes("click_file") ? card : null) } };
}

test("shows the card's own bitmap on the click", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  assert.strictEqual(el.style.display, "none", "hidden until something is clicked");

  listeners.document.click.fn(cardClick("/uploads/small/cat.jpg"));
  assert.strictEqual(el.style.display, "", "shown on the click, not on the reply");
  assert.strictEqual(el.img.attrs.src, "/uploads/small/cat.jpg",
    "…with the very bitmap the grid already has, so there is nothing to fetch");
});

test("listens in the capture phase, ahead of the event it is racing", () => {
  const { hook, listeners } = loadHook();
  hook.mounted.call({ el: fakeEl(true) });
  assert.strictEqual(listeners.document.click.capture, true,
    "a listener that waited its turn would race the thing it exists to hide");
});

test("carries the card's rotation, so a sideways photo does not flip twice", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  listeners.document.click.fn(cardClick("/x.jpg", "w-full object-cover rotate-90"));
  assert.ok(/rotate-90/.test(el.img.className), "the rotation comes across");
  assert.ok(/object-contain/.test(el.img.className),
    "…on top of contain, not the card's cover — the viewer fits the whole picture");
});

test("stays out of select mode, where the same click is a checkbox", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(false);
  hook.mounted.call({ el });

  listeners.document.click.fn(cardClick("/x.jpg"));
  assert.strictEqual(el.style.display, "none", "nothing is being opened, so nothing is shown");
});

test("ignores clicks that are not on a file card", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  listeners.document.click.fn({ target: { closest: () => null } });
  assert.strictEqual(el.style.display, "none");
});

test("a card with no image is left alone", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  listeners.document.click.fn(cardClick(null));
  assert.strictEqual(el.style.display, "none", "nothing to stand in with");
});

test("clears itself the moment the real viewer mounts", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  listeners.document.click.fn(cardClick("/x.jpg"));
  assert.strictEqual(el.style.display, "");

  listeners.window["pk:viewer-open"].fn();
  assert.strictEqual(el.style.display, "none", "out of the way as soon as the real one is up");
  assert.ok(!("src" in el.img.attrs),
    "…and holding no bitmap, so the next open cannot flash the last one");
});

test("gives up on its own if no viewer ever arrives", () => {
  const { hook, listeners, timers } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  listeners.document.click.fn(cardClick("/x.jpg"));
  assert.strictEqual(timers.length, 1, "a click arms a fallback");
  assert.ok(timers[0].ms >= 1000, "…long enough not to cut a slow open short");

  timers[0].cb();
  assert.strictEqual(el.style.display, "none",
    "a stale uuid, a server error or a dropped connection must not leave a " +
    "picture stuck over the page");
});

test("the real viewer is what announces itself", () => {
  // Nothing else can: the modal is a different LiveComponent, and this hook
  // holds no reference to it.
  const keydown = src.slice(src.indexOf("window.PhoenixKitHooks.ViewerKeydown = {"),
                            src.indexOf("destroyed()", src.indexOf("window.PhoenixKitHooks.ViewerKeydown = {")));
  assert.ok(keydown.includes('new CustomEvent("pk:viewer-open")'),
    "the viewer's own hook fires the event the stand-in waits for");
});

test("the markup keeps LiveView's hands off it", () => {
  const heex = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components",
              "media_browser.html.heex"), "utf8"
  );
  const block = heex.slice(heex.indexOf("-instant-viewer"), heex.indexOf("Read-only modal viewer"));
  assert.ok(block.includes('phx-update="ignore"'),
    "the hook owns its contents — patching it mid-show is how it would flicker");
  assert.ok(block.includes("data-armed="),
    "and it is told when a click is actually going to open something");
  assert.ok(block.includes("object-contain"),
    "it fits the whole picture, like the viewer it stands in for");
});
