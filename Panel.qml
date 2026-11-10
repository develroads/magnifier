import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Smooth Magnifier: bar icon plus settings panel. The zoom itself runs in
// Hyprland (hypr/magnifier.lua); this file reads and changes it through
// `hyprctl repl`, sending only schema keys with checked values.
Panel {
  id: root
  moduleName: "io.github.develroads.smooth-magnifier"
  ipcTarget: "smooth-magnifier"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showLevel: setting("showLevel", true) === true

  readonly property string glyphMagnify: String.fromCodePoint(0xF0349)
  readonly property string glyphMouse: String.fromCodePoint(0xF037D)
  readonly property string glyphKeyboard: String.fromCodePoint(0xF030C)
  readonly property string glyphMonitor: String.fromCodePoint(0xF0379)

  property bool engineReady: false
  property bool engineChecked: false
  property real zoom: 1
  property real dragZoom: -1
  property var s: Model.defaults()
  property string page: "scroll"
  property bool advancedOpen: false
  readonly property var pages: ["scroll", "keyboard", "view"]

  readonly property real shownZoom: dragZoom >= 1 ? dragZoom : zoom
  readonly property bool zoomed: zoom > 1.001
  function zoomLabel(z) { return Commons.I18n.formatNumber(z, Model.zoomDecimals(z)) + "×" }

  // ---------------------------------------------------------------- engine
  // One hyprctl at a time. Slider drags and wheel bursts coalesce into the
  // latest value instead of queueing a process per event.
  property var pendingSettings: ({})
  property bool hasPendingSettings: false
  property real pendingZoom: -1
  property int pendingScroll: 0
  property var pendingActions: []

  function pump() {
    if (engineProc.running) return
    var code = ""
    if (hasPendingSettings) {
      code = Model.setCall(pendingSettings)
      pendingSettings = ({})
      hasPendingSettings = false
    } else if (pendingZoom >= 1) {
      code = Model.zoomCall(pendingZoom)
      pendingZoom = -1
    } else if (pendingScroll !== 0) {
      code = Model.scrollCall(pendingScroll)
      pendingScroll = 0
    } else if (pendingActions.length > 0) {
      code = Model.callFor(pendingActions[0])
      pendingActions = pendingActions.slice(1)
    }
    if (code === "") return
    engineProc.command = ["hyprctl", "repl", code]
    engineProc.running = true
  }

  function engineAction(name) {
    if (Model.callFor(name) === "") return
    if (pendingActions.indexOf(name) < 0 || name !== "state") pendingActions = pendingActions.concat([name])
    pump()
  }

  function requestZoom(z) {
    pendingZoom = Math.max(1, Math.min(s.max_zoom, z))
    pump()
  }

  function scrollBy(n) {
    pendingScroll = Math.max(-20, Math.min(20, pendingScroll + n))
    pump()
  }

  function setSetting(key, value) {
    var v = Model.normalize(key, value)
    if (v === undefined) return
    var next = Object.assign({}, s)
    next[key] = v
    s = next
    var changes = Object.assign({}, pendingSettings)
    changes[key] = v
    pendingSettings = changes
    hasPendingSettings = true
    pump()
  }

  function receive(text) {
    var state = Model.parseState(text)
    engineChecked = true
    engineReady = state.ok
    loadError = state.ok ? "" : (enginePathOk ? Model.loadError(text) : "unsupported plugin path")
    if (!state.ok) return
    if (dragZoom < 1 && pendingZoom < 1) zoom = state.zoom
    if (state.lockActive !== engineLockActive) logLock("engine reports lock_active " + state.lockActive + " at zoom " + state.zoom)
    engineLockActive = state.lockActive
    // Keep optimistic values for changes still on their way.
    var merged = state.settings
    if (hasPendingSettings) merged = Object.assign({}, merged, pendingSettings)
    s = merged
  }

  Process {
    id: engineProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.receive(text)
    }
    onExited: Qt.callLater(root.pump)
  }

  // The engine writes the settled zoom here, so the bar follows zoom
  // changes made from the keyboard or the wheel without polling.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/smooth-magnifier"
  FileView {
    id: zoomFile
    path: root.stateDir + "/zoom"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: if (root.dragZoom < 1) root.zoom = Model.parseZoom(text())
  }

  // --------------------------------------------------------------- loading
  // No Hyprland config edit: the engine is loaded into Hyprland's Lua state
  // through `hyprctl repl` (every call loads it first when it is missing).
  // A config reload starts Hyprland's Lua state afresh, so the engine is
  // loaded again as soon as Hyprland reports the reload.
  property string loadError: ""
  property bool enginePathOk: false

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") root.engineAction("state")
    }
  }

  // ----------------------------------------------------------- screen lock
  // Hyprland zooms the lock screen too and sends no lock event, and Omarchy
  // keeps its lock state private. While zoomed in (and only then), ask
  // Hyprland directly with `hyprctl locked`. The engine owns the lock state,
  // so a shell restart mid-lock picks it up again.
  property bool engineLockActive: false
  property int lockTicks: 0
  property var lastLocked: null
  // Last lock-watcher events, shown by the `diagnostics` IPC call.
  property var lockLog: []

  function logLock(message) {
    var next = lockLog.slice(-39)
    next.push(new Date().toISOString().slice(11, 23) + " " + message)
    lockLog = next
  }

  function onLockProbe(text) {
    var locked = Model.parseLocked(text)
    if (locked === null) {
      if (lastLocked !== "unreadable") logLock("hyprctl locked: unreadable reply")
      lastLocked = "unreadable"
      return
    }
    if (locked !== lastLocked) logLock("hyprctl locked: " + locked + " (zoomed " + zoomed + ", engine lock " + engineLockActive + ")")
    lastLocked = locked
    if (locked && zoomed && !engineLockActive) {
      engineLockActive = true
      logLock("lock seen while zoomed: zooming out")
      engineAction("lockBegin")
    } else if (!locked && engineLockActive) {
      engineLockActive = false
      logLock("unlocked: restoring zoom")
      engineAction("lockEnd")
    }
  }

  Process {
    id: lockProbe
    command: ["hyprctl", "locked"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onLockProbe(text)
    }
  }

  Timer {
    id: lockWatch
    interval: 250
    repeat: true
    running: root.engineReady && (root.engineLockActive || (root.s.unzoom_on_lock && root.zoomed))
    onRunningChanged: root.logLock("watcher " + (running ? "started" : "stopped"))
    onTriggered: {
      root.lockTicks++
      if (!lockProbe.running) lockProbe.running = true
    }
  }

  Component.onCompleted: {
    enginePathOk = Model.setEnginePath(String(Qt.resolvedUrl("hypr/magnifier.lua")).replace(/^file:\/\//, ""))
    engineAction("state")
  }
  onOpenedChanged: if (opened) engineAction("state")

  ShellIpc {
    target: "smooth-magnifier"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleZoom(): void { root.engineAction("toggle") }
    function zoomIn(): void { root.engineAction("zoomIn") }
    function zoomOut(): void { root.engineAction("zoomOut") }
    function resetZoom(): void { root.engineAction("reset") }
    function showPage(name: string): void {
      if (root.pages.indexOf(name) < 0) return
      root.page = name
      root.open()
    }
    // For bug reports: what the panel and its lock watcher currently see.
    function diagnostics(): string {
      return JSON.stringify({
        engineReady: root.engineReady, loadError: root.loadError, zoom: root.zoom, zoomed: root.zoomed,
        unzoomOnLock: root.s.unzoom_on_lock, lockScreenZoom: root.s.lock_screen_zoom,
        engineLockActive: root.engineLockActive, lastLocked: root.lastLocked,
        watcherRunning: lockWatch.running, watcherTicks: root.lockTicks, lockLog: root.lockLog
      }, null, 2)
    }
  }

  function cyclePage(delta) {
    var i = pages.indexOf(page)
    page = pages[(i + delta + pages.length) % pages.length]
  }

  // ------------------------------------------------------------------ bar
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphMagnify
    labelText: root.showLevel && root.engineReady && root.zoomed && !vertical ? root.zoomLabel(root.zoom) : ""
    slotSize: Style.bar.iconSlot * (labelText !== "" ? 2.4 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.engineAction("toggle")
      else if (b === Qt.MiddleButton) root.engineAction("reset")
      else root.toggle()
    }
    onWheelMoved: function(delta) { if (delta !== 0) root.scrollBy(delta > 0 ? 1 : -1) }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.cyclePage(dx)
        else if (dy !== 0) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(48)))
      }
      onActivateRequested: if (root.engineReady) root.engineAction("toggle")

      Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: contentHeight > height
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroSwitch.implicitHeight)

            PlainText {
              id: heroIcon
              text: root.glyphMagnify
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              scale: root.zoomed ? 1.08 : 1
              Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PlainText {
                width: parent.width
                text: strings.t("title")
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              PlainText {
                width: parent.width
                text: (!root.engineChecked ? strings.t("status.connecting")
                  : !root.engineReady ? strings.t("status.missing")
                  : root.zoomed ? strings.t("status.zoomed").arg(root.zoomLabel(root.zoom))
                  : strings.t("status.off")).toUpperCase()
                color: root.dim
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }

            ToggleSwitch {
              id: heroSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.engineReady
              checked: root.zoomed
              foreground: root.fg
              accent: root.accent
              onToggled: root.engineAction("toggle")
            }
          }

          // ---------- Engine missing ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.engineChecked && !root.engineReady

            PlainText {
              width: parent.width
              text: strings.t("missing.body")
              wrapMode: Text.Wrap
              color: root.dim
              font.pixelSize: Style.font.bodySmall
            }

            PlainText {
              width: parent.width
              visible: root.loadError !== ""
              text: root.loadError
              wrapMode: Text.Wrap
              color: Commons.Color.urgent
              font.pixelSize: Style.font.caption
            }

            Button {
              text: strings.t("missing.retry")
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.engineAction("state")
            }
          }

          // ---------- Zoom level ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.engineReady

            LabelRow {
              label: strings.t("zoom.level")
              value: root.zoomLabel(root.shownZoom)
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0
              maximum: 1
              step: 0.04
              value: Model.zoomToSlider(root.zoom, root.s.max_zoom)
              onMoved: function(v) {
                root.dragZoom = Model.sliderToZoom(v, root.s.max_zoom)
                root.requestZoom(root.dragZoom)
              }
              onReleased: function(v) {
                var z = Model.sliderToZoom(v, root.s.max_zoom)
                root.zoom = z
                root.dragZoom = -1
                root.requestZoom(z)
              }
            }

            Row {
              id: presetRow
              width: parent.width
              spacing: Style.space(6)
              readonly property var presets: [1, 2, 4, 8].filter(function(p) { return p <= root.s.max_zoom })
              readonly property real cellWidth: (width - spacing * (presets.length - 1)) / Math.max(1, presets.length)

              Repeater {
                model: presetRow.presets
                Button {
                  required property var modelData
                  width: presetRow.cellWidth
                  text: root.zoomLabel(modelData)
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  active: Math.abs(root.shownZoom - modelData) < 0.05
                  onClicked: root.requestZoom(modelData)
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg; visible: root.engineReady }

          // ---------- Tabs ----------
          Row {
            id: tabRow
            width: parent.width
            spacing: Style.space(6)
            visible: root.engineReady
            readonly property real cellWidth: (width - spacing * 2) / 3

            Repeater {
              model: [
                { value: "scroll", icon: root.glyphMouse, label: strings.t("tab.scroll") },
                { value: "keyboard", icon: root.glyphKeyboard, label: strings.t("tab.keyboard") },
                { value: "view", icon: root.glyphMonitor, label: strings.t("tab.view") }
              ]
              Button {
                required property var modelData
                width: tabRow.cellWidth
                iconText: modelData.icon
                text: modelData.label
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.page === modelData.value
                onClicked: root.page = modelData.value
              }
            }
          }

          // ---------- Scroll page ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.engineReady && root.page === "scroll"

            SettingToggle {
              key: "scroll_enabled"
              label: strings.t("scroll.enabled")
              description: strings.t("scroll.enabledDesc")
            }

            Column {
              width: parent.width
              spacing: Style.space(10)
              opacity: root.s.scroll_enabled ? 1 : 0.45
              enabled: root.s.scroll_enabled
              Behavior on opacity { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }

              PanelSectionHeader {
                text: strings.t("scroll.modifier")
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Grid {
                id: modGrid
                width: parent.width
                columns: 2
                spacing: Style.space(6)
                readonly property real cellWidth: (width - spacing) / 2

                Repeater {
                  model: Model.MODIFIERS
                  Button {
                    required property var modelData
                    width: modGrid.cellWidth
                    text: Model.chordParts(modelData).join(" + ")
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    bordered: true
                    active: root.s.modifier === modelData
                    onClicked: root.setSetting("modifier", modelData)
                  }
                }
              }

              SettingSlider {
                key: "scroll_speed"
                label: strings.t("scroll.speed")
                minimum: 0.25
                maximum: 3
                step: 0.05
                valueText: Commons.I18n.formatNumber(root.s.scroll_speed, 2) + "×"
              }

              SettingToggle {
                key: "acceleration"
                label: strings.t("scroll.acceleration")
                description: strings.t("scroll.accelerationDesc")
              }

              SettingToggle {
                key: "inertia"
                label: strings.t("scroll.inertia")
                description: strings.t("scroll.inertiaDesc")
              }

              SettingToggle {
                key: "invert_scroll"
                label: strings.t("scroll.invert")
                description: strings.t("scroll.invertDesc")
              }
            }
          }

          // ---------- Keyboard page ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.engineReady && root.page === "keyboard"

            SettingToggle {
              key: "keyboard_enabled"
              label: strings.t("keyboard.enabled")
              description: strings.t("keyboard.enabledDesc")
            }

            SettingToggle {
              key: "hold_enabled"
              label: strings.t("keyboard.hold")
              description: strings.t("keyboard.holdDesc")
            }

            PanelSectionHeader {
              text: strings.t("keyboard.shortcuts")
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              ShortcutRow { label: strings.t("keyboard.toggle"); keys: ["Super", "Alt", "8"]; active: root.s.keyboard_enabled }
              ShortcutRow { label: strings.t("keyboard.in"); keys: ["Super", "Alt", "="]; active: root.s.keyboard_enabled }
              ShortcutRow { label: strings.t("keyboard.out"); keys: ["Super", "Alt", "-"]; active: root.s.keyboard_enabled }
              ShortcutRow { label: strings.t("keyboard.smooth"); keys: ["Super", "Alt", "\\"]; active: root.s.keyboard_enabled }
              ShortcutRow { label: strings.t("keyboard.holdRow"); keys: ["Super", "Alt", "Z"]; active: root.s.hold_enabled }
              ShortcutRow { label: strings.t("keyboard.stepIn"); keys: ["Super", "Ctrl", "Z"]; active: true }
              ShortcutRow { label: strings.t("keyboard.reset"); keys: ["Super", "Ctrl", "Alt", "Z"]; active: true }
              ShortcutRow {
                label: strings.t("keyboard.scroll")
                keys: Model.chordParts(root.s.modifier).concat(["Scroll"])
                active: root.s.scroll_enabled
              }
            }

            PlainText {
              width: parent.width
              text: strings.t("keyboard.bar") + ": " + strings.t("keyboard.barKeys")
              color: root.dim
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          // ---------- View page ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.engineReady && root.page === "view"

            SettingToggle {
              key: "smooth_images"
              label: strings.t("view.smooth")
              description: strings.t("view.smoothDesc")
            }

            SettingSlider {
              key: "smoothness"
              label: strings.t("view.smoothness")
              minimum: 0
              maximum: 1
              step: 0.05
              valueText: root.s.smoothness <= 0.001
                ? strings.t("view.instant")
                : Commons.I18n.formatNumber(Math.round(70 + root.s.smoothness * 380), 0) + " ms"
            }

            PanelSectionHeader {
              text: strings.t("view.range")
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            SettingSlider {
              key: "min_zoom"
              label: strings.t("view.min")
              minimum: 1.25
              maximum: 10
              step: 0.25
              valueText: root.zoomLabel(root.s.min_zoom)
              onCommitted: function(v) {
                if (v >= root.s.max_zoom) root.setSetting("max_zoom", Math.min(40, v * 1.5))
              }
            }

            SettingSlider {
              key: "max_zoom"
              label: strings.t("view.max")
              minimum: 2
              maximum: 40
              step: 1
              valueText: root.zoomLabel(root.s.max_zoom)
              onCommitted: function(v) {
                if (v <= root.s.min_zoom) root.setSetting("min_zoom", Math.max(1.25, v / 1.5))
              }
            }

            SettingToggle {
              key: "restore_zoom"
              label: strings.t("view.restore")
              description: strings.t("view.restoreDesc")
            }

            SettingToggle {
              key: "unzoom_on_lock"
              label: strings.t("view.unzoomLock")
              description: strings.t("view.unzoomLockDesc")
            }

            SettingToggle {
              key: "lock_screen_zoom"
              label: strings.t("view.lockZoom")
              description: strings.t("view.lockZoomDesc")
            }

            // ---------- Advanced (collapsed until asked for) ----------
            Button {
              width: parent.width
              leftAlign: true
              iconText: String.fromCodePoint(root.advancedOpen ? 0xF0140 : 0xF0142)
              text: strings.t("view.advanced") + "  ·  " + strings.t("view." + root.s.follow)
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              active: root.advancedOpen
              onClicked: root.advancedOpen = !root.advancedOpen
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.advancedOpen

              PanelSectionHeader {
                text: strings.t("view.follow")
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Repeater {
                model: Model.FOLLOW
                Button {
                  required property var modelData
                  width: parent.width
                  leftAlign: true
                  text: strings.t("view." + modelData) + (modelData === "continuous" ? "  ·  " + strings.t("view.default") : "")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  active: root.s.follow === modelData
                  onClicked: root.setSetting("follow", modelData)
                }
              }
            }

            Button {
              text: strings.t("view.resetSettings")
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.engineAction("resetSettings")
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components
  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component LabelRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

    PlainText {
      id: labelText
      anchors.left: parent.left
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    PlainText {
      id: valueText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: parent.value
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  component SettingToggle: Toggle {
    property string key: ""
    width: parent ? parent.width : 0
    checked: root.s[key] === true
    foreground: root.fg
    accent: root.accent
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: root.setSetting(key, !checked)
  }

  component SettingSlider: Column {
    id: sliderRow
    property string key: ""
    property string label: ""
    property string valueText: ""
    property real minimum: 0
    property real maximum: 1
    property real step: 0.05
    signal committed(real value)

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    LabelRow { label: sliderRow.label; value: sliderRow.valueText }

    PanelSlider {
      width: parent.width
      bar: root.bar
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: sliderRow.step
      value: Number(root.s[sliderRow.key])
      function snap(v) { return Math.round(v / sliderRow.step) * sliderRow.step }
      onMoved: function(v) { root.setSetting(sliderRow.key, snap(v)) }
      onReleased: function(v) {
        root.setSetting(sliderRow.key, snap(v))
        sliderRow.committed(snap(v))
      }
    }
  }

  component ShortcutRow: Item {
    id: shortcutRow
    property string label: ""
    property var keys: []
    property bool active: true
    width: parent ? parent.width : 0
    implicitHeight: Math.max(shortcutLabel.implicitHeight, capRow.implicitHeight)
    opacity: active ? 1 : 0.4
    Behavior on opacity { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }

    PlainText {
      id: shortcutLabel
      anchors.left: parent.left
      anchors.right: capRow.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: shortcutRow.label
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Row {
      id: capRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Repeater {
        model: shortcutRow.keys
        Rectangle {
          required property var modelData
          implicitWidth: Math.max(implicitHeight, capText.implicitWidth + Style.space(12))
          implicitHeight: capText.implicitHeight + Style.space(6)
          width: implicitWidth
          height: implicitHeight
          radius: Math.min(Style.cornerRadius, height / 3)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22)

          PlainText {
            id: capText
            anchors.centerIn: parent
            text: String(modelData)
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }
}
