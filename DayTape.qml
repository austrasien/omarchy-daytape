import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import qs.Commons
import "Model.js" as Model

// A HUD tape along the left edge of the screen: the top is the start of the
// day, the bottom its end, one cell per hour, to scale. The events of the
// day sit on it as green blocks, from their start to their end, and
// hovering one opens a targeting-style data card.
//
// The events come from the NextEvent bar widget, which publishes them in
// $XDG_RUNTIME_DIR/next-event-upcoming.json, so the feeds are fetched once.
// Settings are in ~/.config/omarchy/daytape.json:
//   { "dayStart": 6, "dayEnd": 24, "calendars": ["Work"], "visible": true,
//     "monitor": "eDP-1", "railWidth": 12, "hatched": ["Perso"] }
// An empty or missing "calendars" shows every calendar; "hatched" lists the
// calendars drawn hatched instead of solid.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/daytape.json"
  readonly property string eventsPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/next-event-upcoming.json"

  // At rest only the rail shows, as wide as the gap beside the windows; the
  // hours slide out to stripWidth while the pointer is on it.
  readonly property int railWidth: cfg.railWidth || Math.max(8, Style.gapsOut * 2)   // stops short of the window border
  readonly property int stripWidth: 56
  // The widget stays out while the pointer is anywhere on it: tape or card.
  // The space Hyprland leaves beside windows: gaps_out (twice Style.gapsOut)
  // plus the 2 px border.
  readonly property int edgeGap: Style.gapsOut * 2 + 2
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  function barSizeOn(name) { return shell && shell.bar && !shell.bar.barHidden ? shell.bar.barSizeFor(name) : 0 }
  readonly property int barSize: barSizeOn(targetScreen ? targetScreen.name : "")

  // Animations stop when the user turned them off, but not for call mode,
  // which also sets Style.reduceMotion: these only run during a hover.
  // bin/callmode keeps this file while it is the one holding them off.
  property bool callModeHolds: false
  FileView {
    id: callModeFile
    path: Quickshell.env("HOME") + "/.local/state/austraz-callmode/animations"
    printErrors: false
    onLoaded: root.callModeHolds = true
    onLoadFailed: root.callModeHolds = false
  }
  Timer {
    interval: 5000
    running: Style.reduceMotion
    repeat: true
    triggeredOnStart: true
    onTriggered: callModeFile.reload()
  }
  readonly property bool animate: !Style.reduceMotion || callModeHolds
  function dur(ms) { return animate ? ms : 0 }

  // In a call: an app captures the microphone or the screen. Dictation
  // records through pw-record, which is not a call; a page probing the
  // microphone is not one either, and a call reconnecting has not ended.
  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property bool capturing: {
    for (var i = 0; i < pwNodes.length; i++) {
      var node = pwNodes[i]
      if (node && node.isStream && node.isSink === false && node.name !== "pw-record") return true
    }
    return false
  }
  property bool inCall: false
  // When the current call started; 0 out of a call.
  property real callSince: 0
  Timer {
    interval: root.capturing ? 3000 : 15000
    running: root.capturing !== root.inCall
    onTriggered: {
      root.inCall = root.capturing
      root.callSince = root.inCall ? Date.now() : 0
      root.refresh()
    }
  }

  readonly property bool open: tapeHover.hovered || pointerBlock >= 0 || cardHover.hovered || peeking

  // The hours deploy on one timeline, 0 to 1: the strip slides out, then a
  // wave leaves the pointer up and down the tape, each hour switching on as
  // it passes. Leaving runs it back at the same speed.
  property real deploy: 0
  property bool deployed: false
  property real originY: 0
  onOpenChanged: {
    if (!open) { closeDelay.restart(); return }
    closeDelay.stop()
    if (deployed) return
    deployed = true
    originY = tapeHover.hovered ? tapeHover.point.position.y : hovered ? hovered.y : nowY
    retracting.stop()
    deploying.restart()
  }
  // Going from the tape to the card flips `open` for an instant.
  Timer {
    id: closeDelay
    interval: 150
    onTriggered: {
      root.deployed = false
      root.hoveredIndex = -1
      deploying.stop()
      retracting.restart()
    }
  }
  NumberAnimation { id: deploying; target: root; property: "deploy"; to: 1; duration: root.dur(640) }
  NumberAnimation { id: retracting; target: root; property: "deploy"; to: 0; duration: root.dur(640) }

  function deploySeg(a, b) {
    var p = Math.max(0, Math.min(1, (deploy - a) / (b - a)))
    return 1 - Math.pow(1 - p, 3)
  }
  readonly property real waveTravel: (deploy - 0.1) / 0.5 * tape.height
  // How far the mark at height y has switched on: from when the wave reaches it.
  function wave(y) {
    var a = 0.1 + Math.abs(y - originY) / Math.max(1, tape.height) * 0.5
    return deploySeg(a, a + 0.25)
  }
  function hourText(hour, p) {
    if (p >= 0.75) return Model.pad(hour)
    return String(Math.floor(Math.random() * 10)) + Math.floor(Math.random() * 10)
  }
  readonly property int minBlockHeight: 8
  // Everything follows the theme: its accent and three shades of it.
  readonly property color hud: Color.accent
  readonly property color bright: Qt.tint(hud, Qt.alpha("#ffffff", 0.45))
  readonly property color dim: Qt.tint(Color.background, Qt.alpha(hud, 0.45))
  readonly property color hudBlack: Qt.darker(Color.background, 1.6)
  // The line of the current time: white on a dark theme, black on a light one.
  readonly property color nowColor: Color.background.hslLightness < 0.5 ? "#ffffff" : "#000000"

  property var rawConfig: ({})
  readonly property var cfg: Model.normalizeConfig(rawConfig)
  onCfgChanged: refresh()

  property var published: []
  property bool fileSeen: false
  property bool use12Hour: false
  property string browserCommand: ""
  property real lastUpdated: 0
  property int refreshMinutes: 0
  // The feed gets a moment to appear when the shell starts.
  property bool starting: true
  Timer { interval: 20000; running: true; onTriggered: root.starting = false }
  readonly property bool noData: !starting && (!fileSeen || Model.isStale(lastUpdated, nowMs, refreshMinutes))
  property real nowMs: Date.now()
  property real dayMs: Model.midnight(Date.now())

  // Reassigned only when the list really changes: a new list rebuilds the
  // blocks, and a block rebuilt under the pointer would lose its hover.
  property var dayEvents: []

  function refresh() {
    nowMs = Date.now()
    var day = Model.midnight(nowMs)
    if (day !== dayMs) dayMs = day
    var next = Model.eventsOfDay(published, nowMs, cfg.calendars)
    if (JSON.stringify(next) !== JSON.stringify(dayEvents)) dayEvents = next
    acknowledge(Model.joinedEvents(dayEvents, nowMs, callSince, imminentMs))
    wake.interval = Model.nextWake(nowMs, dayEvents, imminentMs, lateMs)
    wake.restart()
  }

  // Events the user has joined: no late warning for them.
  property var acked: ({})
  function acknowledge(events) {
    var next = Object.assign({}, acked)
    var changed = false
    events.forEach(function (ev) {
      var key = Model.eventKey(ev)
      if (!next[key]) { next[key] = true; changed = true }
    })
    if (changed) acked = next
  }

  // A sleep shows as a gap between beats: timers stop during one, the clock
  // does not. The last sleep is kept, for events that started during it.
  property var lastSleep: null
  property real lastBeat: Date.now()
  property var notified: ({})
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      var t = Date.now()
      if (t - root.lastBeat > 30000) root.woke(root.lastBeat, t)
      root.lastBeat = t
    }
  }
  function woke(from, to) {
    lastSleep = { from: from, to: to }
    tellMissed(Model.missedAsleep(published, lastSleep, cfg.calendars))
    refresh()
    eventsFile.reload()
  }
  // Events over before the wake have no block left to blink on.
  function tellMissed(events) {
    var fresh = events.filter(function (ev) { return !notified[Model.eventKey(ev)] })
    if (!fresh.length) return
    var next = Object.assign({}, notified)
    fresh.forEach(function (ev) { next[Model.eventKey(ev)] = true })
    notified = next
    var lines = fresh.map(function (ev) { return Model.clock(ev.start, use12Hour) + "  " + String(ev.title || "") })
    Quickshell.execDetached(["notify-send", "-a", "Day tape", "Missed while asleep", lines.join("\n")])
  }

  function take(raw) {
    try {
      var d = JSON.parse(String(raw || "{}"))
      published = Array.isArray(d.today) ? d.today : []
      fileSeen = true
      use12Hour = d.use12Hour === true
      browserCommand = String(d.browserCommand || "")
      lastUpdated = Number(d.lastUpdated) || 0
      refreshMinutes = Number(d.refreshMinutes) || 0
      refresh()
    } catch (e) {}
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.rawConfig = JSON.parse(text() || "{}") } catch (e) { console.warn("daytape: bad config", e) }
    }
  }

  FileView {
    id: eventsFile
    path: root.eventsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.take(text())
  }
  // The widget may write the file after the shell starts, and then no
  // watch is set: look often until it is there, then only as a safety net.
  Timer { interval: root.fileSeen ? 60000 : 15000; running: true; repeat: true; onTriggered: eventsFile.reload() }
  // One shot, set by refresh() for the next moment anything changes.
  Timer { id: wake; onTriggered: root.refresh() }
  Component.onCompleted: refresh()

  readonly property var range: Model.span(dayMs, cfg, dayEvents)
  readonly property real nowY: (nowMs - range.first) / Math.max(1, range.last - range.first) * tape.height
  readonly property bool nowOnTape: nowMs >= range.first && nowMs <= range.last
  readonly property var cells: Model.hourCells(range, tape.height)
  readonly property var blocks: Model.place(dayEvents, range, tape.height, minBlockHeight)

  // The block under the pointer. Held by index: a modelData object read
  // back from QML is a new object each time, so it never compares equal.
  property int hoveredIndex: -1
  // The block the pointer is on now; the card stays when it leaves the block.
  property int pointerBlock: -1
  property bool peeking: false
  readonly property var hovered: hoveredIndex >= 0 && hoveredIndex < blocks.length ? blocks[hoveredIndex] : null
  onBlocksChanged: { hoveredIndex = -1; pointerBlock = -1 }

  // Alerting blocks: from five minutes before an event until it is joined,
  // ten minutes after its start at most.
  readonly property int imminentMs: 5 * 60000
  readonly property int lateMs: 10 * 60000
  readonly property var alerts: Model.alertStates(blocks, nowMs, { imminentMs: imminentMs, lateMs: lateMs, sleep: lastSleep, acked: acked })
  readonly property bool anyAlert: alerts.some(function (a) { return a !== "" })
  readonly property bool anyWarning: anyAlert && deploy === 0
  // At rest, the enlarged block takes clicks past the rail too, up to its
  // frame; the tag leaves them to the windows underneath.
  readonly property int warningEdge: railWidth + 14
  readonly property var warningZone: Model.alertZone(blocks, anyWarning ? alerts : [], railWidth, warningEdge)
  // The tags share one clock, so that they keep their distances and cross.
  readonly property var tagPhases: Model.sweepPhases(alerts)
  property real tagClock: 0
  NumberAnimation {
    target: root
    property: "tagClock"
    from: 0
    to: 2
    duration: 2200
    loops: Animation.Infinite
    running: root.anyWarning && root.animate
  }
  property bool blinkOn: true
  Timer {
    interval: 500
    running: root.anyAlert
    repeat: true
    onTriggered: root.blinkOn = !root.blinkOn
  }

  // Opens the event's call, through the widget's browser command when it
  // has one. The link comes from the feed: web links only, and as an
  // argument, never spliced into the command.
  function hasCall(ev) { return Model.hasCall(ev) }
  function join(ev) {
    acknowledge([ev])
    if (!hasCall(ev)) return
    var open = browserCommand !== "" ? browserCommand + ' "$1" || xdg-open "$1"' : 'xdg-open "$1"'
    Quickshell.execDetached(["sh", "-c", open, "sh", String(ev.meetUrl)])
  }
  onHoveredChanged: card.track(hovered)

  readonly property var targetScreen: {
    var screens = Quickshell.screens
    var want = cfg.monitor || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    for (var i = 0; i < screens.length; i++) if (screens[i].name === want) return screens[i]
    return screens.length ? screens[0] : null
  }
  // The screens the tape is not on: they show the warnings alone.
  readonly property var otherScreens: {
    var others = []
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i] !== targetScreen) others.push(screens[i])
    return others
  }

  Variants {
    model: root.anyAlert && root.cfg.visible ? root.otherScreens : []

    PanelWindow {
      id: alertWin
      required property var modelData
      // The same blocks and alerts as the tape, placed for this screen.
      readonly property var placed: Model.place(root.dayEvents, root.range, height, root.minBlockHeight)
      readonly property var zone: Model.alertZone(placed, root.alerts, 0, root.warningEdge)

      screen: modelData
      color: "transparent"
      implicitWidth: root.stripWidth

      anchors { top: true; bottom: true; left: true }
      margins {
        top: root.barPosition === "top" ? root.barSizeOn(modelData.name) + 6 : root.edgeGap
        bottom: root.barPosition === "bottom" ? root.barSizeOn(modelData.name) + 6 : root.edgeGap
        left: root.barPosition === "left" ? root.barSizeOn(modelData.name) : 0
      }

      WlrLayershell.namespace: "austraz-daytape-alert"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      exclusiveZone: 0
      mask: Region { x: alertWin.zone.x; y: alertWin.zone.y; width: alertWin.zone.width; height: alertWin.zone.height }

      Repeater {
        model: alertWin.placed
        delegate: Rectangle {
          id: alertBlock
          required property var modelData
          required property int index
          readonly property string alert: root.alerts[index] || ""
          readonly property real laneWidth: (root.railWidth + 10) / modelData.lanes

          visible: alert !== ""
          x: 1 + modelData.lane * laneWidth
          y: modelData.y
          width: Math.max(2, laneWidth - (modelData.lanes > 1 ? 1 : 0))
          height: Math.max(2, modelData.height - 1)
          radius: 2
          color: root.blinkOn ? root.nowColor : root.hud

          Hatch { visible: Model.inCalendars(alertBlock.modelData.event, root.cfg.hatched) }
          AlertMarker {
            event: alertBlock.modelData.event
            alert: alertBlock.alert
            phase: root.tagPhases[alertBlock.index] || 0
            railEdge: 0
            blockX: alertBlock.x
          }
        }
      }
    }
  }

  PanelWindow {
    id: win
    screen: root.targetScreen
    visible: root.cfg.visible && root.targetScreen !== null
    color: "transparent"
    implicitWidth: root.stripWidth

    anchors { top: true; bottom: true; left: true }
    margins {
      // Reaching the window's top and bottom borders: deployed, the strip
      // covers them up to its edge, which then meets what is left of them.
      top: root.barPosition === "top" ? root.barSize + 1 : root.edgeGap - 2
      bottom: root.barPosition === "bottom" ? root.barSize + 1 : root.edgeGap - 2
      left: root.barPosition === "left" ? root.barSize : 0
    }

    WlrLayershell.namespace: "austraz-daytape"
    // Above fullscreen windows during a warning, not to be missed.
    WlrLayershell.layer: root.anyAlert ? WlrLayer.Overlay : WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: 0

    // At rest only the rail takes the pointer, with what a warning draws
    // past it. Deployed, the whole strip does, so the pointer can cross it to
    // the card.
    mask: Region {
      item: root.deployed ? tape : rail
      Region { x: root.warningZone.x; y: root.warningZone.y; width: root.warningZone.width; height: root.warningZone.height }
    }

    Item {
      id: tape
      // As wide as the hover: past the rail, a warning does not deploy it.
      width: root.deployed ? root.stripWidth : root.railWidth
      height: parent.height

      HoverHandler { id: tapeHover }

      Rectangle {
        id: backing
        width: root.railWidth + (root.stripWidth - root.railWidth) * root.deploySeg(0, 0.35)
        height: parent.height
        color: Color.background

        // Its edge while deployed, standing in for the window border it
        // covers; bright while it travels. At rest the real border shows.
        Rectangle {
          readonly property bool moving: root.deploy > 0 && root.deploy < 0.4
          visible: root.deploy > 0
          anchors.right: parent.right
          width: 2
          height: parent.height
          color: moving ? root.bright : root.hud
        }
      }

      Item {
        id: rail
        width: root.railWidth
        height: parent.height


        Repeater {
          model: root.cells
          delegate: Rectangle {
            required property var modelData
            x: 0
            y: modelData.y
            width: root.railWidth
            height: Math.max(1, modelData.height - 1)
            color: Qt.tint(Color.background, Qt.alpha(Color.foreground, y + height < root.nowY ? 0.05 : 0.14))

            // The half hour.
            Rectangle {
              y: parent.height / 2
              width: 4
              height: 1
              color: Qt.tint(Color.background, Qt.alpha(Color.foreground, 0.4))
            }
          }
        }

        Repeater {
          model: root.blocks
          delegate: Rectangle {
            id: block
            required property var modelData
            required property int index
            readonly property real restWidth: Math.max(2, (root.railWidth - 2) / modelData.lanes - (modelData.lanes > 1 ? 1 : 0))
            // While a warning shows, the lanes widen with it, so blocks side
            // by side stay apart.
            readonly property real laneWidth: (root.railWidth - 2 + (root.anyWarning ? 12 : 0)) / modelData.lanes
            readonly property bool live: modelData.event.start <= root.nowMs
            readonly property bool over: modelData.event.end <= root.nowMs
            readonly property bool shown: root.hoveredIndex === index

            x: 1 + modelData.lane * laneWidth
            y: modelData.y
            // At rest and about to start, the block grows out of the rail.
            readonly property string alert: root.alerts[index] || ""
            readonly property bool warning: alert !== "" && root.deploy === 0
            z: shown ? 3 : warning ? 2 : 1
            // Hovered, the block reaches out towards its card.
            width: shown ? restWidth + 6 : warning ? Math.max(2, laneWidth - (modelData.lanes > 1 ? 1 : 0)) : restWidth
            height: Math.max(2, modelData.height - 1)
            radius: 2
            // Finished events are empty outlines.
            color: shown ? root.bright : alert !== "" ? (root.blinkOn ? root.nowColor : root.hud) : over ? "transparent" : live ? root.hud : root.dim
            border.width: shown || over ? 1 : 0
            border.color: shown ? Color.foreground : root.dim

            Behavior on width { NumberAnimation { duration: root.dur(120); easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: root.dur(120) } }

            Hatch { visible: !block.over && Model.inCalendars(block.modelData.event, root.cfg.hatched) }

            AlertMarker {
              visible: block.warning
              event: block.modelData.event
              alert: block.alert
              phase: root.tagPhases[block.index] || 0
              blockX: block.x
            }

            // Hover opens the card from the rail only: the marker handles
            // what a warning draws past it.
            MouseArea {
              width: block.warning ? Math.max(0, root.railWidth - block.x) : parent.width
              height: parent.height
              hoverEnabled: true
              cursorShape: !block.over && root.hasCall(block.modelData.event) ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: if (!block.over) root.join(block.modelData.event)
              onContainsMouseChanged: {
                if (containsMouse) {
                  root.pointerBlock = block.index
                  root.hoveredIndex = block.index
                } else if (root.pointerBlock === block.index) {
                  root.pointerBlock = -1
                }
              }
            }
          }
        }
      }

      // The calendars have not been fetched for too long.
      Rectangle {
        visible: root.noData && root.deploy === 0
        x: root.railWidth + 2
        y: 2
        width: noDataText.implicitWidth + 8
        height: 15
        radius: 2
        color: root.hudBlack
        border.width: 1
        border.color: root.hud

        HudText {
          id: noDataText
          anchors.centerIn: parent
          text: "NO DATA"
          color: root.bright
          font.pixelSize: 9
          font.bold: true
        }
      }

      // One mark per hour, plus the end of the day at the very bottom.
      Repeater {
        model: root.cells
        delegate: HourMark {
          required property var modelData
          markY: modelData.y
          midY: modelData.height / 2
          hour: modelData.hour
        }
      }
      HourMark {
        markY: tape.height - 1
        last: true
        hour: new Date(root.range.last).getHours() || 24
      }

      // The wave, leaving the pointer both ways.
      WavePulse { direction: -1 }
      WavePulse { direction: 1 }

      // Now: a bright line across the rail, with the time beside it.
      Rectangle {
        visible: root.nowOnTape
        z: 3
        y: root.nowY - 1
        width: root.railWidth + 4 * root.deploySeg(0.7, 0.9)
        height: 2
        color: root.nowColor
      }
      HudText {
        visible: root.nowOnTape
        opacity: root.deploySeg(0.7, 1)
        x: root.railWidth + (root.stripWidth - root.railWidth - width) / 2 - (1 - opacity) * 12
        y: root.nowY - height / 2
        text: Model.clock(root.nowMs, root.use12Hour)
        font.pixelSize: 11
        font.bold: true
      }

      // From the hovered block to the edge, where its card starts.
      Rectangle {
        visible: card.t > 0
        z: 3
        x: root.railWidth + 9
        y: card.lineY
        width: (root.stripWidth - x) * card.seg(0, 0.18)
        height: 1
        color: root.bright
      }
    }
  }

  component HudText: Text {
    textFormat: Text.PlainText
    color: root.hud
    font.family: Style.fontFamily
    font.pixelSize: 12
  }

  // Diagonal stripes of the background over a block, whatever its colour.
  component Hatch: Image {
    anchors.fill: parent
    fillMode: Image.Tile
    source: "data:image/svg+xml," + encodeURIComponent(
      "<svg xmlns='http://www.w3.org/2000/svg' width='6' height='6'><path d='M-1 1L1 -1M0 6L6 0M5 7L7 5' stroke='"
      + Color.background + "' stroke-width='1.6'/></svg>")
  }

  // The warning on a block: a target frame round it and a tag sweeping its
  // height, like a master caution. A click on the block joins the call; the
  // tag lets the pointer through to the window underneath.
  component AlertMarker: Item {
    id: marker
    property var event: null
    property string alert: ""
    property real phase: 0
    property real blockX: 0
    property int railEdge: root.railWidth
    anchors.fill: parent

    Rectangle {
      anchors { fill: parent; topMargin: -3; bottomMargin: -3; leftMargin: -1; rightMargin: -3 }
      color: "transparent"
      radius: 2
      border.width: 1
      border.color: root.blinkOn ? root.hud : root.nowColor
    }

    MouseArea {
      x: Math.max(0, marker.railEdge - marker.blockX)
      width: Math.max(0, parent.width - x)
      height: parent.height
      cursorShape: Qt.PointingHandCursor
      onClicked: root.join(marker.event)
    }

    Rectangle {
      // Sweeps the height of the block, like an index on a scale.
      readonly property real sweep: (1 - Math.cos(Math.PI * (root.tagClock + marker.phase))) / 2

      x: 28 - marker.blockX   // one column for all the tags, past the frames
      y: -1 + Math.max(0, parent.height - height + 2) * sweep
      width: 28
      height: 18
      radius: 2
      color: root.blinkOn ? root.nowColor : root.hudBlack
      border.width: 1
      border.color: root.hud

      // Its pointer, towards the block.
      Rectangle {
        x: -3
        y: parent.height / 2 - 3
        z: -1
        width: 6
        height: 6
        rotation: 45
        color: root.hud
      }

      HudText {
        anchors.centerIn: parent
        text: marker.event ? Model.tagText(marker.event, marker.alert, root.nowMs) : ""
        color: root.blinkOn ? Color.background : root.bright
        font.pixelSize: text.length > 4 ? 9 : 10
        font.bold: true
      }
    }
  }

  // An hour on the deployed strip: its graduation, half-hour tick and label
  // grow out of the rail as the wave reaches them.
  component HourMark: Item {
    id: mark
    property real markY: 0
    property real midY: 0
    property int hour: 0
    property bool last: false
    readonly property real p: root.wave(markY)

    x: root.railWidth
    y: markY
    width: root.stripWidth - root.railWidth

    // No line at the very ends: the strip's edge joins the window's border
    // there, in an L.
    Rectangle {
      visible: mark.markY > 0 && !mark.last
      width: mark.width * mark.p
      height: 1
      color: mark.p < 1 ? root.bright : root.dim
    }
    Rectangle {
      visible: mark.midY > 0
      y: mark.midY
      width: 7 * mark.p
      height: 1
      color: root.dim
    }
    HudText {
      x: (mark.width - width) / 2 - (1 - mark.p) * 12
      y: mark.last ? -height - 1 : 2
      text: root.hourText(mark.hour, mark.p)
      color: mark.p < 1 ? root.bright : Qt.tint(Color.background, Qt.alpha(Color.foreground, 0.75))
      opacity: root.nowOnTape && Math.abs(mark.markY + 9 - root.nowY) <= 12 ? 0 : mark.p
      font.pixelSize: 11
    }
  }

  // A front of the wave: a bright line with its trail behind it.
  component WavePulse: Rectangle {
    id: pulse
    property int direction: 1

    visible: root.deployed && root.deploy > 0.1 && y >= 0 && y <= tape.height
    x: root.railWidth
    y: root.originY + direction * root.waveTravel
    width: backing.width - root.railWidth
    height: 2
    color: root.bright
    opacity: 1 - root.deploySeg(0.5, 0.7)

    Rectangle {
      y: pulse.direction > 0 ? -height : pulse.height
      width: parent.width
      height: 36
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.alpha(root.hud, pulse.direction > 0 ? 0 : 0.45) }
        GradientStop { position: 1; color: Qt.alpha(root.hud, pulse.direction > 0 ? 0.45 : 0) }
      }
    }
  }

  // One corner of the targeting frame.
  component Bracket: Item {
    property bool onRight: false
    property bool onBottom: false
    width: 16
    height: 16
    Rectangle {
      x: 0
      y: parent.onBottom ? parent.height - 2 : 0
      width: parent.width
      height: 2
      color: root.bright
    }
    Rectangle {
      x: parent.onRight ? parent.width - 2 : 0
      y: 0
      width: 2
      height: parent.height
      color: root.bright
    }
  }

  // A graduated line, like the scale of a HUD tape.
  component ScaleLine: Item {
    id: scale
    width: parent.width
    height: 5
    Rectangle { width: parent.width; height: 1; color: root.dim }
    Repeater {
      model: 25
      delegate: Rectangle {
        required property int index
        x: index * (scale.width - 1) / 24
        y: 1
        width: 1
        height: index % 4 === 0 ? 4 : 2
        color: root.dim
      }
    }
  }

  // Text the card types out word by word. It keeps the size of the whole
  // text from the start, so the card does not grow as the words come.
  component TypedText: HudText {
    id: typedText
    property int order: 0
    property color shownColor: root.bright
    color: "transparent"
    wrapMode: Text.Wrap
    elide: Text.ElideRight

    HudText {
      width: parent.width
      text: card.typedText(typedText.order)
      color: typedText.shownColor
      font: typedText.font
      wrapMode: typedText.wrapMode
      elide: typedText.elide
      maximumLineCount: typedText.maximumLineCount
    }
  }

  // A label on the left, its reading on the right. Hidden when empty.
  component DataRow: Row {
    id: dataRow
    property string key: ""
    property int order: 0
    readonly property string value: card.typeTexts[order] || ""
    property string copyText: value   // what a click puts in the clipboard
    property int lines: 2
    visible: value !== ""
    width: parent.width
    spacing: 8
    TapHandler { onTapped: card.copy(dataRow.key, dataRow.copyText) }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    HudText {
      width: 44
      text: dataRow.key
      color: root.dim
      font.bold: true
    }
    TypedText {
      width: dataRow.width - 52
      text: dataRow.value
      order: dataRow.order
      shownColor: card.flashKey === dataRow.key && !card.flashOn ? root.nowColor : root.bright
      maximumLineCount: dataRow.lines
    }
  }

  // ------------------------------------------------------ the data card
  //
  // Opens like a target lock, on one timeline `t` from 0 to 1: the leader
  // shoots out of the block, the panel wipes open from it, the corner
  // brackets close in and blink, a scan line paints the content while the
  // text types out word by word behind a block cursor, on a worn VHS picture,
  // and a flash marks the lock. Closing runs it back, fast.

  PopupWindow {
    id: card

    property var ev: null        // kept through the closing animation
    property string target: ""
    property int lineY: 0
    property real t: 0
    property real spin: 0        // what is left of the reticle's turn, 1 to 0
    property real spinFrom: 180  // the angle it starts from, drawn at each lock
    property int spinMs: 1200    // how long it turns, drawn at each lock

    readonly property int pad: 24   // room around the panel for the brackets
    readonly property bool live: !!ev && ev.start <= root.nowMs
    readonly property bool locked: t >= 0.75
    readonly property string details: ev ? Model.plainDescription(ev.description) : ""

    // What the card types, in order: title, time, duration, calendar, link,
    // place, brief.
    readonly property var typeTexts: ev ? [
      String(ev.title || ""),
      Model.clock(ev.start, root.use12Hour) + " – " + Model.clock(ev.end, root.use12Hour),
      Model.duration(ev.end - ev.start).toUpperCase(),
      String(ev.label || "").toUpperCase(),
      ev.meetUrl ? "VISIO" : "",
      Model.maskSecrets(ev.location),
      details
    ] : []
    readonly property var typing: Model.typingPlan(typeTexts)
    // How many words are out, across all the texts.
    property real typed: 0
    // Whole words: the texts change only when this does.
    readonly property int typedCount: Math.floor(typed)
    readonly property bool typingDone: typedCount >= typing.total
    // A word every 45 ms, within 1.6 s however long the brief is.
    readonly property int typingMs: Math.min(1600, typing.total * 45)
    // The cursor sits still while typing, and blinks once done.
    property bool cursorOn: true
    Timer {
      interval: 450
      repeat: true
      running: card.visible && card.typingDone && card.t > 0
      onRunningChanged: card.cursorOn = true
      onTriggered: card.cursorOn = !card.cursorOn
    }
    function typedText(order) {
      var text = Model.typedWords(typeTexts[order] || "", typing, order, typedCount)
      if (order !== Model.cursorItem(typing, typedCount)) return text
      return text + (cursorOn ? " █" : "")
    }

    // Progress of the part of the timeline from a to b, eased.
    function seg(a, b) {
      var p = Math.max(0, Math.min(1, (t - a) / (b - a)))
      return 1 - Math.pow(1 - p, 3)
    }

    readonly property real spread: (1 - seg(0.3, 0.6)) * (pad - 2)
    // Hidden, then closing in, then two blinks as it locks.
    readonly property real bracketOpacity: t < 0.3 ? 0
      : (t > 0.62 && t < 0.66) || (t > 0.7 && t < 0.74) ? 0.15 : 1

    function reanchor() { if (visible) anchor.updateAnchor() }

    // A click on an element copies it and makes it blink three times. Through
    // wl-copy: setting the clipboard from the shell needs keyboard focus,
    // which the card never has.
    property string flashKey: ""
    property bool flashOn: true
    property int flashStep: 0
    function copy(key, text) {
      var value = String(text || "")
      if (value === "") return
      Quickshell.execDetached(["wl-copy", "--", value])
      flashKey = key
      flashOn = false
      flashStep = 1
      flashTimer.restart()
    }
    Timer {
      id: flashTimer
      interval: 100
      repeat: true
      onTriggered: {
        card.flashOn = !card.flashOn
        card.flashStep++
        if (card.flashStep >= 6) {
          stop()
          card.flashOn = true
          card.flashKey = ""
        }
      }
    }

    function track(block) {
      if (block) {
        closing.stop()
        opening.stop()
        spinFrom = 70 + Math.random() * 220   // never near upright: always a turn to see
        spinMs = 600 + Math.random() * 1200   // 1.2 s, give or take half
        ev = block.event
        target = Model.targetLabel(root.blocks, root.hoveredIndex, root.nowMs)
        lineY = Math.round(block.y + block.height / 2)
        t = 0
        typed = 0
        reanchor()
        opening.restart()
      } else if (ev) {
        opening.stop()
        closing.restart()
      }
    }

    // The content paints at full speed, then the timeline holds just short
    // of the lock until the reticle has finished its slow turn.
    readonly property int paintMs: 533
    ParallelAnimation {
      id: opening
      NumberAnimation { target: card; property: "spin"; from: 1; to: 0; duration: root.dur(card.spinMs) }
      SequentialAnimation {
        PauseAnimation { duration: root.dur(250) }
        NumberAnimation { target: card; property: "typed"; from: 0; to: card.typing.total; duration: root.dur(card.typingMs) }
      }
      SequentialAnimation {
        NumberAnimation { target: card; property: "t"; to: 0.74; duration: root.dur(card.paintMs) }
        PauseAnimation { duration: root.dur(card.spinMs - card.paintMs) }
        NumberAnimation { target: card; property: "t"; to: 1; duration: root.dur(187) }
      }
    }
    NumberAnimation { id: closing; target: card; property: "t"; to: 0; duration: root.dur(140) }

    visible: win.visible && ev !== null && (root.hovered !== null || t > 0)
    color: "transparent"
    implicitWidth: 384 + 2 * pad
    // Whole physical pixels at fractional scales (see the minimap's Popover).
    implicitHeight: Math.ceil((body.implicitHeight + 36 + 2 * pad) / 4) * 4
    onImplicitHeightChanged: reanchor()
    mask: Region { item: panel }

    anchor {
      window: win
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1
      onAnchoring: {
        card.anchor.rect.x = root.stripWidth - card.pad
        card.anchor.rect.y = card.lineY - 22 - card.pad
      }
    }

    Item {
      id: panel
      x: card.pad
      y: card.pad
      width: parent.width - 2 * card.pad
      height: parent.height - 2 * card.pad

      HoverHandler { id: cardHover }

      Item {
        id: wipe
        width: panel.width * card.seg(0.1, 0.4)
        height: panel.height
        clip: true

        Rectangle {
          width: panel.width
          height: panel.height
          color: root.hudBlack
          border.width: 1
          border.color: root.dim
        }

        // CRT lines across the panel: one tile, repeated.
        Image {
          width: panel.width
          height: panel.height
          fillMode: Image.Tile
          verticalAlignment: Image.AlignTop
          horizontalAlignment: Image.AlignLeft
          source: "data:image/svg+xml," + encodeURIComponent(
            "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'><rect width='4' height='1' fill='"
            + root.hud + "' fill-opacity='0.07'/></svg>")
        }

        // The content, painted down as the scan line passes.
        Item {
          id: painted
          width: panel.width
          height: panel.height * card.seg(0.35, 0.85)
          clip: true

          Column {
            id: body
            x: 18
            y: 18
            width: panel.width - 36
            spacing: 7

            Item {
              width: parent.width
              height: tgt.implicitHeight
              HudText {
                id: tgt
                text: "◆ " + card.target
                font.bold: true
              }
              HudText {
                anchors.right: parent.right
                text: !card.locked ? "ACQUIRING"
                  : !card.ev ? "" : card.ev.end <= root.nowMs ? "ENDED" : card.live ? "ACTIVE" : "T-" + Model.countdown(card.ev.start - root.nowMs)
                color: root.bright
                opacity: card.locked || Math.floor(card.t * 24) % 2 ? 1 : 0.3
                font.bold: true
              }
            }

            ScaleLine {}

            TypedText {
              width: parent.width - 54
              text: card.typeTexts[0] || ""
              order: 0
              TapHandler { onTapped: card.copy("TITLE", card.ev ? card.ev.title : "") }
              HoverHandler { cursorShape: Qt.PointingHandCursor }
              shownColor: card.flashKey === "TITLE" && !card.flashOn ? root.nowColor : root.bright
              font.pixelSize: 15
              font.bold: true
              font.capitalization: Font.AllUppercase
              maximumLineCount: 3
            }

            DataRow { key: "TIME"; order: 1 }
            DataRow { key: "DUR"; order: 2 }
            DataRow { key: "CAL"; order: 3 }
            DataRow {
              key: "LINK"
              order: 4
              copyText: card.ev ? card.ev.meetUrl || "" : ""
            }
            DataRow {
              key: "LOC"
              order: 5
              copyText: card.ev ? card.ev.location || "" : ""
            }

            ScaleLine { visible: card.details !== "" }

            DataRow { key: "BRIEF"; order: 6; lines: 8 }
          }

          // The reticle spins down onto the target and stops at the lock.
          Item {
            x: panel.width - 18 - width
            y: 44
            width: 44
            height: 44
            scale: 1 + (1 - card.seg(0.3, 0.75)) * 0.6

            Item {
              anchors.fill: parent
              rotation: card.spin * card.spinFrom

              Rectangle {
                anchors.fill: parent
                anchors.margins: 6
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: root.bright
              }
              Rectangle { x: parent.width / 2; y: 0; width: 1; height: 12; color: root.bright }
              Rectangle { x: parent.width / 2; y: parent.height - 12; width: 1; height: 12; color: root.bright }
              Rectangle { x: 0; y: parent.height / 2; width: 12; height: 1; color: root.bright }
              Rectangle { x: parent.width - 12; y: parent.height / 2; width: 12; height: 1; color: root.bright }
              Rectangle { x: parent.width / 2 - 3; y: 3; width: 7; height: 3; color: root.bright }
            }

            Rectangle {
              anchors.centerIn: parent
              width: 12
              height: 12
              color: "transparent"
              border.width: 1
              border.color: root.hud
              rotation: 45 - card.spin * card.spinFrom * 0.75
            }
            Rectangle { anchors.centerIn: parent; width: 3; height: 3; color: root.bright }
          }
        }

        // Worn tape: dark lines across everything, text included.
        Image {
          width: panel.width
          height: panel.height
          fillMode: Image.Tile
          verticalAlignment: Image.AlignTop
          horizontalAlignment: Image.AlignLeft
          source: "data:image/svg+xml," + encodeURIComponent(
            "<svg xmlns='http://www.w3.org/2000/svg' width='3' height='3'><rect width='3' height='1' fill='"
            + root.hudBlack + "' fill-opacity='0.6'/></svg>")
        }

        // The scan line and its trail.
        Rectangle {
          visible: card.t > 0.35 && card.t < 0.74
          y: painted.height - height
          width: panel.width
          height: 34
          gradient: Gradient {
            GradientStop { position: 0; color: Qt.alpha(root.hud, 0) }
            GradientStop { position: 1; color: Qt.alpha(root.hud, 0.4) }
          }
          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 2
            color: root.bright
          }
        }

        // The flash of the lock.
        Rectangle {
          width: panel.width
          height: panel.height
          color: root.bright
          opacity: card.locked ? (1 - card.seg(0.75, 1)) * 0.3 : 0
        }
      }

      // The bright front edge of the wipe.
      Rectangle {
        visible: card.t > 0.1 && card.t < 0.42
        x: wipe.width - 1
        width: 2
        height: panel.height
        color: root.bright
      }

      Bracket { x: -card.spread; y: -card.spread; opacity: card.bracketOpacity }
      Bracket { x: panel.width - width + card.spread; y: -card.spread; onRight: true; opacity: card.bracketOpacity }
      Bracket { x: -card.spread; y: panel.height - height + card.spread; onBottom: true; opacity: card.bracketOpacity }
      Bracket { x: panel.width - width + card.spread; y: panel.height - height + card.spread; onRight: true; onBottom: true; opacity: card.bracketOpacity }
    }
  }

  IpcHandler {
    target: "austraz.daytape"

    function toggle(): void {
      var next = Object.assign({}, root.rawConfig, { visible: !root.cfg.visible })
      root.rawConfig = next
      configFile.setText(JSON.stringify(next, null, 2) + "\n")
    }
    // Show the card of block <index> as a hover would; -1 closes it.
    function peek(index: int): void {
      root.hoveredIndex = index
      root.peeking = index >= 0
    }
    // Act as if the machine had slept for the last <minutes>, for checking.
    function slept(minutes: int): void {
      var now = Date.now()
      root.woke(now - minutes * 60000, now)
    }
    // What the tape holds, for diagnosis.
    function state(): string {
      return JSON.stringify({ first: root.range.first, last: root.range.last, blocks: root.blocks.length, hovered: root.hoveredIndex, deploy: root.deploy, animate: root.animate, rail: root.railWidth, wake: wake.interval, alerts: root.alerts, inCall: root.inCall, noData: root.noData })
    }
  }
}
