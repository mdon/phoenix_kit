// The burn hook must not ask the server to overwrite the editor's ladder.
//
// The viewer opens on `small` and climbs `medium` → `large` → `original`,
// then draws the live shapes on top. Burning those slots draws every
// annotation a second time the next time the picture is opened. List rows
// read `thumbnail`; grid cards read `burned`.
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

test("the default slots are thumbnail and burned, not the viewer ladder", () => {
  assert.match(section, /dataset\.burnVariants \|\| "thumbnail,burned"/);
  assert.doesNotMatch(section, /thumbnail,small,medium,large/);
  for (const rung of ["small", "medium", "large", "original"]) {
    assert.doesNotMatch(
      section,
      new RegExp("burnVariants \\|\\| \"[^\"]*" + rung)
    );
  }
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
