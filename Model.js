.pragma library

// Pure helpers for the user-services panel: parse `systemctl --user
// list-units -o json`, filter and sort it. Kept free of QML so it can be
// exercised from node.

function parseUnits(text) {
  var raw
  try {
    raw = JSON.parse(String(text || "[]"))
  } catch (e) {
    return null
  }
  if (!(raw instanceof Array)) return null

  var units = []
  for (var i = 0; i < raw.length; i++) {
    var u = raw[i] || {}
    var name = String(u.unit || "")
    if (name === "") continue
    units.push({
      unit: name,
      load: String(u.load || ""),
      active: String(u.active || ""),
      sub: String(u.sub || ""),
      description: String(u.description || "")
    })
  }
  return units
}

// systemd escapes unit names (`\x2d` for "-"); show the readable form.
function unescapeName(name) {
  return String(name || "").replace(/\\x([0-9a-fA-F]{2})/g, function(_, hex) {
    return String.fromCharCode(parseInt(hex, 16))
  })
}

function displayName(unit) {
  return unescapeName(unit).replace(/\.service$/, "")
}

function isRunning(u) {
  return !!u && (u.active === "active" || u.active === "activating" || u.active === "reloading")
}

function isTransitioning(u) {
  return !!u && (u.active === "activating" || u.active === "deactivating" || u.active === "reloading")
}

function isFailed(u) {
  return !!u && u.active === "failed"
}

function isAutostart(u) {
  return /^app-.*@autostart\.service$/.test(u.unit)
}

// Transient D-Bus activated units and template-less leftovers are not
// something a person starts or stops by hand.
function isTransient(u) {
  return /^dbus-:/.test(u.unit)
}

function filterUnits(units, options) {
  var opts = options || {}
  var query = String(opts.query || "").trim().toLowerCase()
  var out = []
  for (var i = 0; i < (units || []).length; i++) {
    var u = units[i]
    if (u.load !== "loaded") continue
    if (isTransient(u)) continue
    if (opts.hideAutostart && isAutostart(u)) continue
    if (!opts.showInactive && !isRunning(u) && !isFailed(u)) continue
    if (query !== "") {
      var hay = (displayName(u.unit) + " " + u.description).toLowerCase()
      if (hay.indexOf(query) === -1) continue
    }
    out.push(u)
  }
  out.sort(function(a, b) {
    var ra = rank(a), rb = rank(b)
    if (ra !== rb) return ra - rb
    return displayName(a.unit).localeCompare(displayName(b.unit))
  })
  return out
}

// Failed first (they want attention), then running, then stopped.
function rank(u) {
  if (isFailed(u)) return 0
  if (isRunning(u)) return 1
  return 2
}

function countRunning(units) {
  var n = 0
  for (var i = 0; i < (units || []).length; i++) if (isRunning(units[i])) n++
  return n
}

function countFailed(units) {
  var n = 0
  for (var i = 0; i < (units || []).length; i++) if (isFailed(units[i])) n++
  return n
}

function stateLabel(u) {
  if (!u) return ""
  if (u.sub && u.sub !== u.active) return u.active + " · " + u.sub
  return u.active
}

function elide(text, max) {
  var s = String(text || "").replace(/\s+/g, " ").trim()
  var limit = max || 160
  return s.length > limit ? s.slice(0, limit - 1) + "…" : s
}

// ---- Favorites: an ordered list of unit names, stored in shell.json.

function normalizeFavorites(value) {
  var out = []
  if (!(value instanceof Array)) return out
  for (var i = 0; i < value.length; i++) {
    var name = String(value[i] || "")
    if (name !== "" && out.indexOf(name) === -1) out.push(name)
  }
  return out
}

function toggleFavorite(favorites, unit) {
  var list = normalizeFavorites(favorites)
  var at = list.indexOf(unit)
  if (at === -1) list.push(unit)
  else list.splice(at, 1)
  return list
}

function moveItem(list, from, to) {
  var out = (list || []).slice()
  if (from < 0 || from >= out.length || to < 0 || to >= out.length || from === to) return out
  var item = out.splice(from, 1)[0]
  out.splice(to, 0, item)
  return out
}

