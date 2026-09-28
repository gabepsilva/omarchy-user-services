// Tests for Model.js, the pure helpers behind Panel.qml.
// Run with: node --test test/

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

// Model.js is a QML JavaScript library: its first line is `.pragma library`,
// which is not JavaScript. Drop it and evaluate the rest in a sandbox.
const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const M = vm.createContext({})
vm.runInContext(source, M)

// vm objects come from another realm, so compare through JSON.
const same = (actual, expected) => assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected)

const unit = (name, active = "active", sub = "running", load = "loaded", description = "") =>
  ({ unit: name, load, active, sub, description })

test("parseUnits reads systemctl JSON and rejects junk", () => {
  const units = M.parseUnits(JSON.stringify([
    { unit: "a.service", load: "loaded", active: "active", sub: "running", description: "A" },
    { unit: "", load: "loaded" },
    {}
  ]))
  same(units, [unit("a.service", "active", "running", "loaded", "A")])
  assert.equal(M.parseUnits("not json"), null)
  assert.equal(M.parseUnits("{}"), null)
  same(M.parseUnits(""), [])
})

test("display names unescape systemd escapes and drop .service", () => {
  assert.equal(M.displayName("app-claude\\x2ddesktop@autostart.service"), "app-claude-desktop@autostart")
  assert.equal(M.displayName("kokoro.service"), "kokoro")
})

test("running, failed and transitioning states", () => {
  assert.equal(M.isRunning(unit("a", "active")), true)
  assert.equal(M.isRunning(unit("a", "activating")), true)
  assert.equal(M.isRunning(unit("a", "reloading")), true)
  assert.equal(M.isRunning(unit("a", "inactive")), false)
  assert.equal(M.isRunning(null), false)
  assert.equal(M.isFailed(unit("a", "failed")), true)
  assert.equal(M.isTransitioning(unit("a", "deactivating")), true)
  assert.equal(M.isTransitioning(unit("a", "active")), false)
})

test("filterUnits hides noise, filters, and sorts failed, running, stopped", () => {
  const units = [
    unit("zeta.service", "inactive", "dead"),
    unit("alpha.service"),
    unit("broken.service", "failed", "failed"),
    unit("gone.service", "inactive", "dead", "not-found"),
    unit("dbus-:1.2-x@0.service"),
    unit("app-foo@autostart.service"),
    unit("beta.service", "active", "running", "loaded", "Pipe thing")
  ]
  const names = (list) => Array.from(list, (u) => u.unit)

  same(names(M.filterUnits(units, { showInactive: true, hideAutostart: true })),
    ["broken.service", "alpha.service", "beta.service", "zeta.service"])
  same(names(M.filterUnits(units, { showInactive: false, hideAutostart: true })),
    ["broken.service", "alpha.service", "beta.service"])
  same(names(M.filterUnits(units, { showInactive: true, hideAutostart: false })),
    ["broken.service", "alpha.service", "app-foo@autostart.service", "beta.service", "zeta.service"])
  same(names(M.filterUnits(units, { showInactive: true, query: "PIPE" })), ["beta.service"])
  same(names(M.filterUnits(units, { showInactive: true, query: "  alp " })), ["alpha.service"])
})

test("counts", () => {
  const units = [unit("a"), unit("b", "failed", "failed"), unit("c", "inactive", "dead")]
  assert.equal(M.countRunning(units), 1)
  assert.equal(M.countFailed(units), 1)
  assert.equal(M.countRunning(null), 0)
})

test("elide collapses whitespace and truncates", () => {
  assert.equal(M.elide("  a \n  b  "), "a b")
  assert.equal(M.elide("abcdef", 4), "abc…")
})

test("favorites: normalize, toggle, compare", () => {
  same(M.normalizeFavorites(["a", "a", null, "", "b"]), ["a", "b"])
  same(M.normalizeFavorites("nope"), [])
  same(M.toggleFavorite(["a", "b"], "c"), ["a", "b", "c"])
  same(M.toggleFavorite(["a", "b"], "a"), ["b"])
  assert.equal(M.sameList(["a", "b"], ["a", "b"]), true)
  assert.equal(M.sameList(["a", "b"], ["b", "a"]), false)
  assert.equal(M.sameList(["a"], ["a", "b"]), false)
})

