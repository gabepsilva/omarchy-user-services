import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// User services: `systemctl --user` services in a popup, each with a switch
// to start/stop it and a button to restart it.
//
// Two tabs. All lists every loaded service with a filter and a star to mark
// favorites. Favorites lists the starred ones in an order you set by
// dragging; that order is stored in this widget's shell.json entry.
//
// One entry point carries both the bar button and the popup, the same shape
// as the built-in Tailscale widget.
Panel {
  id: root
  moduleName: "io.github.gabepsilva.user-services"
  ipcTarget: "io.github.gabepsilva.user-services"
  manageIpc: false

  // ---- State
  property var units: []
  property bool loaded: false
  property string loadError: ""
  property string query: ""
  property int cursorIndex: 0
  property bool cursorActive: false

  // Empty until the user picks one, so a fresh popup lands on Favorites
  // when there are any and on All otherwise.
  property string chosenTab: ""
  readonly property string tab: chosenTab !== "" ? chosenTab : (favorites.length > 0 ? "favorites" : "all")

  // True while a favorites row is being dragged: the list model is the
  // source of truth until release, then the order is written back.
  property bool dragging: false

  // The unit an action is in flight for, and what that action is, so the
  // row can show it without the whole list going busy.
  property string busyUnit: ""
  property string busyVerb: ""
  property string actionStatus: ""
  property bool actionFailed: false

  readonly property bool showInactive: setting("showInactive", true) === true
  readonly property bool hideAutostart: setting("hideAutostart", true) === true
  readonly property int refreshIntervalSec: Math.max(2, Number(setting("refreshIntervalSec", 5)) || 5)
  readonly property var favorites: Model.normalizeFavorites(setting("favorites", []))

  readonly property var unitsByName: Model.unitMap(units)
  readonly property var visibleUnits: Model.filterUnits(units, {
    query: query,
    showInactive: showInactive,
    hideAutostart: hideAutostart
  })
  readonly property int runningCount: Model.countRunning(units)
  readonly property int failedCount: Model.countFailed(units)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Data
  function refresh() {
    if (listProcess.running) return
    listProcess.command = ["systemctl", "--user", "list-units", "--type=service", "--all", "--output=json", "--no-pager"]
    listProcess.running = true
    // Figures are only shown in the open list; the closed widget only needs
    // the failed count for its icon. The details view measures its own unit.
    if (root.opened && !root.detailsOpen) refreshMemory()
  }

  // RAM each service actually holds (anon + shmem + kernel, no page cache),
  // read from the cgroups by memory.sh beside this file.
  readonly property string memoryScript: scriptPath("memory.sh")
  // GPU memory per service: kernel DRM fdinfo, plus nvidia-smi when present.
  readonly property string vramScript: scriptPath("vram.sh")
  readonly property string logsScript: scriptPath("logs.sh")
  readonly property int logsMaxBytes: 65536

  function scriptPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  function refreshMemory() {
    if (!memProcess.running) {
      memProcess.command = ["sh", root.memoryScript]
      memProcess.running = true
    }
    if (!vramProcess.running) {
      vramProcess.command = ["bash", root.vramScript]
      vramProcess.running = true
    }
  }

  // Just the unit whose details are open, merged into the shared maps.
  function refreshUnitMemory() {
    if (!detailsOpen) return
    if (!memUnitProcess.running) {
      memUnitProcess.unit = detailsUnit
      memUnitProcess.command = ["sh", root.memoryScript, detailsUnit]
      memUnitProcess.running = true
    }
    if (!vramUnitProcess.running) {
      vramUnitProcess.unit = detailsUnit
      vramUnitProcess.command = ["bash", root.vramScript, detailsUnit]
      vramUnitProcess.running = true
    }
  }

  function refreshStats() {
    if (!detailsOpen || statsProcess.running) return
    statsProcess.command = ["systemctl", "--user", "show", "--timestamp=unix", "--no-pager",
      "-p", "MainPID,ActiveEnterTimestamp,TasksCurrent,CPUUsageNSec,NRestarts",
      "--", detailsUnit]
    statsProcess.running = true
  }

  function runAction(verb, unit) {
    if (!unit || unit === "") return
    if (actionProcess.running) return
    root.busyUnit = unit
    root.busyVerb = verb
    root.actionStatus = ""
    root.actionFailed = false
    actionProcess.command = ["systemctl", "--user", verb, "--", unit]
    actionProcess.running = true
  }

  function toggleUnit(u) {
    if (!u) return
    runAction(Model.isRunning(u) ? "stop" : "start", u.unit)
  }

  function restartUnit(u) {
    if (!u) return
    runAction("restart", u.unit)
  }

  // ---- Details popup: header, start-at-login switch, then the journal.
  property string detailsUnit: ""
  readonly property bool detailsOpen: detailsUnit !== ""
  readonly property var detailsData: detailsOpen ? Model.favoriteUnit(unitsByName, detailsUnit) : null
  property string enableState: ""
  property string enableError: ""
  property string logsText: ""

  // Log colours follow the theme: its palette (for ANSI colours and the
  // warning yellow) is read from the theme's colors.toml, re-read each time
  // details open so a theme switch is picked up.
  property var logPalette: ({})
  readonly property var logColors: ({
    foreground: String(root.foreground),
    dim: String(root.dim),
    error: String(root.urgent),
    warning: root.logPalette[3] || "#d7a94b",
    palette: root.logPalette
  })
  property bool logsLoaded: false

  // Memory per running unit for the list, and the full figures for the
  // unit whose details are open.
  property var memoryByUnit: ({})
  // Last raw outputs, to skip re-publishing identical results.
  property string _listText: ""
  property string _memText: ""
  property string _vramText: ""
  property var vramByUnit: ({})
  property var stats: ({})
  property real nowSec: Date.now() / 1000
  readonly property bool detailsRunning: Model.isRunning(detailsData)
  readonly property var activeSince: Model.unixTimestamp(stats.ActiveEnterTimestamp)

  function openDetails(unit) {
    if (!unit) return
    themeColors.reload()
    root.detailsUnit = unit
    root.enableState = ""
    root.enableError = ""
    root.logsText = ""
    root.logsLoaded = false
    if (logsFlick) logsFlick.pinned = true
    root.stats = ({})
    root.nowSec = Date.now() / 1000
    refreshStats()
    refreshEnableState()
    refreshLogs()
  }

  function closeDetails() {
    root.detailsUnit = ""
    if (root.opened) refreshMemory()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function refreshEnableState() {
    if (!detailsOpen || enableStateProcess.running) return
    enableStateProcess.command = ["systemctl", "--user", "is-enabled", "--", detailsUnit]
    enableStateProcess.running = true
  }

  function setEnabled(on) {
    if (!detailsOpen || enableProcess.running || !Model.canToggleEnable(enableState)) return
    // Flip optimistically so the knob throws on the click; the exit
    // handler re-reads the real state either way.
    root.enableError = ""
    enableProcess.command = ["systemctl", "--user", on ? "enable" : "disable", "--", detailsUnit]
    root.enableState = on ? "enabled" : "disabled"
    enableProcess.running = true
  }

  function refreshLogs() {
    if (!detailsOpen || logsProcess.running) return
    // logs.sh caps the output in bytes (not just lines) before it reaches
    // the shell, and marks the cut; see the script.
    logsProcess.command = ["sh", root.logsScript, detailsUnit, "300", String(root.logsMaxBytes)]
    logsProcess.running = true
  }

  function followLogs() {
    if (!detailsOpen) return
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec",
      "--app-id=org.omarchy.terminal", "--title=" + Model.displayName(detailsUnit) + " logs",
      "-e", "journalctl", "--user-unit=" + detailsUnit, "-f", "-n", "200"])
  }

  // ---- Favorites
  function isFavorite(unit) {
    return favorites.indexOf(unit) !== -1
  }

  // Applied locally first so the star and the list react on the click
  // itself; the shell.json write comes back through the bar as the same
  // value. Without a writable entry it stays a session-only preference.
  function persistFavorites(list) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.favorites = list
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleFavorite(u) {
    if (!u) return
    persistFavorites(Model.toggleFavorite(favorites, u.unit))
  }

  function modelOrder() {
    var out = []
    for (var i = 0; i < favModel.count; i++) out.push(favModel.get(i).unit)
    return out
  }

  // ListModel rather than a JS array so a drag can move rows without the
  // delegates (and the mouse grab inside them) being torn down.
  function syncFavModel() {
    if (root.dragging) return
    if (Model.sameList(modelOrder(), favorites)) return
    favModel.clear()
    for (var i = 0; i < favorites.length; i++) favModel.append({ unit: favorites[i] })
  }

  function commitFavoriteOrder() {
    var order = modelOrder()
    if (!Model.sameList(order, favorites)) persistFavorites(order)
  }

  function moveFavorite(from, to) {
    if (from < 0 || to < 0 || from >= favModel.count || to >= favModel.count || from === to) return
    favModel.move(from, to, 1)
  }

  // ---- Tabs
  function setTab(name) {
    if (name === root.tab) return
    root.chosenTab = name
    root.cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (name !== "all" && searchField.activeFocus) keyCatcher.forceActiveFocus()
  }

  // ---- Cursor
  function rowCount() {
    return tab === "all" ? visibleUnits.length : favModel.count
  }

  function unitAt(index) {
    if (index < 0 || index >= rowCount()) return null
    if (tab === "all") return visibleUnits[index]
    return Model.favoriteUnit(unitsByName, favModel.get(index).unit)
  }

  function selectedUnit() {
    return unitAt(Math.max(0, Math.min(cursorIndex, rowCount() - 1)))
  }

  function rowItem(index) {
    if (tab === "all") return index >= 0 && index < unitColumn.children.length ? unitColumn.children[index] : null
    return favList.itemAtIndex(index)
  }

  function clampCursor() {
    if (cursorIndex >= rowCount()) cursorIndex = Math.max(0, rowCount() - 1)
    if (cursorIndex < 0) cursorIndex = 0
  }

  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; clampCursor(); scrollCursorIntoView(); return }
    cursorIndex = Math.max(0, Math.min(rowCount() - 1, cursorIndex + dy))
    scrollCursorIntoView()
  }

  function moveSelectedFavorite(delta) {
    if (tab !== "favorites" || !cursorActive) return
    var to = cursorIndex + delta
    if (to < 0 || to >= favModel.count) return
    moveFavorite(cursorIndex, to)
    cursorIndex = to
    commitFavoriteOrder()
    scrollCursorIntoView()
  }

  function setCursor(index) {
    if (root.dragging) return
    cursorActive = true
    cursorIndex = index
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      var item = rowItem(cursorIndex)
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function focusSearch() {
    setTab("all")
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    syncFavModel()
    refresh()
  }

  onOpenedChanged: {
    if (!opened) { detailsUnit = ""; return }
    cursorActive = false
    cursorIndex = 0
    chosenTab = ""
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onFavoritesChanged: syncFavModel()
  onVisibleUnitsChanged: clampCursor()
  onTabChanged: clampCursor()

  ListModel { id: favModel }

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.logPalette = Model.parseThemePalette(text())
  }

  // Fast while the popup is open, slow otherwise so the bar icon still
  // notices a unit falling over.
  Timer {
    interval: root.opened ? root.refreshIntervalSec * 1000 : 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: if (!root.actionFailed) root.actionStatus = ""
  }

  Process {
    id: listProcess
    running: false
    command: []
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.loadError = Model.elide(listStderr.text || "systemctl --user list-units failed")
        return
      }
      // Unchanged output keeps the current array, so the All list's Repeater
      // does not tear down and rebuild every row on each poll.
      var text = String(listStdout.text || "")
      if (root.loaded && text === root._listText) {
        root.loadError = ""
        return
      }
      var parsed = Model.parseUnits(text)
      if (parsed === null) {
        root.loadError = "Could not parse systemctl output"
        return
      }
      root._listText = text
      root.loadError = ""
      root.units = parsed
      root.loaded = true
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var name = Model.displayName(root.busyUnit)
      if (exitCode !== 0) {
        root.actionFailed = true
        root.actionStatus = Model.elide(actionStderr.text || (root.busyVerb + " " + name + " failed"))
      } else {
        root.actionFailed = false
        root.actionStatus = Model.doneLabel(root.busyVerb) + " " + name
        statusTimer.restart()
      }
      root.busyUnit = ""
      root.busyVerb = ""
      root.refresh()
    }
  }

  // While details are open the journal is re-read every couple of seconds.
  Timer {
    interval: 2000
    running: root.opened && root.detailsOpen
    repeat: true
    onTriggered: {
      root.nowSec = Date.now() / 1000
      root.refreshLogs()
      root.refreshStats()
      root.refreshUnitMemory()
    }
  }

  Process {
    id: enableStateProcess
    running: false
    command: []
    stdout: StdioCollector { id: enableStateStdout; waitForEnd: true }
    // is-enabled exits non-zero for "disabled"; the word on stdout is what counts.
    onExited: function(exitCode) {
      root.enableState = String(enableStateStdout.text || "").trim().split("\n")[0]
    }
  }

  Process {
    id: enableProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: enableStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.enableError = Model.elide(enableStderr.text || "Could not change start at login")
      root.refreshEnableState()
    }
  }

  Process {
    id: memProcess
    running: false
    command: []
    stdout: StdioCollector { id: memStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && memStdout.text !== root._memText) {
        root._memText = memStdout.text
        root.memoryByUnit = Model.memoryLines(memStdout.text)
      }
    }
  }

  Process {
    id: memUnitProcess
    property string unit: ""
    running: false
    command: []
    stdout: StdioCollector { id: memUnitStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0)
        root.memoryByUnit = Model.withUnitValue(root.memoryByUnit, unit, Model.memoryLines(memUnitStdout.text)[unit])
    }
  }

  Process {
    id: vramProcess
    running: false
    command: []
    stdout: StdioCollector { id: vramStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && vramStdout.text !== root._vramText) {
        root._vramText = vramStdout.text
        root.vramByUnit = Model.memoryLines(vramStdout.text)
      }
    }
  }

  Process {
    id: vramUnitProcess
    property string unit: ""
    running: false
    command: []
    stdout: StdioCollector { id: vramUnitStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0)
        root.vramByUnit = Model.withUnitValue(root.vramByUnit, unit, Model.memoryLines(vramUnitStdout.text)[unit])
    }
  }

  Process {
    id: statsProcess
    running: false
    command: []
    stdout: StdioCollector { id: statsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var blocks = Model.parseShow(statsStdout.text)
      root.stats = exitCode === 0 && blocks.length > 0 ? blocks[0] : ({})
    }
  }

  Process {
    id: logsProcess
    running: false
    command: []
    stdout: StdioCollector { id: logsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(logsStdout.text || "").replace(/\s+$/, "")
      if (text === "-- No entries --") text = ""
      if (text !== root.logsText) root.logsText = text
      root.logsLoaded = true
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function details(unit: string): string { root.open(); root.openDetails(unit); return "ok" }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function start(unit: string): string { root.runAction("start", unit); return "ok" }
    function stop(unit: string): string { root.runAction("stop", unit); return "ok" }
    function restart(unit: string): string { root.runAction("restart", unit); return "ok" }
    function favorite(unit: string): string { root.toggleFavorite({ unit: unit }); return root.isFavorite(unit) ? "added" : "removed" }
    function favorites(): string { return JSON.stringify(root.favorites) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰒓"
    active: root.failedCount > 0
    tooltipText: root.failedCount > 0
      ? root.failedCount + " failed user service" + (root.failedCount === 1 ? "" : "s")
      : root.runningCount + " user services running"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.detailsOpen ? 640 : 440))
    contentHeight: root.detailsOpen
      ? panel.fittedContentHeight(Style.space(640), Style.space(640))
      : panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || root.detailsOpen
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.setTab(dx > 0 ? "all" : "favorites")
        else root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.toggleUnit(root.selectedUnit())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") root.focusSearch()
        else if (t === "r" && root.cursorActive) root.restartUnit(root.selectedUnit())
        else if ((t === "d" || t === "i") && root.cursorActive) { var du = root.selectedUnit(); if (du) root.openDetails(du.unit) }
        else if (t === "s" && root.cursorActive) root.toggleFavorite(root.selectedUnit())
        else if (t === "J") root.moveSelectedFavorite(1)
        else if (t === "K") root.moveSelectedFavorite(-1)
        else if (t === "R") root.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height && !root.dragging
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        visible: !root.detailsOpen

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // Header: title on the left, tabs and refresh on the right.
          Item {
            width: parent.width
            implicitHeight: Math.max(hero.implicitHeight, headerControls.implicitHeight)

          PanelHero {
            id: hero
            width: parent.width - headerControls.width - Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            title: "User services"
            meta: {
              if (root.loadError !== "") return "Unavailable"
              if (!root.loaded) return "Loading…"
              var parts = [root.runningCount + " running"]
              if (root.failedCount > 0) parts.push(root.failedCount + " failed")
              return parts.join(" · ")
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰒓"
                color: root.failedCount > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Row {
            id: headerControls
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            ButtonGroup {
              id: tabs
              anchors.verticalCenter: parent.verticalCenter
              options: [
                { value: "favorites", label: "Favorites" + (root.favorites.length > 0 ? " · " + root.favorites.length : "") },
                { value: "all", label: "All" }
              ]
              value: root.tab
              focusable: false
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) { root.setTab(v) }
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              tooltipText: "Refresh list (R)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.actionStatus !== "" || root.loadError !== ""
            width: parent.width
            text: root.loadError !== "" ? root.loadError : root.actionStatus
            color: root.loadError !== "" || root.actionFailed ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          TextField {
            id: searchField
            visible: root.tab === "all"
            width: parent.width
            foreground: root.foreground
            placeholderText: "Filter services  (/)"
            text: root.query
            onTextChanged: {
              root.query = text
              root.cursorIndex = 0
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (text !== "") text = ""
                else root.close()
                keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                keyCatcher.forceActiveFocus()
                root.cursorActive = true
                root.cursorIndex = 0
                event.accepted = true
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Text {
            visible: root.tab === "all" && root.loaded && root.visibleUnits.length === 0
            width: parent.width
            text: root.query !== "" ? "No services match." : "No user services."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: root.tab === "favorites" && favModel.count === 0
            width: parent.width
            text: "No favorites yet. Star services in the All tab."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---- All
          Column {
            id: unitColumn
            visible: root.tab === "all"
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.tab === "all" ? root.visibleUnits : []
              UnitRow {
                required property var modelData
                required property int index
                width: unitColumn.width
                unitData: modelData
                rowIndex: index
                showStar: true
              }
            }
          }

          // ---- Favorites
          ListView {
            id: favList
            visible: root.tab === "favorites"
            width: parent.width
            height: contentHeight
            interactive: false
            spacing: Style.space(4)
            model: favModel

            moveDisplaced: Transition {
              NumberAnimation { properties: "y"; duration: 120; easing.type: Easing.OutCubic }
            }
            move: Transition {
              NumberAnimation { properties: "y"; duration: 120; easing.type: Easing.OutCubic }
            }

            delegate: UnitRow {
              required property string unit
              required property int index
              width: favList.width
              unitData: Model.favoriteUnit(root.unitsByName, unit)
              rowIndex: index
              showHandle: true
            }
          }
        }
      }

      // Details popup: laid over the list inside the same panel window,
      // which widens while it is open so the journal has room.
      Popup {
        id: detailsPopup
        x: 0
        y: 0
        width: parent.width
        height: parent.height
        padding: 0
        modal: false
        focus: true
        visible: root.detailsOpen
        closePolicy: Popup.CloseOnEscape
        onClosed: if (root.detailsOpen) root.closeDetails()
        onOpened: Qt.callLater(function() { detailsContent.forceActiveFocus() })

        background: Item {}

        contentItem: ColumnLayout {
          id: detailsContent
          focus: true
          spacing: Style.space(12)
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.text === "q") {
              root.closeDetails(); event.accepted = true
            } else if (event.text === "e") {
              root.setEnabled(!Model.isEnabledState(root.enableState)); event.accepted = true
            } else if (event.text === "r") {
              root.restartUnit(root.detailsData); event.accepted = true
            } else if (event.text === "f") {
              root.followLogs(); event.accepted = true
            } else if (event.key === Qt.Key_Down || event.text === "j") {
              logsFlick.scrollBy(Style.space(40)); event.accepted = true
            } else if (event.key === Qt.Key_Up || event.text === "k") {
              logsFlick.scrollBy(-Style.space(40)); event.accepted = true
            }
          }

          // Header: name and description.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            RowIconButton {
              glyph: "󰁍"
              tooltipText: "Back (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignTop
              onClicked: root.closeDetails()
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: Model.displayName(root.detailsUnit)
                color: Model.isFailed(root.detailsData) ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: text !== ""
                text: Model.descriptionOf(root.detailsData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }

            RowIconButton {
              glyph: "󰑖"
              tooltipText: "Restart service (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.busyUnit === "" && root.detailsData !== null && root.detailsData.load === "loaded"
              Layout.alignment: Qt.AlignTop
              onClicked: root.restartUnit(root.detailsData)
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: text !== ""
            text: root.busyUnit === root.detailsUnit && root.busyUnit !== ""
              ? Model.busyLabel(root.busyVerb)
              : root.actionStatus
            color: root.actionFailed && root.busyUnit === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // Resource figures. PID and uptime only live here, not on the rows.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            StatCell {
              label: "STATUS"
              value: root.detailsData ? (root.detailsData.sub || root.detailsData.active) : "—"
              valueColor: Model.isFailed(root.detailsData) ? root.urgent : root.foreground
            }
            StatCell {
              label: "PID"
              value: root.detailsRunning && Model.numberOrNull(root.stats.MainPID) > 0 ? String(root.stats.MainPID) : "—"
            }
            StatCell {
              label: "UPTIME"
              value: root.detailsRunning && root.activeSince ? Model.formatDuration(root.nowSec - root.activeSince) : "—"
            }
            StatCell {
              label: "MEMORY"
              value: root.detailsRunning && root.memoryByUnit[root.detailsUnit] !== undefined
                ? Model.formatBytes(root.memoryByUnit[root.detailsUnit]) : "—"
            }
            StatCell {
              label: "VRAM"
              value: root.detailsRunning && root.vramByUnit[root.detailsUnit] !== undefined
                ? Model.formatBytes(root.vramByUnit[root.detailsUnit]) : "—"
            }
            StatCell {
              label: "CPU"
              value: Model.formatCpu(Model.numberOrNull(root.stats.CPUUsageNSec))
            }
            StatCell {
              label: "TASKS"
              value: root.detailsRunning && Model.numberOrNull(root.stats.TasksCurrent) !== null ? String(root.stats.TasksCurrent) : "—"
              detail: Model.numberOrNull(root.stats.NRestarts) > 0 ? root.stats.NRestarts + " restarts" : ""
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // Start at login.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Start at login"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.enableError !== "" ? root.enableError : Model.enableStateHint(root.enableState)
                color: root.enableError !== "" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            ToggleSwitch {
              id: enableSwitch
              Layout.alignment: Qt.AlignVCenter
              enabled: Model.canToggleEnable(root.enableState)
              opacity: enabled ? 1.0 : 0.4
              checked: Model.isEnabledState(root.enableState)
              busy: enableProcess.running
              cursorRing: false
              foreground: root.foreground
              onToggled: root.setEnabled(!checked)

              PanelToolTip {
                visible: enableSwitch.containsMouse
                text: enableSwitch.checked ? "Don't start at login (e)" : "Start at login (e)"
                fontFamily: root.fontFamily
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // Logs.
          RowLayout {
            Layout.fillWidth: true

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "LOGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowIconButton {
              glyph: "󰆍"
              tooltipText: "Follow in terminal (f)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.followLogs()
            }
          }

          BorderSurface {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, Color.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

            Flickable {
              id: logsFlick
              anchors.fill: parent
              anchors.margins: Style.space(8)
              contentWidth: width
              contentHeight: logsEdit.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              // Stay pinned to the newest line unless the user scrolled up.
              property bool pinned: true
              readonly property real bottomY: Math.max(0, contentHeight - height)
              function scrollBy(dy) {
                contentY = Math.max(0, Math.min(bottomY, contentY + dy))
                pinned = contentY >= bottomY - Style.space(8)
              }
              // Deferred: the wrapped text settles its height after the
              // change that triggered this, so scroll once layout is done.
              function pinToEnd() {
                if (!pinned) return
                Qt.callLater(function() {
                  logsFlick.contentY = Math.max(0, logsFlick.contentHeight - logsFlick.height)
                })
              }
              onMovementEnded: pinned = contentY >= bottomY - Style.space(8)
              onContentHeightChanged: pinToEnd()
              onHeightChanged: pinToEnd()

              TextEdit {
                id: logsEdit
                width: logsFlick.width
                readOnly: true
                selectByMouse: true
                // Rich text built by Model.logsHtml: severity colours, dimmed
                // headers, the service's own ANSI colours. Everything from
                // the journal is HTML-escaped there.
                textFormat: TextEdit.RichText
                wrapMode: TextEdit.WrapAnywhere
                text: !root.logsLoaded
                  ? Model.plainHtml("Loading…", String(root.dim))
                  : (root.logsText !== ""
                    ? Model.logsHtml(root.logsText, root.logColors)
                    : Model.plainHtml("No log entries.", String(root.dim)))
                color: root.foreground
                selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  component UnitRow: CursorSurface {
    id: row
    property var unitData: null
    property int rowIndex: 0
    property bool showStar: false
    property bool showHandle: false
    readonly property string unitName: unitData ? unitData.unit : ""
    readonly property bool present: unitData ? unitData.load === "loaded" : false
    readonly property bool running: Model.isRunning(unitData)
    readonly property bool failed: Model.isFailed(unitData)
    readonly property bool favorite: root.favorites.indexOf(unitName) !== -1
    readonly property bool busy: root.busyUnit !== "" && root.busyUnit === unitName
    readonly property bool anyBusy: root.busyUnit !== ""
    readonly property bool held: handleMouse.pressed
    readonly property var ram: root.memoryByUnit[unitName]
    readonly property var vram: root.vramByUnit[unitName]

    hasCursor: held || (root.cursorActive && root.cursorIndex === rowIndex)
    foreground: root.foreground
    z: held ? 10 : 0
    implicitHeight: Math.max(content.implicitHeight, powerSwitch.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (containsMouse) root.setCursor(row.rowIndex)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: row.showHandle ? Style.space(2) : Style.space(10)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(8)

      // Drag handle: pressing it grabs the row; moving over another row's
      // slot swaps the model in place so the list reflows under the pointer.
      Item {
        visible: row.showHandle
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(18)
        Layout.preferredHeight: Style.space(22)

        CenteredGlyph {
          anchors.fill: parent
          text: "󰇛"
          color: row.held ? root.foreground : root.dim
        }

        MouseArea {
          id: handleMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          enabled: row.showHandle
          hoverEnabled: true
          preventStealing: true
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          onPressed: {
            root.dragging = true
            root.cursorActive = true
            root.cursorIndex = row.rowIndex
          }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var p = mapToItem(favList.contentItem, mouse.x, mouse.y)
            var to = favList.indexAt(Style.space(20), p.y)
            if (to >= 0 && to !== row.rowIndex) {
              root.moveFavorite(row.rowIndex, to)
              root.cursorIndex = to
            }
          }
          onReleased: {
            root.dragging = false
            root.commitFavoriteOrder()
          }
          onCanceled: {
            root.dragging = false
            root.commitFavoriteOrder()
          }
        }
      }

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.space(8)
        implicitHeight: Style.space(8)
        radius: width / 2
        color: row.failed ? root.urgent : (row.running ? root.foreground : "transparent")
        border.width: row.running || row.failed ? 0 : 1
        border.color: root.dim
        opacity: row.busy || Model.isTransitioning(row.unitData) ? 0.4 : 1.0

        SequentialAnimation on opacity {
          running: row.busy
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.3; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        id: content
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.displayName(row.unitName)
          color: row.failed ? root.urgent : (row.running ? root.foreground : root.dim)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: Model.descriptionOf(row.unitData)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      RowIconButton {
        visible: row.showStar
        glyph: row.favorite ? "󰓎" : "󰓒"
        tooltipText: row.favorite ? "Remove from favorites (s)" : "Add to favorites (s)"
        foreground: row.favorite ? root.foreground : root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.setCursor(row.rowIndex) }
        onClicked: root.toggleFavorite(row.unitData)
      }

      // RAM, with GPU memory underneath when the service holds any. One
      // hover area over both figures; the tooltip names them.
      Item {
        visible: row.running && (row.ram !== undefined || row.vram !== undefined)
        Layout.alignment: Qt.AlignVCenter
        Layout.minimumWidth: Style.space(40)
        implicitWidth: figures.implicitWidth
        implicitHeight: figures.implicitHeight

        ColumnLayout {
          id: figures
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          MemoryFigure {
            Layout.alignment: Qt.AlignRight
            visible: row.ram !== undefined
            text: Model.formatBytes(row.ram)
          }

          MemoryFigure {
            Layout.alignment: Qt.AlignRight
            visible: row.vram !== undefined
            text: Model.formatBytes(row.vram)
          }
        }

        MouseArea {
          id: figuresMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onContainsMouseChanged: if (containsMouse) root.setCursor(row.rowIndex)
        }

        PanelToolTip {
          visible: figuresMouse.containsMouse
          text: Model.memoryTooltip(row.ram, row.vram)
          fontFamily: root.fontFamily
        }
      }

      RowIconButton {
        glyph: "󰋽"
        tooltipText: "Details (d)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.setCursor(row.rowIndex) }
        onClicked: root.openDetails(row.unitName)
      }

      ToggleSwitch {
        id: powerSwitch
        Layout.alignment: Qt.AlignVCenter
        enabled: row.present
        opacity: row.present ? 1.0 : 0.4
        checked: row.busy ? (root.busyVerb !== "stop") : row.running
        busy: row.anyBusy
        cursorRing: false
        foreground: root.foreground
        onHovered: function(on) { if (on) root.setCursor(row.rowIndex) }
        onToggled: root.toggleUnit(row.unitData)

        PanelToolTip {
          visible: powerSwitch.containsMouse
          text: row.running ? "Stop (Enter)" : "Start (Enter)"
          fontFamily: root.fontFamily
        }
      }
    }
  }

  // A small dim figure on a row.
  component MemoryFigure: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // One labelled figure in the details stats strip.
  component StatCell: ColumnLayout {
    property string label: ""
    property string value: ""
    property string detail: ""
    property color valueColor: root.foreground
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    Layout.alignment: Qt.AlignTop
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: parent.detail !== ""
      text: parent.detail
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // Nerd Font icons sit high in their line box, so centering the Text item
  // leaves the glyph above its neighbours. This centers the painted bounds.
  component CenteredGlyph: Item {
    id: cg
    property string text: ""
    property color color: root.foreground
    property real fontSize: Style.font.icon

    TextMetrics {
      id: cgMetrics
      font: cgText.font
      text: cg.text
    }

    Text {
      id: cgText
      textFormat: Text.PlainText
      text: cg.text
      color: cg.color
      font.family: root.fontFamily
      font.pixelSize: cg.fontSize
      x: Math.round((cg.width - cgMetrics.tightBoundingRect.width) / 2 - cgMetrics.tightBoundingRect.x)
      y: Math.round((cg.height - cgMetrics.tightBoundingRect.height) / 2 - cgText.baselineOffset - cgMetrics.tightBoundingRect.y)
    }
  }

  // PanelActionButton with its icon drawn by CenteredGlyph.
  component RowIconButton: PanelActionButton {
    id: rib
    property string glyph: ""
    iconText: ""

    CenteredGlyph {
      anchors.fill: parent
      text: rib.glyph
      fontSize: rib.fontSize
      color: rib.enabled ? (rib._hot ? rib.hoverColor : rib.foreground) : Qt.darker(rib.foreground, 2.0)
    }
  }

}
