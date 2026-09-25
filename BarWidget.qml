import QtQuick
import qs.Commons
import qs.Ui

// Derived from Omarchy's own `omarchy.weather` bar widget
// (https://github.com/basecamp/omarchy, MIT, Copyright (c) David Heinemeier
// Hansson). The injectPanel / open / close / closeForPopoutSwitch contract
// below is what the bar requires of any widget hosting a panel, and this file
// follows that implementation closely. See LICENSE for the full notice.

// One glyph in the bar, tinted green, amber or red; everything else lives in
// the panel.
//
// There is no live number here. While the panel is closed the collector runs
// once a minute, only to keep the tint honest: red for what the panel already
// alarms on (a sensor near its critical limit, a filesystem past the disk
// alarm, memory or battery nearly gone), amber for the approach to any of
// them or a collector that could not be read, green otherwise. See barStatus
// in Panel.qml for the exact limits.
BarWidget {
  id: root
  moduleName: "brightwalker25.system"

  // nf-md-speedometer. Present in JetBrainsMono Nerd Font, which is what the
  // bar falls back to; a theme with a font lacking it gets tofu, so it is one
  // string and easy to change.
  readonly property string glyph: "󰓅"

  readonly property string status: panelLoader.item ? String(panelLoader.item.barStatus || "") : ""

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.poll) panelLoader.item.poll()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // needs open/close/opened on the bar-widget root, not on the nested panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // The bar prefers closeForPopoutSwitch over close when handing one panel
  // over to another, and reads popoutSwitchClosing back off the owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    slotSize: Style.bar.iconSlot
    // Suppressed because the panel is the detail view; a tooltip repeating
    // "System" over a panel that is about to open is noise.
    tooltipText: ""

    // The active colour is how the bar tints a glyph. The same fixed green,
    // amber and red as the other brightwalker25 widgets.
    useActiveColor: true
    active: root.status !== ""
    activeColor: root.status === "bad" ? "#f85149"
      : (root.status === "warn" ? "#d29922" : "#3fb950")

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
