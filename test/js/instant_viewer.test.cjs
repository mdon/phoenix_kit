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
    querySelector: () => null,
  };
  const win = {
    addEventListener: (n, fn) => (listeners.window[n] = { fn }),
    removeEventListener: () => {},
  };
  const hooks = {};
  const fetched = [];
  function FakeImage() { fetched.push(this); }
  Object.defineProperty(FakeImage.prototype, "src", {
    set(v) { this._src = v; fetched.srcs = (fetched.srcs || []).concat(v); },
    get() { return this._src; },
  });
  const fn = new Function(
    "window", "document", "setTimeout", "clearTimeout", "Image",
    "window.PhoenixKitHooks = window.PhoenixKitHooks || {};" +
      src.slice(start, end) + "; return window.PhoenixKitHooks.InstantViewer;"
  );
  const timers = [];
  const hook = fn(
    Object.assign(win, { PhoenixKitHooks: hooks }),
    doc,
    (cb, ms) => { timers.push({ cb, ms }); return timers.length; },
    () => {},
    FakeImage
  );
  return { hook, listeners, timers, fetched, doc };
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
  const box = { style: {} };
  return {
    img,
    sidebar,
    box,
    style: {},
    dataset: {
      armed: String(armed),
      sidebarOpen: String((opts && opts.sidebarOpen) ?? true),
    },
    querySelector: (sel) =>
      sel.includes("sidebar") ? sidebar : sel.includes("modal-box") ? box : img,
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
  // darker pulse for as long as both are up. The stand-in sits on top, so
  // ITS black goes transparent in the same frame the real one's appears…
  const viewer = realViewer(false);
  listeners.window["pk:viewer-open"].fn(viewer);
  assert.strictEqual(el.style.backgroundColor, "transparent",
    "the stand-in must not add its black on top of the real modal's");
  assert.strictEqual(viewer.root.style.transition, "none",
    "…with the real one's transition off, or its black fades in over 0.3s " +
    "while the stand-in's vanishes instantly — a visible dip");

  // …and comes back when the stand-in resets, ready for the next open.
  viewer.img.handlers.load();
  assert.strictEqual(el.style.display, "none");
  assert.strictEqual(el.style.backgroundColor, "",
    "the stand-in's own black is restored for its next showing");
});

test("a viewer that opened without the stand-in is left entirely alone", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });

  // No click preceded this open (select-mode, keyboard nav, a card with no
  // image) — there is nothing to hand over and nothing to align.
  const viewer = realViewer(false);
  listeners.window["pk:viewer-open"].fn(viewer);
  assert.strictEqual(viewer.root.style.transition, undefined,
    "no styles are touched on a viewer the stand-in never covered");
});

test("the real sidebar shows through while the blur covers the image column", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg"));

  // The real modal mounts UNDER the stand-in, its sidebar content already
  // rendered — only its image is still in flight. The stand-in becomes a
  // window: box and skeleton pane transparent, so the real comments are
  // visible at once instead of popping in when the image arrives.
  const viewer = realViewer(false);
  listeners.window["pk:viewer-open"].fn(viewer);
  assert.strictEqual(el.box.style.backgroundColor, "transparent",
    "the stand-in's box must not hide the real sidebar behind it");
  assert.strictEqual(el.sidebar.style.visibility, "hidden",
    "the skeleton pane yields to the real content, keeping its ground " +
    "(visibility, not display) so the image column's width holds");

  viewer.img.handlers.load();
  assert.strictEqual(el.box.style.backgroundColor, "", "box reset for next open");
  assert.strictEqual(el.sidebar.style.visibility, "", "pane reset for next open");
});

test("the real layout corrects a mispredicted pane before the image lands", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true, { sidebarOpen: true });
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg"));
  assert.strictEqual(el.sidebar.style.display, "", "predicted open");

  // The viewer arrives with NO sidebar: the blurry column must widen now,
  // not keep a phantom 30% reserved until the image loads.
  listeners.window["pk:viewer-open"].fn(realViewer(false, { sidebar: false }));
  assert.strictEqual(el.sidebar.style.display, "none",
    "truth beats prediction the moment the real layout exists");
});

