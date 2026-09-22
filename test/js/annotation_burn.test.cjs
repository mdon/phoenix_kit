// The burn hook must not ask the server to overwrite the editor's ladder.
//
// The viewer opens on `small` and climbs `medium` → `large` → `original`,
// then draws the live shapes on top. Burning those slots draws every
// annotation a second time the next time the picture is opened. List rows
// read `thumbnail`; grid cards read `burned` (card-sized); the viewer opens
// on `burned_large`.
//
//   node --test test/js/annotation_burn.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

function burnSection() {
  const start = src.indexOf("// AnnotationBurn —");
  const end = src.indexOf("// EtcherTooltipActions");
  assert.ok(start !== -1 && end > start, "could not find the AnnotationBurn section");
  return src.slice(start, end);
}

const section = burnSection();

// Whole slot names, not substrings: `burned_large` is a burn slot, not the
// ladder's `large`.
function defaultSlots() {
  const m = section.match(/dataset\.burnVariants \|\| "([^"]*)"/);
  assert.ok(m, "could not find the default burnVariants");
  return m[1].split(",");
}

test("the default slots are the burn slots, not the viewer ladder", () => {
  assert.deepStrictEqual(defaultSlots(), ["thumbnail", "burned", "burned_large"]);
  for (const rung of ["small", "medium", "large", "original"]) {
    assert.ok(!defaultSlots().includes(rung), `the default must not burn \`${rung}\``);
  }
});

test("a stored burn is announced by slot, never by a client-built URL", () => {
  // The viewer reads the stored instance itself; the hook must not hand it a
  // URL or size to trust.
  const push = section.slice(section.indexOf('"burn_stored"'));
  const payload = push.slice(0, push.indexOf("});"));
  assert.match(payload, /variant: made\.variant/);
  assert.doesNotMatch(payload, /url:|width:|height:/);
});

test("the burn is composed from this picture, and names the original it used", () => {
  assert.match(section, /body\.append\("source_version", sourceVersion\)/);
  assert.doesNotMatch(section, /document\.querySelector\('\[phx-hook="FrescoCanvas"\]'\)/);
  assert.doesNotMatch(section, /document\.querySelector\("\[data-sources\]"\)/);
});

test("a session-end during an in-flight burn keeps the plan taken while the overlay is still there", () => {
  assert.match(section, /if \(this\._running\) \{\s*this\._pending = pending;/);
  assert.match(section, /var next = self\._pending;\s*self\._pending = null;\s*if \(next\) self\._start\(next\);/);
});

// Review of #848: closing the viewer called burnIfChanged whatever the viewer
// was allowed to do, so a readonly MediaBrowser (can_annotate: false) still
// composed and POSTed a burn on the way out.
test("a viewer that cannot draw never burns", () => {
  const start = section.indexOf("burnIfChanged() {");
  assert.ok(start !== -1, "could not find burnIfChanged");
  const body = section.slice(start, section.indexOf("var now = this._signature();", start));
  assert.match(body, /dataset\.canAnnotate !== "true"\) return;/);
});

function sliceFn(name) {
  const start = src.indexOf("function " + name + "(");
  assert.ok(start !== -1, "could not find " + name);
  let i = src.indexOf("{", start);
  let depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error("unclosed " + name);
}

const affine = new Function(
  sliceFn("burnViewAffine") + "\n" +
  sliceFn("burnSvgMatrix") + "\n" +
  "return { burnViewAffine, burnSvgMatrix };"
)();

test("a quarter turn still produces an affine, and the matrix carries the rotation", () => {
  // 90°: image +X points down the screen. The old X-only delta was 0 and
  // burnCapturePlan returned null, so a rotated picture never burned.
  const rect = { left: 10, top: 20 };
  const p0 = { x: 50, y: 80 };
  const ax = affine.burnViewAffine(p0, { x: 50, y: 1080 }, { x: -950, y: 80 }, rect);
  assert.ok(ax, "a 90° view must still burn");
  assert.ok(Math.abs(ax.s - 1) < 1e-9);
  assert.ok(Math.abs(ax.cos) < 1e-9);
  assert.ok(Math.abs(ax.sin - 1) < 1e-9);
  assert.deepStrictEqual(
    affine.burnSvgMatrix(ax, 1, 0, 0).map((n) => Math.round(n * 1e6) / 1e6),
    [0, -1, 1, 0, -60, 40]
  );
});

test("an unrotated view keeps the axis-aligned matrix", () => {
  const ax = affine.burnViewAffine(
    { x: 0, y: 0 }, { x: 1000, y: 0 }, { x: 0, y: 1000 }, { left: 0, top: 0 }
  );
  assert.deepStrictEqual(
    affine.burnSvgMatrix(ax, 2, 0, 0).map((n) => n === 0 ? 0 : n),
    [2, 0, 0, 2, 0, 0]
  );
});

test("stepping to the next file burns while the overlay is still mounted", () => {
  assert.match(section, /phx-click="step_viewer"/);
  assert.match(section, /e\.key === "ArrowLeft" \|\| e\.key === "ArrowRight"/);
  assert.match(section, /if \(closing \|\| stepping\) self\.burnIfChanged\(\)/);
});
