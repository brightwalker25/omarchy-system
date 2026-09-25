import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The panel scaffolding here -- the open/close and IPC contract, and the Meter
// component -- is derived from Omarchy's `omarchy.weather` and `omarchy.agents`
// plugins (https://github.com/basecamp/omarchy, MIT, Copyright (c) David
// Heinemeier Hansson). See LICENSE for the full notice.

// The panel behind the bar glyph: thermals, load, storage, network and power.
//
// It renders whatever `bin/system-collect` hands it and discovers nothing
// itself. Every machine-specific quirk -- which sensors exist, whether a
// threshold is real, whether a battery is a stylus -- is settled in that
// script, which runs fine from a terminal with no compositor involved.
//
// Rates are derived here rather than there. The collector is stateless and
// never sleeps, so cumulative counters arrive raw beside a monotonic
// timestamp and two consecutive snapshots make a rate.
Panel {
  id: root
  moduleName: "brightwalker25.system"
  ipcTarget: "brightwalker25.system"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // the popout coordinator has to be handed that widget as the identity.
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int refreshMs: Math.max(500, Number(setting("refreshIntervalMs", 2000)))
  readonly property int perCoreCutoff: Math.max(0, Number(setting("perCoreCutoff", 8)))
  readonly property int maxSensorRows: Math.max(3, Number(setting("maxSensorRows", 4)))
  readonly property int maxFilesystemRows: Math.max(1, Number(setting("maxFilesystemRows", 4)))
  readonly property real diskAlarmFraction: root.clamp(Number(setting("diskAlarmPercent", 90)) / 100, 0.5, 0.99)
  // How often the collector runs for the bar tint while the panel is closed.
  readonly property int barRefreshMs: Math.max(15000, Number(setting("barRefreshIntervalMs", 60000)))

  // The newest snapshot, and the one before it. `prev` is what makes rates
  // possible, and is dropped whenever it cannot honestly be compared.
  property var snap: null
  property var prev: null
  property string error: ""

  // ---------------------------------------------------------------- plumbing

  // The collector ships inside the plugin, so it is found relative to this
  // file rather than through PATH. That deliberately avoids the ~/.local/bin
  // symlink step, which is the kind of out-of-tree install detail that gets
  // forgotten on the next machine.
  readonly property string collector: String(Qt.resolvedUrl("bin/system-collect")).replace(/^file:\/\//, "")

  function poll() {
    if (proc.running) return
    proc.running = true
  }

  function ingest(text) {
    var parsed = null
    try {
      parsed = JSON.parse(String(text))
    } catch (e) {
      root.error = "Could not parse collector output"
      return
    }
    if (!parsed || typeof parsed !== "object") return
    root.error = ""
    // Only keep the old snapshot when the clock actually moved forward. A
    // monotonic timestamp that did not advance gives a zero-length interval,
    // and one that went backwards means the machine rebooted between polls;
    // deltas across either are noise presented as a rate.
    root.prev = (root.snap && parsed.monotonic > root.snap.monotonic) ? root.snap : null
    root.snap = parsed
  }

  Process {
    id: proc
    command: [root.collector]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingest(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") root.error = t
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.error === "")
        root.error = "Collector exited " + exitCode
    }
  }

  // Polls every couple of seconds while the panel is open, for the live
  // figures.
  Timer {
    running: root.opened
    interval: root.refreshMs
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // Polls once a minute while it is closed, only to keep the bar tint
  // honest. The collector reads /proc and /sys and takes a fraction of a
  // second, so this costs nothing measurable.
  Timer {
    running: !root.opened
    interval: root.barRefreshMs
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // ok, warn or bad for the bar glyph, from the same limits the panel draws
  // in the urgent colour. Red is what the panel already alarms on: a sensor
  // at 90% of its own critical limit, a filesystem past the disk alarm,
  // under 5% of memory available, or a battery at 15% and not charging.
  // Amber is the approach to each (80%, five points short of the alarm,
  // under 10%, 25%), or a collector that could not be read.
  readonly property string barStatus: {
    if (root.error !== "" || !root.snap) return root.error !== "" ? "warn" : ""
    var worst = 0
    function note(level) { if (level > worst) worst = level }
    var t = root.snap.thermal
    var sensors = (t && t.governed) ? t.governed : []
    for (var i = 0; i < sensors.length; i++) {
      var f = sensors[i].critFraction || 0
      note(f >= 0.9 ? 2 : (f >= 0.8 ? 1 : 0))
    }
    var fss = root.snap.filesystems || []
    for (var j = 0; j < fss.length; j++) {
      var u = fss[j].usedFraction || 0
      note(u >= root.diskAlarmFraction ? 2 : (u >= root.diskAlarmFraction - 0.05 ? 1 : 0))
    }
    var m = root.snap.memory
    if (m && m.totalKb > 0) {
      var avail = (m.availableKb || 0) / m.totalKb
      note(avail < 0.05 ? 2 : (avail < 0.10 ? 1 : 0))
    }
    var bats = root.batteryRows
    for (var k = 0; k < bats.length; k++) {
      if (bats[k].state === "Charging") continue
      var pct = bats[k].percent === undefined ? 100 : bats[k].percent
      note(pct <= 15 ? 2 : (pct <= 25 ? 1 : 0))
    }
    return worst === 2 ? "bad" : (worst === 1 ? "warn" : "ok")
  }

  // ----------------------------------------------------------------- derived

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // /proc/stat order is user, nice, system, idle, iowait, irq, softirq, steal,
  // guest, guest_nice. Idle time is idle plus iowait: a core waiting on disk
  // is not doing work, and counting it as busy makes an idle machine look hot.
  function jiffySplit(arr) {
    var total = 0
    for (var i = 0; i < arr.length; i++) total += arr[i]
    return { total: total, busy: total - ((arr[3] || 0) + (arr[4] || 0)) }
  }

  function busyRatio(now, before) {
    if (!now || !before) return -1
    var a = jiffySplit(now)
    var b = jiffySplit(before)
    var span = a.total - b.total
    if (span <= 0) return -1
    return clamp((a.busy - b.busy) / span, 0, 1)
  }

  readonly property real cpuBusy: {
    if (!snap || !snap.cpu || !prev || !prev.cpu) return -1
    return busyRatio(snap.cpu.totalJiffies, prev.cpu.totalJiffies)
  }

  readonly property var coreBusy: {
    var out = []
    if (!snap || !snap.cpu || !snap.cpu.perCoreJiffies) return out
    var before = ({})
    if (prev && prev.cpu && prev.cpu.perCoreJiffies)
      for (var i = 0; i < prev.cpu.perCoreJiffies.length; i++)
        before[prev.cpu.perCoreJiffies[i].cpu] = prev.cpu.perCoreJiffies[i].jiffies
    for (var j = 0; j < snap.cpu.perCoreJiffies.length; j++) {
      var e = snap.cpu.perCoreJiffies[j]
      out.push({ name: e.cpu, ratio: busyRatio(e.jiffies, before[e.cpu]) })
    }
    return out
  }

  readonly property real interval: (snap && prev && snap.monotonic > prev.monotonic)
                                   ? (snap.monotonic - prev.monotonic) : 0

  readonly property var netRates: {
    var out = []
    if (!snap || !snap.net) return out
    var before = ({})
    if (prev && prev.net)
      for (var i = 0; i < prev.net.length; i++) before[prev.net[i].iface] = prev.net[i]
    for (var j = 0; j < snap.net.length; j++) {
      var n = snap.net[j]
      var b = before[n.iface]
      var ok = root.interval > 0 && b !== undefined
      out.push({
        iface: n.iface,
        up: n.operstate === "up",
        wireless: n.wireless === true,
        // Counters are 64-bit but can still reset when an interface is
        // re-created, so a negative delta is dropped rather than shown.
        rx: ok ? Math.max(0, n.rxBytes - b.rxBytes) / root.interval : -1,
        tx: ok ? Math.max(0, n.txBytes - b.txBytes) / root.interval : -1
      })
    }
    return out
  }

  // Whether the two headline sensors are in fact one sensor. On a machine with
  // a single dominant heat source -- a fanless one, typically -- the hottest
  // reading and the reading closest to its own limit are the same row, and
  // printing it twice spends a line saying nothing.
  readonly property bool heroSensorsCoincide: {
    if (!snap || !snap.thermal) return false
    var h = snap.thermal.hottest, c = snap.thermal.closestToLimit
    return !!h && !!c && h.label === c.label && h.chip === c.chip
           && h.instance === c.instance
  }

  // Two chips of the same name -- two NVMe drives, say -- publish the same
  // labels, so "Composite  nvme" would name two different sensors. The
  // collector sends an instance only where it is needed to tell them apart.
  function sensorName(s) {
    if (!s) return ""
    return s.label + "  " + s.chip + (s.instance ? " " + s.instance : "")
  }

  // Governed sensors, hottest share of their own budget first, trimmed to a
  // readable number. Twenty coretemp rows is not a panel, it is a log file.
  readonly property var governedRows: {
    if (!snap || !snap.thermal || !snap.thermal.governed) return []
    var all = snap.thermal.governed.slice()
    all.sort(function(a, b) { return (b.critFraction || 0) - (a.critFraction || 0) })
    return all.slice(0, root.maxSensorRows)
  }

  readonly property string governedRemainder: {
    if (!snap || !snap.thermal || !snap.thermal.governed) return ""
    var all = snap.thermal.governed
    var hidden = all.length - root.governedRows.length
    if (hidden <= 0) return ""
    var sorted = all.slice().sort(function(a, b) { return (b.critFraction || 0) - (a.critFraction || 0) })
    var lo = Infinity, hi = -Infinity
    for (var i = root.governedRows.length; i < sorted.length; i++) {
      lo = Math.min(lo, sorted[i].celsius)
      hi = Math.max(hi, sorted[i].celsius)
    }
    return hidden + " more between " + fmtTemp(lo) + " and " + fmtTemp(hi)
  }

  readonly property var ambientRows: (snap && snap.thermal && snap.thermal.ambient) ? snap.thermal.ambient : []
  readonly property var fanRows: (snap && snap.fans) ? snap.fans : []

  // With no readable rpm the section still has something to say, because
  // "no fan" and "a fan this machine will not let us read" look identical
  // from an empty list and are not the same fact. The collector reports
  // which one it found; anything unrecognised stays silent rather than
  // guessing.
  readonly property string fanNote: {
    if (root.fanRows.length > 0) return ""
    var why = snap ? snap.fanReporting : ""
    if (why === "none") return "no fan"
    if (why === "declared") return "fan present, speed not published"
    if (why === "vendor") return "fan present, no driver reporting speed"
    return ""
  }
  readonly property var batteryRows: (snap && snap.power && snap.power.batteries) ? snap.power.batteries : []

  // Filesystems, fullest first after the root, trimmed the same way the
  // sensor rows are. The collector has already collapsed the several mounts
  // of one filesystem into a single row, so what arrives here is one row per
  // filesystem and every row is a different number.
  readonly property var filesystemRows: {
    if (!snap || !snap.filesystems) return []
    var all = snap.filesystems.slice()
    all.sort(function(a, b) {
      if ((a.mountpoint === "/") !== (b.mountpoint === "/")) return a.mountpoint === "/" ? -1 : 1
      return (b.usedFraction || 0) - (a.usedFraction || 0)
    })
    return all.slice(0, root.maxFilesystemRows)
  }

  readonly property string filesystemRemainder: {
    if (!snap || !snap.filesystems) return ""
    var hidden = snap.filesystems.length - root.filesystemRows.length
    if (hidden <= 0) return ""
    var shown = ({})
    for (var i = 0; i < root.filesystemRows.length; i++) shown[root.filesystemRows[i].mountpoint] = true
    var free = 0
    for (var j = 0; j < snap.filesystems.length; j++)
      if (!shown[snap.filesystems[j].mountpoint]) free += snap.filesystems[j].freeBytes
    return hidden + (hidden === 1 ? " more filesystem, " : " more filesystems, ") + root.fmtBytes(free) + " free between them"
  }

  readonly property var diskRows: (snap && snap.disks) ? snap.disks : []

  // -------------------------------------------------------------- formatting

  function fmtBytes(n) {
    if (n === undefined || n === null || n < 0 || !isFinite(n)) return "—"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (i > 0 && n < 10 ? n.toFixed(1) : Math.round(n)) + " " + units[i]
  }

  function fmtRate(n) { return n < 0 ? "—" : fmtBytes(n) + "/s" }
  function fmtKb(kb) { return fmtBytes(kb * 1024) }

  function fmtTemp(c) {
    if (c === undefined || c === null || !isFinite(c)) return "—"
    return c.toFixed(1) + " °C"
  }

  function fmtPct(ratio) {
    if (ratio === undefined || ratio === null || ratio < 0) return "—"
    return Math.round(ratio * 100) + "%"
  }

  // ------------------------------------------------------- open/close contract

  property bool openedFromHotkey: false

  function open() {
    openedFromHotkey = false
    root.controller.show()
    root.poll()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.poll()
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      root.bar.switchPanelFrom(root.barIdentity, direction)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.poll() }
  }

  // ------------------------------------------------------------- components

  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground
      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
  }

  // Label on the left, value on the right, both on one baseline.
  component StatRow: Item {
    id: statRow
    property string label: ""
    property string value: ""
    property bool muted: false
    implicitHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)

    Text {
      id: statLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      // Leave the value room to sit unelided; a truncated temperature is
      // worse than a truncated sensor name.
      width: statRow.width - statValue.width - Style.spacing.controlGap
      elide: Text.ElideRight
      text: statRow.label
      color: statRow.muted ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: statValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: statRow.value
      color: statRow.muted ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  // A sensor with a real threshold: name, meter against its own crit, and the
  // reading with the headroom left.
  component SensorRow: Column {
    id: sensorRow
    property var sensor: null
    spacing: Style.spacing.xxs

    StatRow {
      width: parent.width
      label: root.sensorName(sensorRow.sensor)
      value: sensorRow.sensor ? (root.fmtTemp(sensorRow.sensor.celsius) + "   "
                                 + root.fmtTemp(sensorRow.sensor.headroomC) + " left") : ""
    }

    Meter {
      width: parent.width
      value: sensorRow.sensor ? (sensorRow.sensor.critFraction || 0) : 0
      // Past 90% of its own crit the hardware is about to throttle, which is
      // the one thermal fact worth colouring differently.
      alarming: sensorRow.sensor ? (sensorRow.sensor.critFraction || 0) >= 0.9 : false
    }
  }

  // One filesystem: what it is, how much of it is gone, and what is left,
  // each as a figure and as a share of the whole. A percentage alone does
  // not say whether 8% free is 30 GB or 300 MB, and a figure alone does not
  // say whether 30 GB is comfortable, so neither is shown without the other.
  component FilesystemRow: Column {
    id: fsRow
    property var fs: null
    // Reserved blocks are real but small, and only worth a line when they
    // are large enough to make used% and free% visibly fail to sum to 100.
    readonly property bool reservedWorthSaying: fs && fs.sizeBytes > 0
                                                && (fs.reservedBytes || 0) / fs.sizeBytes >= 0.005
    spacing: Style.spacing.xxs

    StatRow {
      width: parent.width
      label: fsRow.fs ? (fsRow.fs.mountpoint + "  " + (fsRow.fs.fstype || "")) : ""
      value: fsRow.fs ? (root.fmtBytes(fsRow.fs.usedBytes) + " of " + root.fmtBytes(fsRow.fs.sizeBytes)) : ""
    }

    Meter {
      width: parent.width
      value: fsRow.fs ? (fsRow.fs.usedFraction || 0) : 0
      alarming: fsRow.fs ? (fsRow.fs.usedFraction || 0) >= root.diskAlarmFraction : false
    }

    StatRow {
      width: parent.width
      label: fsRow.fs ? (root.fmtPct(fsRow.fs.usedFraction) + " used") : ""
      value: fsRow.fs ? (root.fmtBytes(fsRow.fs.freeBytes) + " free   " + root.fmtPct(fsRow.fs.freeFraction)) : ""
      muted: true
    }

    StatRow {
      width: parent.width
      visible: fsRow.reservedWorthSaying
      label: "reserved for root"
      value: fsRow.fs ? root.fmtBytes(fsRow.fs.reservedBytes) : ""
      muted: true
    }

    // Running out of inodes fills a filesystem that still shows free bytes,
    // so it is said only when it is close enough to matter.
    StatRow {
      width: parent.width
      visible: fsRow.fs !== null && fsRow.fs.inodesUsedFraction !== undefined
               && fsRow.fs.inodesUsedFraction >= 0.8
      label: "inodes"
      value: fsRow.fs ? (root.fmtPct(fsRow.fs.inodesUsedFraction) + " used") : ""
      muted: true
    }
  }

  // Per-thread load where the machine has few enough threads to name them.
  component CoreBars: Column {
    id: coreBars
    property var cores: []
    spacing: Style.spacing.xs

    Repeater {
      model: coreBars.cores
      delegate: Column {
        required property var modelData
        width: coreBars.width
        spacing: Style.spacing.xxs
        StatRow {
          width: parent.width
          label: modelData.name
          value: root.fmtPct(modelData.ratio)
          muted: true
        }
        Meter { width: parent.width; value: modelData.ratio }
      }
    }
  }

  // Per-thread load where naming them would be unreadable. One column per
  // thread, filled from the bottom: the shape of the load is legible at a
  // glance even at twenty threads, where twenty labelled bars are not.
  component CoreStrip: Item {
    id: strip
    property var cores: []
    readonly property int count: cores ? cores.length : 0
    implicitHeight: Style.space(34)

    Row {
      id: stripRow
      anchors.fill: parent
      spacing: Math.max(1, Style.space(2))

      Repeater {
        model: strip.cores
        delegate: Item {
          required property var modelData
          height: stripRow.height
          width: (stripRow.width - stripRow.spacing * Math.max(0, strip.count - 1)) / Math.max(1, strip.count)

          Rectangle {
            anchors.fill: parent
            radius: Math.min(width, Style.space(2))
            color: root.track
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            radius: Math.min(width, Style.space(2))
            height: parent.height * root.clamp(modelData.ratio, 0, 1)
            color: modelData.ratio >= 0.9 ? root.urgent : root.foreground
            Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
          }
        }
      }
    }
  }

  component SectionHeading: Column {
    id: heading
    property string title: ""
    spacing: Style.spacing.sm
    PanelSeparator { width: heading.width; foreground: root.foreground }
    PanelSectionHeader {
      text: heading.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  // ------------------------------------------------------------------ layout

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: flick.width
          spacing: Style.spacing.lg

          // ---- Hero: the hottest thing in the machine, and the thing closest
          // to its own limit. Usually different sensors, so both are shown
          // rather than one being picked; when they coincide the two captions
          // collapse into one rather than repeating the sensor.
          Column {
            width: parent.width
            spacing: Style.spacing.xxs
            visible: root.snap && root.snap.thermal && root.snap.thermal.hottest

            Text {
              text: root.snap && root.snap.thermal && root.snap.thermal.hottest
                    ? root.fmtTemp(root.snap.thermal.hottest.celsius) : "—"
              color: root.foreground
              font.family: root.fontFamily
              // Hero read-out, deliberately outside the Style.font.* scale.
              font.pixelSize: 36
              font.bold: true
            }

            Text {
              text: {
                var t = root.snap ? root.snap.thermal : null
                var h = t ? t.hottest : null
                if (!h) return ""
                if (!root.heroSensorsCoincide)
                  return "hottest — " + h.label + " (" + h.chip
                         + (h.instance ? " " + h.instance : "") + ", " + h.class + ")"
                // Closest to its limit implies governed, so the class is dropped.
                var c = t.closestToLimit
                return "hottest, and closest to limit — " + h.label + " (" + h.chip
                       + (h.instance ? " " + h.instance : "")
                       + ") at " + root.fmtPct(c.critFraction) + " of " + root.fmtTemp(c.critC)
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: text !== ""
              text: {
                if (root.heroSensorsCoincide) return ""
                var c = root.snap && root.snap.thermal ? root.snap.thermal.closestToLimit : null
                if (!c) return ""
                return "closest to limit — " + c.label + " at " + root.fmtPct(c.critFraction)
                       + " of " + root.fmtTemp(c.critC)
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Thermals
          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.governedRows.length > 0 || root.ambientRows.length > 0

            SectionHeading { width: parent.width; title: "THERMALS" }

            Column {
              width: parent.width
              spacing: Style.spacing.md
              Repeater {
                model: root.governedRows
                delegate: SensorRow {
                  required property var modelData
                  width: parent.width
                  sensor: modelData
                }
              }
            }

            Text {
              visible: root.governedRemainder !== ""
              text: root.governedRemainder
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Ambient sensors publish no threshold, so there is no meter to
            // draw. A raw reading is the only honest thing to show.
            Column {
              width: parent.width
              spacing: Style.spacing.xs
              visible: root.ambientRows.length > 0

              Text {
                text: "No published limit"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.ambientRows
                delegate: StatRow {
                  required property var modelData
                  width: parent.width
                  label: root.sensorName(modelData)
                  value: root.fmtTemp(modelData.celsius)
                  muted: true
                }
              }
            }

            // Shown whenever there is either a speed or a reason there is
            // none; silent only when the collector could not tell.
            Column {
              width: parent.width
              spacing: Style.spacing.xs
              visible: root.fanRows.length > 0 || root.fanNote !== ""

              Text {
                text: "Fans"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.fanRows
                delegate: StatRow {
                  required property var modelData
                  width: parent.width
                  label: modelData.label
                  value: modelData.rpm > 0 ? (modelData.rpm + " rpm") : "stopped"
                }
              }

              Text {
                visible: root.fanNote !== ""
                text: root.fanNote
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Load
          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.snap && root.snap.cpu

            SectionHeading { width: parent.width; title: "LOAD" }

            StatRow {
              width: parent.width
              label: root.snap && root.snap.cpu ? (root.snap.cpu.model || "CPU") : "CPU"
              value: root.fmtPct(root.cpuBusy)
            }
            Meter { width: parent.width; value: root.cpuBusy }

            // The cutoff is the whole point: bars name each thread and stop
            // working somewhere above eight, the strip stays legible at twenty
            // but names nothing.
            CoreBars {
              width: parent.width
              visible: root.coreBusy.length > 0 && root.coreBusy.length <= root.perCoreCutoff
              cores: visible ? root.coreBusy : []
            }

            CoreStrip {
              width: parent.width
              visible: root.coreBusy.length > root.perCoreCutoff
              cores: visible ? root.coreBusy : []
            }

            StatRow {
              width: parent.width
              label: "Load average"
              value: {
                var l = root.snap && root.snap.cpu ? root.snap.cpu.loadavg : null
                return l ? (l[0].toFixed(2) + "  " + l[1].toFixed(2) + "  " + l[2].toFixed(2)) : "—"
              }
              muted: true
            }

            StatRow {
              width: parent.width
              visible: root.snap && root.snap.cpu && root.snap.cpu.governor
              label: "Governor"
              value: root.snap && root.snap.cpu ? (root.snap.cpu.governor || "") : ""
              muted: true
            }

            StatRow {
              width: parent.width
              visible: root.snap && root.snap.memory
              label: "Memory"
              value: {
                var m = root.snap ? root.snap.memory : null
                if (!m) return "—"
                return root.fmtKb(m.totalKb - m.availableKb) + " of " + root.fmtKb(m.totalKb)
              }
            }
            Meter {
              width: parent.width
              visible: root.snap && root.snap.memory
              value: {
                var m = root.snap ? root.snap.memory : null
                return (m && m.totalKb > 0) ? (m.totalKb - m.availableKb) / m.totalKb : 0
              }
            }

            StatRow {
              width: parent.width
              visible: root.snap && root.snap.memory && root.snap.memory.swapTotalKb > 0
              label: "Swap"
              value: {
                var m = root.snap ? root.snap.memory : null
                if (!m || !m.swapTotalKb) return "—"
                return root.fmtKb(m.swapTotalKb - m.swapFreeKb) + " of " + root.fmtKb(m.swapTotalKb)
              }
              muted: true
            }
          }

          // ---- Storage
          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.filesystemRows.length > 0 || root.diskRows.length > 0

            SectionHeading { width: parent.width; title: "STORAGE" }

            Column {
              width: parent.width
              spacing: Style.spacing.md
              Repeater {
                model: root.filesystemRows
                delegate: FilesystemRow {
                  required property var modelData
                  width: parent.width
                  fs: modelData
                }
              }
            }

            Text {
              visible: root.filesystemRemainder !== ""
              text: root.filesystemRemainder
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            // The drives themselves, which is a different question from how
            // full a filesystem is: capacity here is the hardware's, before
            // any partitioning, and the temperature belongs to the drive.
            Column {
              width: parent.width
              spacing: Style.spacing.xs
              visible: root.diskRows.length > 0

              Text {
                text: "Drives"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.diskRows
                delegate: StatRow {
                  required property var modelData
                  width: parent.width
                  label: modelData.name + "  " + (modelData.rotational ? "spinning" : "solid state")
                  value: root.fmtBytes(modelData.sizeBytes)
                         + (modelData.tempC !== undefined ? "   " + root.fmtTemp(modelData.tempC) : "")
                  muted: true
                }
              }
            }
          }

          // ---- Network
          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.netRates.length > 0

            SectionHeading { width: parent.width; title: "NETWORK" }

            Repeater {
              model: root.netRates
              delegate: StatRow {
                required property var modelData
                width: parent.width
                label: modelData.iface + (modelData.wireless ? "  wifi" : "")
                value: modelData.up
                       ? ("↓ " + root.fmtRate(modelData.rx) + "   ↑ " + root.fmtRate(modelData.tx))
                       : "down"
                muted: !modelData.up
              }
            }
          }

          // ---- Power
          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.batteryRows.length > 0 || (root.snap && root.snap.power && root.snap.power.onAc !== undefined)

            SectionHeading { width: parent.width; title: "POWER" }

            StatRow {
              width: parent.width
              visible: root.snap && root.snap.power && root.snap.power.onAc !== undefined
              label: "Mains"
              value: root.snap && root.snap.power && root.snap.power.onAc ? "connected" : "on battery"
            }

            Repeater {
              model: root.batteryRows
              delegate: Column {
                required property var modelData
                width: parent.width
                spacing: Style.spacing.xxs

                StatRow {
                  width: parent.width
                  label: modelData.name
                  // wattsDirection is why this can say "charging at" rather
                  // than presenting a charge rate as system draw.
                  value: {
                    var pct = (modelData.percent !== undefined && modelData.percent !== null)
                              ? modelData.percent + "%" : "—"
                    if (modelData.watts === undefined) return pct
                    var verb = modelData.wattsDirection === "charge" ? "charging at "
                             : modelData.wattsDirection === "draw" ? "drawing " : ""
                    return pct + "   " + verb + modelData.watts.toFixed(1) + " W"
                  }
                }
                Meter {
                  width: parent.width
                  value: (modelData.percent || 0) / 100
                  alarming: (modelData.percent || 100) <= 15 && modelData.state !== "Charging"
                }
              }
            }
          }

          // ---- Footer: where the numbers came from, and anything that broke.
          Column {
            width: parent.width
            spacing: Style.spacing.xs

            PanelSeparator { width: parent.width; foreground: root.foreground }

            Text {
              text: {
                if (!root.snap) return "waiting for first sample"
                var host = root.snap.host || ""
                // Rates need two samples. Saying so beats showing a dash and
                // letting it read as "no traffic".
                return root.prev ? host : host + " — rates start on the next sample"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.error !== ""
              text: root.error
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }
        }
      }
    }
  }
}