test("unitMap and favoriteUnit placeholder for missing units", () => {
  const map = M.unitMap([unit("a.service")])
  assert.equal(map["a.service"].unit, "a.service")
  same(M.favoriteUnit(map, "gone.service"),
    { unit: "gone.service", load: "not-found", active: "inactive", sub: "not loaded", description: "" })
})

test("descriptionOf hides descriptions that just repeat the unit name", () => {
  assert.equal(M.descriptionOf(unit("a.service", "active", "running", "loaded", "Thing")), "Thing")
  assert.equal(M.descriptionOf(unit("a.service", "active", "running", "loaded", "a.service")), "")
  assert.equal(M.descriptionOf(null), "")
})

test("start-at-login states", () => {
  assert.equal(M.canToggleEnable("enabled"), true)
  assert.equal(M.canToggleEnable("disabled"), true)
  assert.equal(M.canToggleEnable("static"), false)
  assert.equal(M.isEnabledState("enabled-runtime"), true)
  assert.equal(M.isEnabledState("disabled"), false)
  assert.equal(M.enableStateHint(""), "Checking…")
  assert.equal(M.enableStateHint("weird"), "weird")
})

test("parseShow splits KEY=value blocks", () => {
  same(M.parseShow("Id=a.service\nMainPID=12\n\nId=b.service\nMainPID=0\n"),
    [{ Id: "a.service", MainPID: "12" }, { Id: "b.service", MainPID: "0" }])
  same(M.parseShow("ExecStart={ path=/bin/x ; argv[]=/bin/x a=b }"),
    [{ ExecStart: "{ path=/bin/x ; argv[]=/bin/x a=b }" }])
})

test("numberOrNull treats systemd's unset values as null", () => {
  assert.equal(M.numberOrNull("42"), 42)
  assert.equal(M.numberOrNull("[not set]"), null)
  assert.equal(M.numberOrNull("18446744073709551615"), null)
  assert.equal(M.numberOrNull("infinity"), null)
  assert.equal(M.numberOrNull(""), null)
})

test("memoryLines parses unit=bytes output", () => {
  same(M.memoryLines("a.service=1024\nb@x=y.service=2048\nbad\nzero.service=0\n"),
    { "a.service": 1024, "b@x=y.service": 2048 })
})

test("formatting", () => {
  assert.equal(M.formatBytes(900), "900B")
  assert.equal(M.formatBytes(532480), "520K")
  assert.equal(M.formatBytes(14626816), "14M")
  assert.equal(M.formatBytes(2630627328), "2.4G")
  assert.equal(M.formatBytes(null), "—")
  assert.equal(M.formatDuration(59), "59s")
  assert.equal(M.formatDuration(3725), "1h 2m")
  assert.equal(M.formatDuration(200000), "2d 7h")
  assert.equal(M.formatDuration(-1), "—")
  assert.equal(M.formatCpu(22326973000), "22s")
  assert.equal(M.formatCpu(null), "—")
  assert.equal(M.unixTimestamp("@1790576006"), 1790576006)
  assert.equal(M.unixTimestamp("n/a"), null)
})

test("memoryTooltip lines up RAM and VRAM", () => {
  assert.equal(M.memoryTooltip(128974848, 1181116006), "RAM:  123M\nVRAM: 1.1G")
  assert.equal(M.memoryTooltip(128974848, undefined), "RAM:  123M")
})

test("action status wording", () => {
  assert.equal(M.busyLabel("restart"), "Restarting…")
  assert.equal(M.busyLabel("other"), "Working…")
  assert.equal(M.doneLabel("stop"), "Stopped")
  assert.equal(M.doneLabel("other"), "Done")
})

test("withUnitValue sets, removes, and keeps identity when unchanged", () => {
  const map = M.memoryLines("a.service=1\nb.service=2\n")
  assert.equal(M.withUnitValue(map, "a.service", 1), map)
  assert.equal(M.withUnitValue(map, "gone.service", undefined), map)
  same(M.withUnitValue(map, "a.service", 5), { "a.service": 5, "b.service": 2 })
  same(M.withUnitValue(map, "a.service", undefined), { "b.service": 2 })
  same(map, { "a.service": 1, "b.service": 2 })
})