function sameList(a, b) {
  if ((a || []).length !== (b || []).length) return false
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function unitMap(units) {
  var map = {}
  for (var i = 0; i < (units || []).length; i++) map[units[i].unit] = units[i]
  return map
}

// A favorite whose unit is gone (uninstalled, never loaded) still gets a
// row so it can be removed or reordered.
function favoriteUnit(map, name) {
  return map[name] || { unit: name, load: "not-found", active: "inactive", sub: "not loaded", description: "" }
}

// ---- Details

function descriptionOf(u) {
  if (!u) return ""
  var d = String(u.description || "")
  return d === u.unit ? "" : d
}

// `systemctl is-enabled` words. Only enabled/disabled are something a
// person flips; the rest are explained instead.
function isEnabledState(state) {
  return state === "enabled" || state === "enabled-runtime" || state === "linked" || state === "alias"
}

function canToggleEnable(state) {
  return state === "enabled" || state === "disabled"
}

function enableStateHint(state) {
  switch (state) {
  case "": return "Checking…"
  case "enabled": return "Starts automatically when you log in"
  case "disabled": return "Only runs when started by hand or by another unit"
  case "enabled-runtime": return "Enabled until next reboot"
  case "static": return "Static: started by other units, has no install section"
  case "indirect": return "Indirect: enabled through another unit"
  case "generated": return "Generated: managed automatically (e.g. XDG autostart)"
  case "transient": return "Transient: created at runtime"
  case "masked": return "Masked: cannot be started"
  case "alias": return "Alias of another unit"
  case "linked": return "Linked from outside the unit path"
  case "not-found": return "Unit file not found"
  default: return state
  }
}

// ---- Resource figures from `systemctl show`

// `systemctl show` prints KEY=value lines, one blank-line-separated block
// per unit. Returns an array of { Key: "value" } objects.
function parseShow(text) {
  var blocks = []
  var current = null
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") { current = null; continue }
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    if (!current) { current = {}; blocks.push(current) }
    current[line.slice(0, eq)] = line.slice(eq + 1)
  }
  return blocks
}

// Unset figures come back as "[not set]" or the max-uint64 sentinel.
function numberOrNull(value) {
  var s = String(value === undefined ? "" : value)
  if (s === "" || s === "[not set]" || s === "infinity" || s === "18446744073709551615") return null
  var n = Number(s)
  return isFinite(n) ? n : null
}

// memory.sh output: one "<unit>=<bytes>" line per service.
function memoryLines(text) {
  var map = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].lastIndexOf("=")
    if (eq <= 0) continue
    var bytes = Number(lines[i].slice(eq + 1))
    if (isFinite(bytes) && bytes > 0) map[lines[i].slice(0, eq)] = bytes
  }
  return map
}

function formatBytes(bytes) {
  if (bytes === null || bytes === undefined || !(bytes >= 0)) return "—"
  var units = ["B", "K", "M", "G", "T"]
  var v = bytes, u = 0
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++ }
  return (v >= 10 || u === 0 ? Math.round(v) : Math.round(v * 10) / 10) + units[u]
}

function formatDuration(seconds) {
  if (seconds === null || seconds === undefined || !(seconds >= 0)) return "—"
  var s = Math.floor(seconds)
  var d = Math.floor(s / 86400); s -= d * 86400
  var h = Math.floor(s / 3600); s -= h * 3600
  var m = Math.floor(s / 60); s -= m * 60
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m " + s + "s"
  return s + "s"
}

// `--timestamp=unix` gives "@<seconds>".
function unixTimestamp(value) {
  var m = /^@(\d+)/.exec(String(value || ""))
  return m ? Number(m[1]) : null
}

function formatCpu(nsec) {
  if (nsec === null) return "—"
  return formatDuration(nsec / 1e9)
}

// Row memory tooltip; labels padded so the figures line up in a
// monospace face.
function memoryTooltip(ram, vram) {
  var lines = []
  if (ram !== undefined) lines.push("RAM:  " + formatBytes(ram))
  if (vram !== undefined) lines.push("VRAM: " + formatBytes(vram))
  return lines.join("\n")
}
