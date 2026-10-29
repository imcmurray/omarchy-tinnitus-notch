import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ianm.tinnitus"
  ipcTarget: "ianm.tinnitus"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property string ctl: Quickshell.env("HOME") + "/.config/omarchy/plugins/ianm.tinnitus/bin/tinnitus-notch"

  property bool enabled: false
  property real freq: 6000
  property real notchQ: 8
  property bool toneBusy: false
  property real wheelAccumulator: 0
  property real pendingFreq: -1
  property real pendingQ: -1
  property bool meterActive: false
  property bool meterQuiet: true
  property bool meterTone: false
  property bool meterOutputQuiet: false
  property bool meterHeard: false
  property bool meterStopRequested: false
  property var meterCutDb: null
  property string meterError: ""
  property var meterBefore: []
  property var meterAfter: []

  readonly property color ink: root.bar ? root.bar.foreground : Color.foreground
  readonly property bool meterLive: enabled
    && meterActive
    && !meterQuiet
    && !meterOutputQuiet
    && meterBefore.length === 25
    && meterAfter.length === 25

  readonly property int widthHz: Math.max(1, Math.round(freq / Math.max(notchQ, 0.7)))
  readonly property string freqText: Math.round(freq) + " Hz"
  readonly property string barLabel: (freq / 1000).toFixed(1) + "k"
  readonly property string tooltip: enabled
    ? ("Tinnitus notch on · " + freqText + " · about " + widthHz + " Hz wide")
    : ("Tinnitus notch off · " + freqText)

  function open() {
    root.controller.show()
    stateFile.reload()
  }

  function openFromHotkey() {
    root.controller.show()
    stateFile.reload()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function applyState(raw) {
    var data
    try {
      data = JSON.parse(String(raw || ""))
    } catch (e) {
      return
    }
    if (!data || typeof data !== "object") return
    root.enabled = data.enabled === true
    var freqHeld = (freqSlider && freqSlider.dragging) || root.pendingFreq >= 0
    var widthHeld = (widthSlider && widthSlider.dragging) || root.pendingQ >= 0
    if (!freqHeld) {
      var nextFreq = Number(data.freq)
      if (!isNaN(nextFreq) && nextFreq > 0) root.freq = nextFreq
    }
    if (!widthHeld) {
      var nextQ = Number(data.q)
      if (!isNaN(nextQ) && nextQ > 0) root.notchQ = nextQ
    }
  }

  function queueFreq(value) {
    root.freq = clampFreq(value)
    root.pendingFreq = root.freq
    freqTimer.restart()
  }

  function queueQ(value) {
    root.notchQ = clampQ(value)
    root.pendingQ = root.notchQ
    qTimer.restart()
  }

  function commitFreq() {
    if (root.pendingFreq < 0) return
    var value = Math.round(root.pendingFreq)
    root.pendingFreq = -1
    Quickshell.execDetached([root.ctl, "freq", String(value)])
  }

  function commitQ() {
    if (root.pendingQ < 0) return
    var value = Math.round(root.pendingQ * 100) / 100
    root.pendingQ = -1
    Quickshell.execDetached([root.ctl, "q", String(value)])
  }

  function clampFreq(value) {
    return Math.max(500, Math.min(14000, value))
  }

  function clampQ(value) {
    return Math.max(0.7, Math.min(30, value))
  }

  function nudge(delta) {
    queueFreq(root.freq + delta)
  }

  function nudgeFromWheel(delta) {
    var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
    root.wheelAccumulator = wheel.remainder
    if (wheel.steps === 0) return
    nudge(wheel.steps * 20)
  }

  function setEnabled(on) {
    root.enabled = on
    Quickshell.execDetached([root.ctl, on ? "on" : "off"])
  }

  function playTone() {
    if (root.toneBusy) return
    root.toneBusy = true
    toneTimer.restart()
    Quickshell.execDetached([root.ctl, "tone"])
  }

  function widthLabel(q) {
    var hz = Math.max(1, Math.round(root.freq / Math.max(q, 0.7)))
    if (q >= 10) return "Thin · " + hz + " Hz"
    if (q >= 4) return "Medium · " + hz + " Hz"
    return "Wide · " + hz + " Hz"
  }

  // Bin layout matches meter_frequencies() in bin/tinnitus-notch.
  function meterFreq(index) {
    var nyquist = 48000 * 0.45
    var span = 1
    if (root.freq * 2 > nyquist)
      span = Math.log(nyquist / root.freq) / Math.LN2
    if (index === 12) return root.freq
    return root.freq * Math.pow(2, ((index - 12) / 12) * span)
  }

  function expectedNotch(index) {
    var frequency = root.meterFreq(index)
    var rate = 48000
    var q = Math.max(root.notchQ, 0.7)
    var w0 = 2 * Math.PI * root.freq / rate
    var alpha = Math.sin(w0) / (2 * q)
    var cw0 = Math.cos(w0)
    var b1 = -2 * cw0
    var a0 = 1 + alpha
    var a2 = 1 - alpha
    var angle = 2 * Math.PI * frequency / rate
    var c1 = Math.cos(angle)
    var s1 = Math.sin(angle)
    var c2 = Math.cos(2 * angle)
    var s2 = Math.sin(2 * angle)
    var nr = 1 + b1 * c1 + c2
    var ni = -(b1 * s1 + s2)
    var dr = a0 + b1 * c1 + a2 * c2
    var di = -(b1 * s1 + a2 * s2)
    var mag = Math.sqrt(nr * nr + ni * ni) / Math.max(1e-9, Math.sqrt(dr * dr + di * di))
    var db = 20 * Math.log(Math.max(mag, 1e-6)) / Math.LN10
    return Math.max(0, Math.min(1, (db + 42) / 42))
  }

  function cutReadout() {
    if (root.meterTone) return "tone passes"
    if (root.meterLive && typeof root.meterCutDb === "number") {
      var down = Math.round(-root.meterCutDb)
      if (down >= 3) return down + " dB down"
    }
    if (!root.enabled) return "off"
    if (root.meterLive) return "live"
    return "waiting"
  }

  function cutStatus() {
    if (root.meterError !== "") return root.meterError
    if (!root.enabled)
      return "Turn the notch on and play something. The outline is the band that will be cut."
    if (root.meterOutputQuiet)
      return "Sound is going into the notch, but nothing is reaching the speakers."
    if (root.meterTone)
      return "The match tone is passing through. The notch does not remove it."
    if (!root.meterLive)
      return "Play something. The outline is the cut you set. Pale bars are sound going in, solid bars are sound coming out."
    return "Pale bars are sound going in. Solid bars are sound coming out. The gap under the mark is the notch."
  }

  function clearMeter() {
    root.meterActive = false
    root.meterQuiet = true
    root.meterTone = false
    root.meterOutputQuiet = false
    root.meterHeard = false
    root.meterCutDb = null
    root.meterError = ""
    root.meterBefore = []
    root.meterAfter = []
  }

  function applyMeter(line) {
    var data
    try {
      data = JSON.parse(String(line || ""))
    } catch (e) {
      return
    }
    if (!data || typeof data !== "object") return
    root.meterHeard = true
    root.meterActive = data.active === true
    root.meterQuiet = data.quiet !== false
    root.meterTone = data.tone === true
    root.meterOutputQuiet = data.output_quiet === true
    root.meterError = String(data.error || "")
    root.meterCutDb = (typeof data.cut_db === "number") ? data.cut_db : null
    if (!root.meterQuiet && !root.meterOutputQuiet && data.before && data.after
        && data.before.length === 25 && data.after.length === 25) {
      root.meterBefore = data.before
      root.meterAfter = data.after
    }
  }

  function syncMeter() {
    if (!meterProc) return
    var want = root.opened && root.enabled
    if (want) {
      root.meterStopRequested = false
      if (!meterProc.running) meterProc.running = true
      return
    }
    root.meterStopRequested = true
    if (meterProc.running) meterProc.running = false
    root.clearMeter()
  }

  onOpenedChanged: root.syncMeter()
  onEnabledChanged: root.syncMeter()
  Component.onCompleted: root.syncMeter()

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.config/tinnitus-notch/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: root.applyState("")
  }

  Timer {
    id: freqTimer
    interval: 70
    repeat: false
    onTriggered: root.commitFreq()
  }

  Timer {
    id: qTimer
    interval: 70
    repeat: false
    onTriggered: root.commitQ()
  }

  Timer {
    id: toneTimer
    interval: 1800
    repeat: false
    onTriggered: root.toneBusy = false
  }

  Timer {
    id: meterRestart
    interval: 800
    repeat: false
    onTriggered: {
      if (!root.meterStopRequested && root.opened && root.enabled && !meterProc.running)
        meterProc.running = true
    }
  }

  Process {
    id: meterProc
    command: [root.ctl, "meter"]
    stdout: SplitParser { onRead: function(line) { root.applyMeter(line) } }
    stderr: SplitParser { onRead: function(line) {} }
    onExited: function(exitCode) {
      if (!root.meterStopRequested && root.opened && root.enabled)
        meterRestart.restart()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.nudge(dx * 10)
        else if (dy !== 0) root.nudge(dy * -100)
      }
      onActivateRequested: root.setEnabled(!root.enabled)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") root.playTone()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰋋"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            opacity: root.enabled ? 1.0 : 0.45
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: powerSwitch
            checked: root.enabled
            foreground: root.bar ? root.bar.foreground : Color.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.setEnabled(!root.enabled)
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: powerSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Tinnitus notch"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.enabled ? "ON · PLAYBACK ONLY" : "OFF"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              width: parent.width
            }
          }
        }

        PanelSeparator {
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(freqHeader.implicitHeight, freqReadout.implicitHeight)

            PanelSectionHeader {
              id: freqHeader
              text: "PITCH"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: freqReadout
              textFormat: Text.PlainText
              text: root.freqText
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: freqSlider
            width: parent.width
            bar: root.bar
            minimum: 500
            maximum: 14000
            step: 10
            integer: true
            value: root.freq
            onMoved: function(v) { root.queueFreq(v) }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: "-100"
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.nudge(-100)
            }
            Button {
              text: "-10"
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.nudge(-10)
            }
            Button {
              text: "+10"
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.nudge(10)
            }
            Button {
              text: "+100"
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.nudge(100)
            }
            Button {
              text: "÷2"
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.queueFreq(root.freq / 2)
            }
            Button {
              text: "×2"
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.queueFreq(root.freq * 2)
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(widthHeader.implicitHeight, widthReadout.implicitHeight)

            PanelSectionHeader {
              id: widthHeader
              text: "WIDTH"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: widthReadout
              textFormat: Text.PlainText
              text: root.widthLabel(root.notchQ)
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: widthSlider
            width: parent.width
            bar: root.bar
            minimum: 250
            maximum: 5000
            step: 50
            value: Math.max(250, Math.min(5000, root.widthHz))
            onMoved: function(v) { root.queueQ(root.freq / Math.max(250, v)) }
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: "Thin"
              bordered: true
              selected: root.notchQ >= 10
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.queueQ(12)
            }
            Button {
              text: "Medium"
              bordered: true
              selected: root.notchQ >= 4 && root.notchQ < 10
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.queueQ(8)
            }
            Button {
              text: "Octave"
              bordered: true
              selected: root.notchQ < 4
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.queueQ(1.41)
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(cutHeader.implicitHeight, cutReadout.implicitHeight)

            PanelSectionHeader {
              id: cutHeader
              text: "THE CUT"
              foreground: root.ink
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: cutReadout
              textFormat: Text.PlainText
              text: root.cutReadout()
              color: (root.meterLive && typeof root.meterCutDb === "number" && root.meterCutDb <= -6)
                ? Color.accent
                : Qt.darker(root.ink, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Item {
            id: meterPlot
            width: parent.width
            height: Style.space(68)

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: 1
              color: root.ink
              opacity: 0.18
            }

            Repeater {
              model: 25

              Item {
                required property int index
                readonly property real slot: meterPlot.width / 25
                x: index * slot + 1
                width: Math.max(2, slot - 2)
                height: meterPlot.height

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  radius: 1
                  visible: root.meterLive
                  color: root.ink
                  opacity: 0.22
                  height: {
                    var level = 0
                    if (root.meterLive && root.meterBefore.length === 25)
                      level = Number(root.meterBefore[index]) || 0
                    level = Math.max(0, Math.min(1, level))
                    return level * meterPlot.height
                  }
                }

                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  radius: 1
                  width: root.meterLive ? parent.width * 0.62 : parent.width
                  color: (!root.meterLive || index === 12) ? Color.accent : root.ink
                  opacity: root.meterLive ? 0.95 : (root.enabled ? 0.5 : 0.28)
                  height: {
                    var level = root.meterLive ? 0 : root.expectedNotch(index)
                    if (root.meterLive && root.meterAfter.length === 25)
                      level = Number(root.meterAfter[index]) || 0
                    level = Math.max(0, Math.min(1, level))
                    return level * meterPlot.height
                  }
                }

                Rectangle {
                  visible: index === 12
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.top: parent.top
                  width: parent.width
                  height: 2
                  color: Color.accent
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: meterLowLabel.implicitHeight

            Text {
              id: meterLowLabel
              textFormat: Text.PlainText
              text: "lower"
              color: Qt.darker(root.ink, 1.45)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
            }

            Text {
              textFormat: Text.PlainText
              text: root.freqText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: "higher"
              color: Qt.darker(root.ink, 1.45)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: Qt.darker(root.ink, 1.35)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            text: root.cutStatus()
          }
        }

        Button {
          width: parent.width
          text: root.toneBusy ? "Playing match tone…" : "Play match tone"
          bordered: true
          enabled: !root.toneBusy
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.playTone()
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          text: "Match the tone to the ring, then leave the notch on for music and video. Scroll the bar icon to nudge the pitch. The ring is in the ear, so silence still rings. Thin is the least obvious cut. Octave is about the width used in notched-music studies. The microphone is left alone."
        }
      }
    }
  }
}
