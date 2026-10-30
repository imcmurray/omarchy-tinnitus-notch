import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ianm.tinnitus"

  readonly property string ctl: Quickshell.env("HOME") + "/.config/omarchy/plugins/ianm.tinnitus/bin/tinnitus-notch"
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: Quickshell.execDetached([ctl, "ensure-unit"])

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: panelLoader.item ? panelLoader.item.barLabel : "— k"
    fontSize: Style.font.caption
    active: panelLoader.item ? panelLoader.item.enabled === true : false
    activeColor: Color.accent
    dimmed: !(panelLoader.item && panelLoader.item.enabled)
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : "Tinnitus notch"

    onPressed: function(buttonCode) {
      if (!panelLoader.item) return
      if (buttonCode === Qt.RightButton) panelLoader.item.setEnabled(!panelLoader.item.enabled)
      else panelLoader.item.toggle()
    }

    onWheelMoved: function(delta) {
      if (panelLoader.item) panelLoader.item.nudgeFromWheel(delta)
    }
  }
}
