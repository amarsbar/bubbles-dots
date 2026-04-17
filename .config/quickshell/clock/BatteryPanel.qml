// ─────────────────────────────────────────────────────────────────────────────
// Standalone battery module (currently unused).
//
// Battery indication now lives in the settings popup header (see
// SettingsContent.qml). This file is preserved so a future setting can toggle
// between "battery in settings header" (current default) and "separate battery
// pill" (this module, equivalent to the original layout pre-redesign).
//
// To re-enable: add `BatteryPanel {}` as a direct child of ShellRoot in
// shell.qml, and adjust settingsPanel's right margin accordingly.
// ─────────────────────────────────────────────────────────────────────────────

import Quickshell
import Quickshell.Wayland
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: batteryPanel

        required property var modelData
        screen: modelData

        anchors { bottom: true; right: true }
        margins { bottom: 8; right: 292 }  // clock right-margin (24) + clock panel width (260) + gap (8)

        implicitWidth: 140
        implicitHeight: 48
        color: "transparent"

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-clock"
        exclusionMode: ExclusionMode.Ignore

        readonly property var batteryDevice: UPower.displayDevice
        readonly property bool batteryReady: batteryDevice && batteryDevice.ready && batteryDevice.isPresent
        readonly property real batteryPercent: {
            if (!batteryReady) return 0
            if (batteryDevice.state === UPowerDeviceState.FullyCharged) return 100
            return Math.round(batteryDevice.percentage * 100)
        }
        readonly property bool isCharging: batteryReady && (batteryDevice.state === UPowerDeviceState.Charging || batteryDevice.state === UPowerDeviceState.FullyCharged)

        RowLayout {
            anchors.fill: parent

            Pill {
                id: batteryPill
                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter

                collapsedWidth: batteryIcon.width + batteryPill.padding * 2
                expandedWidth:  percentText.implicitWidth + 10 + batteryIcon.width + batteryPill.padding * 2
                pillHeight: 36

                BatteryIcon {
                    id: batteryIcon
                    anchors.left: parent.left
                    anchors.leftMargin: batteryPill.padding
                    anchors.verticalCenter: parent.verticalCenter
                    percent: batteryPanel.batteryPercent
                    isCharging: batteryPanel.isCharging
                }

                Text {
                    id: percentText
                    anchors.right: parent.right
                    anchors.rightMargin: batteryPill.padding
                    anchors.verticalCenter: parent.verticalCenter
                    text: Math.round(batteryPanel.batteryPercent) + "%"
                    color: Qt.rgba(1, 1, 1, 0.5)
                    font.family: "Geist"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    font.letterSpacing: -0.12
                    opacity: batteryPill.hovered ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
                }
            }
        }
    }
}
