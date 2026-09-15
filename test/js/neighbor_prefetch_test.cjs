// Pins the viewer's neighbour warming.
//
// An arrow press remounts the viewer on the next file, and that file's
// small + large variants used to start downloading only then — the
// download WAS the wait between pressing → and seeing the picture. The
// modal now carries the neighbours' variant URLs, and ViewerKeydown
// warms them on mount, deduped page-wide across remounts.
//
//   node --test test/js/neighbor_prefetch_test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

function loadKeydown() {
  const start = src.indexOf("  window.PhoenixKitHooks.ViewerKeydown = {");
  assert.notStrictEqual(start, -1, "could not find ViewerKeydown");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  const fetched = [];
  function FakeImage() {}
  Object.defineProperty(FakeImage.prototype, "src", {
    set(v) { fetched.push(v); }, get() { return null; },
  });
  const win = {
    addEventListener: () => {}, removeEventListener: () => {},
    dispatchEvent: () => {},
  };
  const doc = { addEventListener: () => {}, removeEventListener: () => {} };
  const fn = new Function("window", "document", "Image", "CustomEvent",
    "window.PhoenixKitHooks = window.PhoenixKitHooks || {};" +
    src.slice(start, end) + "; return window.PhoenixKitHooks.ViewerKeydown;");
  const hook = fn(win, doc, FakeImage, function C(n, o) { this.name = n; this.detail = o && o.detail; });
  return { hook, fetched, win };
}

test("mounting the viewer warms both neighbours' variants", () => {
  const { hook, fetched } = loadKeydown();
  hook.mounted.call({ el: {
    dataset: { neighborPrefetch: "/f/p/small/aa /f/p/large/ab /f/n/small/ba /f/n/large/bb" },
    querySelector: () => null,
  }, pushEventTo: () => {} });
  assert.deepStrictEqual(fetched,
    ["/f/p/small/aa", "/f/p/large/ab", "/f/n/small/ba", "/f/n/large/bb"],
    "prev and next, small and large — everything an arrow press will ask for");
});

test("each URL warms once per page, across remounts", () => {
  const { hook, fetched, win } = loadKeydown();
  const el = { dataset: { neighborPrefetch: "/f/x/small/aa" }, querySelector: () => null };
  hook.mounted.call({ el, pushEventTo: () => {} });
  // the next file's mount lists the same URL as ITS neighbour
  hook.mounted.call({ el, pushEventTo: () => {} });
  assert.deepStrictEqual(fetched, ["/f/x/small/aa"],
    "the shared page-wide map survives the remount an arrow causes");
});

test("no neighbours, no fetches, no crash", () => {
  const { hook, fetched } = loadKeydown();
  assert.doesNotThrow(() => hook.mounted.call({
    el: { dataset: {}, querySelector: () => null }, pushEventTo: () => {} }));
  assert.deepStrictEqual(fetched, []);
});

test("the modal advertises its neighbours", () => {
  const heex = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components",
              "media_browser.html.heex"), "utf8");
  assert.ok(heex.includes("data-neighbor-prefetch={neighbor_prefetch}"),
    "ViewerKeydown reads the URLs off its own element");
  assert.ok(/Enum\.at\(siblings, viewer_idx - 1\)/.test(heex) &&
            /Enum\.at\(siblings, viewer_idx \+ 1\)/.test(heex),
    "…built from the same siblings list the arrows step through");
  assert.ok(heex.includes(`&1.file_type == "image"`),
    "videos and pdfs are not image-warmable and are skipped");
});
