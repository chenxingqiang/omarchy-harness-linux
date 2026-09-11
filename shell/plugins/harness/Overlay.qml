import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "SessionView.js" as SessionView

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool hostDown: false
  property string statusText: ""
  property var pending: []
  property string sessionTitle: "Untitled session"
  property string keyboardHint: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(640), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(420), panel.height - Style.gapsOut * 2)

  function open(payloadJson) {
    root.opened = true
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "omarchy.harness")
  }

  function refresh() {
    stateProc.running = false
    stateProc.running = true
  }

  function loadState(text) {
    const view = SessionView.parseHostState(text)
    root.hostDown = view.hostDown
    root.pending = view.pending
    root.sessionTitle = view.title
    root.statusText = view.statusText
    root.keyboardHint = view.keyboardHint || ""
  }

  function pendingToneColor(tone) {
    if (tone === "urgent")
      return Color.urgent
    if (tone === "accent")
      return Color.accent
    return Color.muted
  }

  function decide(approvalId, decision) {
    const binary = decision === "allow" ? "omarchy-harness-approve" : "omarchy-harness-deny"
    Quickshell.execDetached([root.omarchyPath + "/bin/" + binary, approvalId])
    Qt.callLater(root.refresh)
  }

  function decideFirst(decision) {
    if (!root.pending.length)
      return
    root.decide(root.pending[0].approvalId, decision)
  }

  IpcHandler {
    target: "omarchy.harness"
    function open(payloadJson: string): string { root.open(payloadJson); return "ok" }
    function close(): string { root.close(); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }
    function ping(): string { return root.hostDown ? "down" : "ok" }
  }

  Process {
    id: stateProc
    command: [root.omarchyPath + "/bin/omarchy-harness-host", "session", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadState(text)
    }
    onExited: function(code) {
      if (code !== 0)
        root.loadState("")
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-harness"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_R) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_Y || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.decideFirst("allow")
            event.accepted = true
          } else if (event.key === Qt.Key_N) {
            root.decideFirst("deny")
            event.accepted = true
          }
        }

        Column {
          anchors.fill: parent
          spacing: Style.spacing.md

          Text {
            width: parent.width
            text: root.sessionTitle
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            width: parent.width
            text: root.statusText
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            visible: !root.hostDown
            text: root.keyboardHint
            textFormat: Text.PlainText
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.pending
            delegate: Row {
              required property var modelData
              spacing: Style.spacing.sm
              width: keyCatcher.width

              Column {
                width: parent.width - Style.space(180)
                spacing: Style.spacing.xxs

                Text {
                  text: modelData.badge
                  textFormat: Text.PlainText
                  color: root.pendingToneColor(modelData.tone)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: modelData.kind === "system"
                }

                Text {
                  width: parent.width
                  text: modelData.summary || modelData.approvalId
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }

                Text {
                  width: parent.width
                  text: modelData.hint
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  color: Color.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                width: Style.space(80)
                height: Style.space(28)
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.decide(modelData.approvalId, "allow")
                Rectangle {
                  anchors.fill: parent
                  radius: root.cornerRadius
                  color: root.selectedBackground
                  Text {
                    anchors.centerIn: parent
                    text: "Allow"
                    color: root.selectedText
                    font.family: root.fontFamily
                  }
                }
              }

              MouseArea {
                width: Style.space(80)
                height: Style.space(28)
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.decide(modelData.approvalId, "deny")
                Rectangle {
                  anchors.fill: parent
                  radius: root.cornerRadius
                  color: root.border
                  Text {
                    anchors.centerIn: parent
                    text: "Deny"
                    color: root.foreground
                    font.family: root.fontFamily
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
