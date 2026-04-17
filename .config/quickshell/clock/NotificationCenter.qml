pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications

PopupWindow {
    id: root

    required property var anchorItem
    required property var server

    readonly property var notifs: server && server.trackedNotifications
        ? server.trackedNotifications.values
        : []
    readonly property int count: notifs.length
    readonly property int panelWidth: count > 0 ? 302 : 272

    // Receipt-time map: notif.id -> Date.now() ms, populated via Connections below
    property var receivedAt: ({})

    // Body height: empty placeholder is 152; list sums each item (56 for 1-line,
    // 76 for 2-line — rough heuristic by char count to drive the panel height).
    readonly property int bodyHeight: {
        if (count === 0) return 152
        let total = 0
        for (let i = 0; i < notifs.length; i++) {
            const n = notifs[i]
            if (!n) continue
            const text = (n.body || n.summary || "")
            total += text.length > 40 ? 76 : 56
        }
        return total
    }
    readonly property int panelHeight: 16 + 26 + 12 + 1 + 12 + bodyHeight + 8

    anchor.item: anchorItem
    anchor.rect.x: anchorItem ? (anchorItem.width - panelWidth) / 2 : 0
    anchor.rect.y: -panelHeight - 8

    implicitWidth: panelWidth
    implicitHeight: panelHeight
    color: "transparent"
    visible: false

    HyprlandFocusGrab {
        active: root.visible
        windows: [root]
        onCleared: root.visible = false
    }

    // Track receipt time so the timestamp column can show when each arrived.
    Connections {
        target: root.server
        ignoreUnknownSignals: true
        function onNotification(n) {
            const next = Object.assign({}, root.receivedAt)
            next[n.id] = Date.now()
            root.receivedAt = next
        }
    }

    function _formatTime(ms) {
        if (!ms) return ""
        const d = new Date(ms)
        const h = d.getHours() % 12 || 12
        const mm = d.getMinutes().toString().padStart(2, '0')
        const ap = d.getHours() >= 12 ? "pm" : "am"
        return h + ":" + mm + ap
    }

    function _clearAll() {
        const list = notifs.slice()
        for (let i = 0; i < list.length; i++) {
            if (list[i]) list[i].dismiss()
        }
    }

    // Background: SDF shader fill + 1px border, matches pill styling at r=16
    ShaderEffect {
        anchors.fill: parent
        property size  iSize:         Qt.size(width, height)
        property real  cornerRadius:  16
        property color fillColor1:    Qt.rgba(1, 1, 1, 0.048)
        property color fillColor2:    Qt.rgba(1, 1, 1, 0.12)
        property color glowAmber:     Qt.rgba(0, 0, 0, 0)
        property color glowWhite:     Qt.rgba(1, 1, 1, 0.12)
        property real  glowRadius:    8.0
        property real  glowIntensity: 1.0

        fragmentShader: "file:///home/user/.config/quickshell/clock/pill.frag.qsb"
    }

    Shape {
        anchors.fill: parent
        ShapePath {
            strokeColor: Qt.rgba(1, 1, 1, 0.4)
            strokeWidth: 1
            fillColor: "transparent"
            PathRectangle {
                x: 0.5; y: 0.5
                width: root.width - 1
                height: root.height - 1
                radius: 15.5
            }
        }
    }

    // ── Content ──
    Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: 16
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        anchors.bottomMargin: 8

        // Header row
        Item {
            id: header
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 26

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Image {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20; height: 20
                    source: Qt.resolvedUrl("bell.svg")
                    sourceSize: Qt.size(40, 40)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.count + " Notifications"
                    color: Qt.rgba(1, 1, 1, 0.8)
                    font.family: "Geist"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    font.letterSpacing: -0.12
                }
            }

            Rectangle {
                id: clearBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.count > 0
                height: 26
                width: 45
                radius: 13
                color: clearMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.1)
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text: "Clear"
                    color: Qt.rgba(1, 1, 1, 0.8)
                    font.family: "Geist"
                    font.pixelSize: 10
                    font.weight: Font.Medium
                    font.letterSpacing: -0.1
                }

                MouseArea {
                    id: clearMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root._clearAll()
                }
            }
        }

        // Separator line
        Rectangle {
            id: separator
            anchors.top: header.bottom
            anchors.topMargin: 12
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Qt.rgba(1, 1, 1, 0.1)
        }

        // Body
        Item {
            id: body
            anchors.top: separator.bottom
            anchors.topMargin: 12
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            // Empty placeholder
            Text {
                visible: root.count === 0
                anchors.centerIn: parent
                text: "No notifications"
                color: Qt.rgba(1, 1, 1, 0.3)
                font.family: "Geist"
                font.pixelSize: 14
                font.weight: Font.Medium
            }

            // List of notification items — x=-8 to extend 8px into the content padding
            // on both sides, giving the wider hover target that Figma shows.
            Column {
                id: list
                visible: root.count > 0
                x: -8
                width: 286

                Repeater {
                    model: root.notifs
                    delegate: Rectangle {
                        id: item
                        required property var modelData
                        required property int index

                        readonly property string _body: modelData ? (modelData.body || modelData.summary || "") : ""
                        readonly property string _app: modelData ? (modelData.appName || "Notification") : ""
                        readonly property string _icon: modelData ? (modelData.image || modelData.appIcon || "") : ""
                        readonly property real _ts: (modelData && root.receivedAt) ? (root.receivedAt[modelData.id] || 0) : 0

                        width: 286
                        height: bodyText.contentHeight + 36  // 8 top-pad + 16 header + 4 gap + 8 bot-pad
                        radius: 12
                        color: itemHover.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(0, 0, 0, 0)
                        Behavior on color { ColorAnimation { duration: 150 } }

                        MouseArea {
                            id: itemHover
                            anchors.fill: parent
                            hoverEnabled: true
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: 8

                            Item {
                                id: itemHeader
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: 16

                                Row {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    Image {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 16; height: 16
                                        source: item._icon
                                        visible: source != ""
                                        sourceSize: Qt.size(32, 32)
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: item._app
                                        color: Qt.rgba(1, 1, 1, 0.5)
                                        font.family: "Geist"
                                        font.pixelSize: 12
                                        font.weight: Font.Medium
                                    }
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root._formatTime(item._ts)
                                    color: Qt.rgba(1, 1, 1, 0.5)
                                    font.family: "Geist"
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                }
                            }

                            Text {
                                id: bodyText
                                anchors.top: itemHeader.bottom
                                anchors.topMargin: 4
                                anchors.left: parent.left
                                anchors.right: parent.right
                                text: item._body
                                color: Qt.rgba(1, 1, 1, 0.8)
                                font.family: "Geist"
                                font.pixelSize: 14
                                font.weight: Font.Medium
                                lineHeight: 20
                                lineHeightMode: Text.FixedHeight
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
