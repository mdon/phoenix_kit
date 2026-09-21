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
