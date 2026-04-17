import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

PopupWindow {
    id: root

    required property var anchorWindow
    required property var anchorItem
    required property var net   // NetworkService instance

    // The SSID of the row currently in password-entry mode (empty = none).
    property string passwordRowSsid: ""

    readonly property int popupWidth: 232
    readonly property int popupHeight: 230

    // Anchor above the pill, right-aligned to the pill's right edge.
    // Coordinates are in the anchor item's local space; negative y = above.
    anchor.item: anchorItem
    anchor.rect.x: anchorItem ? anchorItem.width - popupWidth : 0
    anchor.rect.y: -popupHeight - 8

    implicitWidth: popupWidth
    implicitHeight: popupHeight
    color: "transparent"
    visible: false
    grabFocus: true

    HyprlandFocusGrab {
        active: root.visible
        windows: [root]
        onCleared: {
            root.visible = false
            root.passwordRowSsid = ""
        }
    }

    onVisibleChanged: {
        if (visible) {
            passwordRowSsid = ""
            net.scan()
        }
    }

    // ── Animated container: scales from the pill (bottom-right) outward ──
    Item {
        id: contentRoot
        anchors.fill: parent
        transformOrigin: Item.BottomRight
        scale: root.visible ? 1.0 : 0.0
        opacity: root.visible ? 1.0 : 0.0

        Behavior on scale   { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }

    // ── Background (pill shader: diagonal fill + warm inner glow) ──
    ShaderEffect {
        id: bgShader
        anchors.fill: parent

        property size  iSize:        Qt.size(width, height)
        property real  cornerRadius: 16

        property color fillColor1:   "#2B2418"
        property color fillColor2:   "#BCA06B"

        property color glowAmber:    Qt.rgba(1.000, 0.745, 0.380, 0.08)  // #FFBE61
        property color glowWhite:    Qt.rgba(1.000, 0.815, 0.484, 0.03)  // #FFD07B
        property real  glowRadius:   25.0
        property real  glowIntensity: 1.0

        fragmentShader: "file:///home/user/.config/quickshell/clock/pill.frag.qsb"
    }

    Shape {
        id: bgBorder
        anchors.fill: parent

        ShapePath {
            strokeColor: "transparent"
            fillRule: ShapePath.OddEvenFill
            fillGradient: LinearGradient {
                x1: 0.870 * bgBorder.width
                y1: 0.146 * bgBorder.height
                x2: 0.185 * bgBorder.width
                y2: 0.930 * bgBorder.height
                GradientStop { position: 0.00; color: Qt.rgba(1, 1, 1, 0.14) }
                GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, 0.00) }
                GradientStop { position: 0.95; color: Qt.rgba(1, 1, 1, 0.025) }
                GradientStop { position: 1.00; color: Qt.rgba(1, 1, 1, 0.14) }
            }
            PathRectangle {
                x: 0; y: 0
                width: bgBorder.width
                height: bgBorder.height
                radius: 16
            }
            PathRectangle {
                x: 1; y: 1
                width: bgBorder.width - 2
                height: bgBorder.height - 2
                radius: 15
            }
        }
    }

    // ── Network list ──
    ListView {
        id: networkList
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: divider.top
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.topMargin: 10
        anchors.bottomMargin: 8
        clip: true
        spacing: 0

        model: {
            const arr = Object.values(root.net.networks)
            arr.sort((a, b) => b.signal - a.signal)
            return arr
        }

        delegate: Item {
            id: row
            width: networkList.width
            height: 36

            required property var modelData
            property bool isHovered: rowMouse.containsMouse
            property bool isPasswordRow: root.passwordRowSsid === row.modelData.ssid
            property bool actionVisible: isHovered || isPasswordRow

            // Hover / active background
            Rectangle {
                anchors.fill: parent
                radius: 18
                color: Qt.rgba(0.737, 0.627, 0.420, 0.10)
                opacity: row.actionVisible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
            }

            WifiIcon {
                id: rowIcon
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                signalLevel: {
                    const s = row.modelData.signal
                    return s >= 70 ? 3 : s >= 40 ? 2 : s > 0 ? 1 : 0
                }
            }

            Text {
                anchors.left: rowIcon.right
                anchors.leftMargin: 8
                anchors.right: actionBtn.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.ssid
                color: Qt.rgba(1, 1, 1, 0.85)
                font.family: "Geist"
                font.pixelSize: 12
                font.weight: Font.Medium
                elide: Text.ElideRight
            }

            // Inline Connect button / password TextField on the right of the row
            Rectangle {
                id: actionBtn
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: row.isPasswordRow ? 120 : 64
                height: 22
                radius: 11
                color: Qt.rgba(0.737, 0.627, 0.420, 0.18)
                visible: row.actionVisible
                opacity: row.actionVisible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                Text {
                    anchors.centerIn: parent
                    text: row.modelData.connected ? "Disconnect" : "Connect"
                    visible: !row.isPasswordRow
                    color: Qt.rgba(1, 1, 1, 0.9)
                    font.family: "Geist"
                    font.pixelSize: 11
                    font.weight: Font.Medium
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: !row.isPasswordRow
                    acceptedButtons: Qt.LeftButton
                    onClicked: (mouse) => {
                        mouse.accepted = true
                        if (row.modelData.connected) {
                            root.net.disconnect(row.modelData.ssid)
                            root.visible = false
                        } else if (row.modelData.secured) {
                            root.passwordRowSsid = row.modelData.ssid
                        } else {
                            root.net.connect(row.modelData.ssid, "")
                            root.visible = false
                        }
                    }
                }

                TextField {
                    id: passwordField
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    visible: row.isPasswordRow
                    echoMode: TextInput.Password
                    passwordCharacter: "●"
                    color: "white"
                    font.family: "Geist"
                    font.pixelSize: 11
                    placeholderText: "Password"
                    placeholderTextColor: Qt.rgba(1, 1, 1, 0.4)
                    background: null
                    selectByMouse: true

                    onVisibleChanged: if (visible) forceActiveFocus()

                    onAccepted: {
                        if (text.length === 0) return
                        root.net.connect(row.modelData.ssid, text)
                        text = ""
                        root.passwordRowSsid = ""
                        root.visible = false
                    }

                    Keys.onEscapePressed: {
                        text = ""
                        root.passwordRowSsid = ""
                    }
                }
            }

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
            }
        }
    }

    // ── Footer divider + wifi toggle ──
    Rectangle {
        id: divider
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        height: 1
        color: Qt.rgba(1, 1, 1, 0.2)
    }

    Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: "Wifi"
            color: Qt.rgba(1, 1, 1, 0.8)
            font.family: "Geist"
            font.pixelSize: 12
            font.weight: Font.Medium
        }

        Rectangle {
            id: toggleTrack
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            width: 32
            height: 18
            radius: 9
            color: Qt.rgba(1, 1, 1, 0.2)

            Rectangle {
                width: 14
                height: 14
                radius: 7
                color: "white"
                anchors.verticalCenter: parent.verticalCenter
                x: root.net.wifiEnabled ? parent.width - width - 2 : 2
                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: root.net.setWifiEnabled(!root.net.wifiEnabled)
            }
        }
    }
    } // contentRoot
}
