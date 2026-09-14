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

function fakeEl(armed, opts) {
  const BASE = "w-full h-full object-contain";
  const img = {
    attrs: { "data-base-class": BASE },
    className: "",
    getAttribute: (k) => img.attrs[k] ?? null,
    setAttribute: (k, v) => (img.attrs[k] = v),
    removeAttribute: (k) => delete img.attrs[k],
    dataset: { baseClass: BASE },
  };
  const sidebar = { style: {} };
  return {
    img,
    sidebar,
    style: {},
    dataset: {
      armed: String(armed),
      sidebarOpen: String((opts && opts.sidebarOpen) ?? true),
    },
    querySelector: (sel) => (sel.includes("sidebar") ? sidebar : img),
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

// A stand-in for the real viewer's modal, whose image may or may not have
// decoded by the time the hook mounts.
function realViewer(complete, opts) {
  const img = { complete, handlers: {},
    addEventListener: (n, fn) => (img.handlers[n] = fn),
    removeEventListener: (n) => delete img.handlers[n] };
  const root = {
    style: {},
    querySelector: (sel) =>
      sel.includes("data-viewer-sidebar")
        ? ((opts && opts.sidebar) ?? true) ? {} : null
        : img,
  };
  return { detail: { el: root }, img, root };
}

test("holds on until the real image has actually painted", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/thumbnail_annotated/x.jpg"));

  // Mounted is not painted. The card shows `thumbnail_annotated` where the
  // viewer loads `small`, so the real image is usually a different URL and
  // not in cache — hiding on mount swaps the blurred picture for an empty
  // box and then paints, which is the flash this hook exists to remove.
  const viewer = realViewer(false);
  listeners.window["pk:viewer-open"].fn(viewer);
  assert.strictEqual(el.style.display, "",
    "still up: the real image has not decoded yet");

  viewer.img.handlers.load();
  assert.strictEqual(el.style.display, "none", "and out of the way once it has");
});

test("hands over at once when the real image is already decoded", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg"));

  listeners.window["pk:viewer-open"].fn(realViewer(true));
  assert.strictEqual(el.style.display, "none",
    "a warm cache should not be made to wait a frame");
});

test("a broken image does not strand the stand-in", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg"));

  const viewer = realViewer(false);
  listeners.window["pk:viewer-open"].fn(viewer);
  viewer.img.handlers.error();
  assert.strictEqual(el.style.display, "none",
    "it must not sit there pretending the picture loaded");
});

test("exactly one dark layer at every moment of the hand-off", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg"));

  // Both the stand-in and the real viewer are .modal-open, and .modal-open
  // paints its own 40% black — stacked, they compound to ~64%, a visible
  // darker pulse for as long as both are up. So the real modal's black is
  // suppressed while the stand-in's is showing…
  const viewer = realViewer(false);
  listeners.window["pk:viewer-open"].fn(viewer);
  assert.strictEqual(viewer.root.style.backgroundColor, "transparent",
    "the real modal must not add its black on top of the stand-in's");
  assert.strictEqual(viewer.root.style.transition, "none",
    "…and with the transition off, or restoring it would fade over 0.3s");

  // …and restored in the very call that hides the stand-in, so the swap is
  // within one frame and the darkness never doubles or dips.
  viewer.img.handlers.load();
  assert.strictEqual(el.style.display, "none");
  assert.strictEqual(viewer.root.style.backgroundColor, "",
    "the real modal's own black takes over the same frame");
});

test("a viewer that opened without the stand-in keeps its own backdrop", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  // No click preceded this open (select-mode, keyboard nav, a card with no
  // image) — the real modal's black is the ONLY dark layer, and
  // suppressing it would flash the page bright instead of dark.
  const viewer = realViewer(false);
  listeners.window["pk:viewer-open"].fn(viewer);
  assert.notStrictEqual(viewer.root.style.backgroundColor, "transparent",
    "nothing to hand over, so nothing to suppress");
});

test("the stand-in reserves the sidebar's ground when the pref says open", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true, { sidebarOpen: true });
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg"));

  // The info sidebar is open by default. A stand-in that paints the image
  // over the full popup shrinks it a beat later when the sidebar mounts —
  // the very flash it exists to remove, in layout form.
  assert.strictEqual(el.sidebar.style.display, "",
    "the empty pane holds the sidebar's ground so the image column starts " +
    "at its final size");

  const closed = fakeEl(true, { sidebarOpen: false });
  hook.mounted.call({ el: closed });
  listeners.document.click.fn(cardClick("/x.jpg"));
  assert.strictEqual(closed.sidebar.style.display, "none",
    "…and stays out of the way when the pref says collapsed");
});