test("closing the viewer mid-hold takes the floating blur down with it", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.document.click.fn(cardClick("/x.jpg"));
  listeners.window["pk:viewer-open"].fn(realViewer(false));
  assert.strictEqual(el.style.display, "", "holding, waiting on the image");

  // Escape tears the modal out from under the overlay — without this, the
  // blurry column hangs over the grid until the 8s fallback.
  listeners.window["pk:viewer-closed"].fn();
  assert.strictEqual(el.style.display, "none");

  const keydown = src.slice(src.indexOf("window.PhoenixKitHooks.ViewerKeydown = {"));
  assert.ok(keydown.includes('new CustomEvent("pk:viewer-closed")'),
    "the viewer's own teardown is what announces the close");
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

function stepEl(withModal) {
  // a chevron press: target inside a [phx-click="step_viewer"] button
  const btn = {
    getAttribute: (k) => (k === "phx-value-dir" ? "next" : null),
  };
  return { target: { closest: (sel) => (sel.includes("step_viewer") ? btn : null) } };
}

test("a chevron press paints the neighbour instantly", () => {
  const { hook, listeners, doc } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  doc.querySelector = () => ({
    dataset: { stepNextSrc: "/f/n/small/aa", stepNextRot: "rotate-90" } });
  listeners.document.click.fn(stepEl());
  assert.strictEqual(el.style.display, "", "shown on the press, not on the reply");
  assert.strictEqual(el.img.attrs.src, "/f/n/small/aa",
    "…with the neighbour's warmed small — a cache hit");
  assert.ok(/rotate-90/.test(el.img.className), "the neighbour's rotation rides along");
});

test("a keyboard step announces itself and the stand-in answers", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.window["pk:viewer-step"].fn({ detail: { src: "/f/p/small/zz", rotation: "" } });
  assert.strictEqual(el.style.display, "");
  assert.strictEqual(el.img.attrs.src, "/f/p/small/zz");
});

test("the step's own teardown of the old viewer does not kill the bridge", () => {
  const { hook, listeners } = loadHook();
  const el = fakeEl(true);
  hook.mounted.call({ el });
  listeners.window["pk:viewer-step"].fn({ detail: { src: "/f/n/small/aa" } });
  // The OLD viewer's destroyed() fires pk:viewer-closed mid-step — the
  // stand-in exists precisely to bridge that gap and must survive it.
  listeners.window["pk:viewer-closed"].fn();
  assert.strictEqual(el.style.display, "", "still bridging");
  // The NEW viewer arrives; the normal hand-off takes over.
  listeners.window["pk:viewer-open"].fn(realViewer(true));
  assert.strictEqual(el.style.display, "none", "handed off");
  // …and a plain close afterwards hides as before.
  listeners.window["pk:viewer-step"].fn({ detail: { src: "/f/n/small/aa" } });
  listeners.window["pk:viewer-open"].fn(realViewer(true));
  listeners.window["pk:viewer-closed"].fn();
  assert.strictEqual(el.style.display, "none",
    "the stepping guard clears on hand-off — Esc still cleans up");
});

function hoverCard(small, large) {
  const card = { dataset: {} };
  if (small) card.dataset.prefetchSmall = small;
  if (large) card.dataset.prefetchLarge = large;
  return { target: { closest: (sel) => (sel.includes("click_file") ? card : null) } };
}

test("hovering a card starts the viewer's downloads before the click", () => {
  const { hook, listeners, fetched } = loadHook();
  hook.mounted.call({ el: fakeEl(true) });

  // The viewer opens on `small` and swaps up to `large` — a third of a
  // megabyte that used to start moving only after the click's round trip.
  // The pointer rests on a card for a beat before the button goes down;
  // that beat is download time now.
  listeners.document.pointerover.fn(hoverCard("/f/small/aa", "/f/large/bb"));
  assert.deepStrictEqual(fetched.srcs, ["/f/small/aa", "/f/large/bb"],
    "both variants the open will ask for are warming");

  // Once per page: the second hover of the same card fetches nothing —
  // the first fetch is either done (cached, immutable) or in flight.
  listeners.document.pointerover.fn(hoverCard("/f/small/aa", "/f/large/bb"));
  assert.strictEqual(fetched.srcs.length, 2, "no re-fetch on re-hover");

  assert.ok(listeners.document.pointerdown,
    "pointerdown is the backstop for touch, where there is no hover");
});

test("hovering anything that is not a file card fetches nothing", () => {
  const { hook, listeners, fetched } = loadHook();
  hook.mounted.call({ el: fakeEl(true) });
  listeners.document.pointerover.fn({ target: { closest: () => null } });
  listeners.document.pointerover.fn(hoverCard(null, null)); // video/pdf card
  assert.strictEqual(fetched.length, 0);
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
  assert.ok(/z-index:\s*1000/.test(block),
    "it floats ABOVE the real modal (.modal is 999): the hold only works " +
    "if the blur stays visible after the real viewer mounts underneath");
  assert.ok(/pointer-events:\s*none/.test(block),
    "and it must never block the real viewer's close button or sidebar");
  assert.ok(/transition:\s*none/.test(block),
    "its backdrop must appear and yield instantly, not on daisyUI's fade");
  assert.ok(block.includes("skeleton"),
    "the pane shows loading bars — an empty white block reads as 'no " +
    "comments', making the real content's arrival a pop");

  // Every click_file site carries the prefetch attributes, or hovering
  // that surface silently loses the head start.
  const sites = heex.split('phx-click="click_file"').length - 1;
  assert.ok(sites >= 2, "grid and list both open the viewer");
  assert.strictEqual(heex.split("data-prefetch-small=").length - 1, sites,
    "every click_file site advertises the small variant to warm");
  assert.strictEqual(heex.split("data-prefetch-large=").length - 1, sites,
    "…and the large one, which is what the open actually waits on");
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