test("what the last viewer actually showed beats the server's pref", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true, { sidebarOpen: true });
  hook.mounted.call({ el });

  // The pref is read once at mount and never refreshed, so after the user
  // collapses the sidebar inside the viewer it is stale. The layout of the
  // viewer that just closed is the freshest evidence there is.
  listeners.document.click.fn(cardClick("/a.jpg"));
  listeners.window["pk:viewer-open"].fn(realViewer(true, { sidebar: false }));

  listeners.document.click.fn(cardClick("/b.jpg"));
  assert.strictEqual(el.sidebar.style.display, "none",
    "the last open had no sidebar, so this stand-in predicts none — " +
    "whatever the mount-time pref said");
});

test("the viewer hands over its element, or there is nothing to wait on", () => {
  const keydown = src.slice(src.indexOf("window.PhoenixKitHooks.ViewerKeydown = {"),
                            src.indexOf("destroyed()", src.indexOf("window.PhoenixKitHooks.ViewerKeydown = {")));
  assert.ok(/detail:\s*\{\s*el:/.test(keydown),
    "the stand-in finds the image through the element the event carries");
});

test("the real viewer is what announces itself", () => {
  // Nothing else can: the modal is a different LiveComponent, and this hook
  // holds no reference to it.
  const keydown = src.slice(src.indexOf("window.PhoenixKitHooks.ViewerKeydown = {"),
                            src.indexOf("destroyed()", src.indexOf("window.PhoenixKitHooks.ViewerKeydown = {")));
  assert.ok(/new CustomEvent\("pk:viewer-open"/.test(keydown),
    "the viewer's own hook fires the event the stand-in waits for");
});

test("fills the box the real image is about to occupy", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg", "object-cover"));

  // `max-w-full` constrains but never scales UP, so a 300px thumbnail sat
  // at 300px in the middle of a 95vw box — which reads as the viewer having
  // opened wrong, not as something still loading.
  assert.ok(/\bw-full\b/.test(el.img.className) && /\bh-full\b/.test(el.img.className),
    "the stand-in occupies the box, so the hand-off is a sharpening not a jump");
  assert.ok(!/max-w-full/.test(el.img.className), "not merely constrained by it");
});

test("the upscale is blurred, and by a style the className rewrite cannot drop", () => {
  const heex = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components",
              "media_browser.html.heex"), "utf8"
  );
  const block = heex.slice(heex.indexOf("-instant-viewer"), heex.indexOf("Read-only modal viewer"));

  // Blurred on purpose: filling the box from a 300-400px card variant is a
  // ~4x upscale, which reads as "developing" when soft and as broken when
  // sharp and pixelated.
  assert.ok(/style="filter: blur\(/.test(block), "the stand-in is softened");
  // Inline rather than `blur-sm`, for two reasons that both bite silently:
  // a host whose Tailwind build does not reach into this package would drop
  // the utility, and the hook overwrites className wholesale to carry the
  // card's rotation across.
  // Checked against the class attributes, not the block, so the comment
  // explaining the choice does not satisfy the assertion about it.
  const classes = (block.match(/(?:data-base-)?class="[^"]*"/g) || []).join(" ");
  assert.ok(!/blur/.test(classes),
    "a utility class here depends on the host's Tailwind scanning a library " +
    "template, and would not survive the hook's className rewrite either");
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
  assert.ok(/data-base-class="w-full h-full/.test(block),
    "and fills the box rather than sitting small in the middle of it");
  assert.ok(block.includes('data-pane="sidebar"') && block.includes("flex-[7]"),
    "it mirrors the viewer's image/sidebar split, not one centred box");
  assert.ok(block.includes("data-sidebar-open="),
    "and is seeded with the user's sidebar pref for the first open");

  // The other half of the layout prediction: the real viewer marks its
  // sidebar so the hook can remember what this session actually showed.
  const viewerHeex = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components",
              "media_canvas_viewer.html.heex"), "utf8"
  );
  assert.ok(viewerHeex.includes("data-viewer-sidebar"),
    "the real sidebar carries the marker the hook's memory reads");
});
