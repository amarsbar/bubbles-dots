import QtQuick
import QtQuick.Shapes

Item {
    id: pill

    property int collapsedWidth: 80
    property int expandedWidth: 140
    property int pillHeight: 48
    readonly property int padding: 18
    readonly property bool hovered: mouseArea.containsMouse

    // Active state overrides (for click-driven expansion like settings panel)
    property int activeWidth: -1
    property int activeHeight: -1
    property real activeCornerRadius: -1
    readonly property bool expanded: activeHeight > 0

    // Optional: override the expanded-state glow color (e.g. from album art).
    // Default matches the dock's blue inner glow theme.
    property color expandedGlowColor: Qt.rgba(0.349, 0.557, 1.0, 1.0)

    // Optional theme tint — when set (alpha > 0), replaces the default white fill
    // and suppresses the amber hover glow. Used by the music pill to tint itself
    // with the dominant album color across all non-expanded states.
    property color themeColor: Qt.rgba(0, 0, 0, 0)
    readonly property bool _themed: themeColor.a > 0.01

    // When false, the pill ignores hover and clicks (used by decorative
    // non-interactive pills like the notification module).
    property bool interactive: true

    // Duration (ms) for the width/height/corner Behaviors. Callers that need
    // a slower morph (e.g. the big critical-notification pill) can override
    // this per-instance without touching every other pill in the shell.
    property int animationDuration: 350

    // Toggle the shader-side fill/glow Behaviors separately from the main
    // size animation. Set false on pills that should snap instantly between
    // fill/glow states (e.g. the critical big pill, where the slow size
    // morph is the focal effect and a 5s glow fade would feel drifty).
    property bool animateShader: true

    // When false, the fill shader and gradient border render nothing. Used
    // by the critical big pill so the pill can rest at the compact toast's
    // dimensions (for a grow-from-there animation) while remaining visually
    // absent — otherwise its 0.07-alpha fill would show as a ghost overlay
    // on top of the actual compact toast beneath.
    property bool shaderEnabled: true

    // Fill gradient alphas for rest/hover states. Hover defaults now match
    // the dock theme — 180deg linear-gradient from purple-grey (top) to deep
    // blue (bottom), both at 0.25. The critical big pill overrides to match
    // its Figma spec (neutral-white brighter-on-hover, no tint).
    // Rest alphas lowered (from 0.07/0.16) so the compact pills don't
    // read as a foggy overlay on their own — the pill is more see-through
    // and the shader fill acts as a tint rather than a wash.
    property color restFill1:  Qt.rgba(1, 1, 1, 0.04)
    property color restFill2:  Qt.rgba(1, 1, 1, 0.10)
    property color hoverFill1: Qt.rgba(0.447, 0.373, 0.498, 0.25)
    property color hoverFill2: Qt.rgba(0.031, 0.302, 0.631, 0.25)

    // When false, the inner warm/white glow pass is suppressed (glowIntensity
    // forced to 0). The big pill uses this because its Figma spec shows only
    // a fill-alpha change on hover, no glow ring.
    property bool glowEnabled: true

    signal clicked()

    default property alias contentData: contentContainer.data

    implicitWidth: activeWidth > 0 ? activeWidth : (hovered ? expandedWidth : collapsedWidth)
    implicitHeight: activeHeight > 0 ? activeHeight : pillHeight
    clip: true

    Behavior on implicitWidth {
        NumberAnimation { duration: pill.animationDuration; easing.type: Easing.OutCubic }
    }
    Behavior on implicitHeight {
        NumberAnimation { duration: pill.animationDuration; easing.type: Easing.OutCubic }
    }

    property real _cornerRadius: activeCornerRadius > 0 ? activeCornerRadius : height / 2
    Behavior on _cornerRadius {
        NumberAnimation { duration: pill.animationDuration; easing.type: Easing.OutCubic }
    }

    // ── Fill + inner warm glow (SDF shader) ──
    ShaderEffect {
        id: fillShader
        anchors.fill: parent
        visible: pill.shaderEnabled

        property size  iSize:        Qt.size(width, height)
        property real  cornerRadius: pill._cornerRadius

        // Expanded state uses the same 180° purple→blue gradient as the
        // hover state (rgba(114,95,127,0.25) top → rgba(8,77,161,0.25) bottom),
        // per the Figma "expanded pill" spec.
        property color fillColor1: pill._themed
            ? Qt.rgba(pill.themeColor.r, pill.themeColor.g, pill.themeColor.b, 0.25)
            : (pill.expanded
                ? Qt.rgba(0.447, 0.373, 0.498, 0.25)
                : pill.hovered
                    ? pill.hoverFill1
                    : pill.restFill1)
        property color fillColor2: pill._themed
            ? Qt.rgba(pill.themeColor.r, pill.themeColor.g, pill.themeColor.b, 0.50)
            : (pill.expanded
                ? Qt.rgba(0.031, 0.302, 0.631, 0.25)
                : pill.hovered
                    ? pill.hoverFill2
                    : pill.restFill2)

        // Kept `glowAmber` as the property name to match the shader uniform;
        // the value is the dock's blue inner-top glow (rgba(89,142,255,0.12)).
        property color glowAmber: pill._themed
            ? Qt.rgba(0, 0, 0, 0)
            : Qt.rgba(0.349, 0.557, 1.0, 0.12)
        property color glowWhite: pill.expanded
            ? Qt.rgba(1.000, 1.000, 1.000, 0.06)
            : Qt.rgba(1.000, 1.000, 1.000, 0.06)
        property real  glowRadius: pill.expanded ? 12.0 : 15.0
        property real  glowIntensity: pill.glowEnabled
            ? (pill.expanded ? 0.5 : (pill.hovered ? 1.0 : 0.0))
            : 0.0

        Behavior on fillColor1    { enabled: pill.animateShader; ColorAnimation  { duration: 300; easing.type: Easing.OutCubic } }
        Behavior on fillColor2    { enabled: pill.animateShader; ColorAnimation  { duration: 300; easing.type: Easing.OutCubic } }
        Behavior on glowIntensity { enabled: pill.animateShader; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        Behavior on glowRadius    { enabled: pill.animateShader; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

        fragmentShader: "file:///home/user/.config/quickshell/clock/pill.frag.qsb"
    }

    // ── Gradient border ring ──
    Shape {
        id: borderRing
        anchors.fill: parent
        visible: pill.shaderEnabled

        ShapePath {
            strokeColor: "transparent"
            fillRule: ShapePath.OddEvenFill
            fillGradient: LinearGradient {
                x1: 0.870 * borderRing.width
                y1: 0.146 * borderRing.height
                x2: 0.586 * borderRing.width
                y2: 1.287 * borderRing.height
                GradientStop { position: 0.0;  color: Qt.rgba(1, 1, 1, 0.07) }
                GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0.00) }
                GradientStop { position: 0.78; color: Qt.rgba(1, 1, 1, 0.00) }
                GradientStop { position: 1.0;  color: Qt.rgba(1, 1, 1, 0.07) }
            }
            PathRectangle {
                x: 0; y: 0
                width: borderRing.width
                height: borderRing.height
                radius: pill._cornerRadius
            }
            PathRectangle {
                x: 2; y: 2
                width: borderRing.width - 4
                height: borderRing.height - 4
                radius: Math.max(0, pill._cornerRadius - 2)
            }
        }
    }

    // ── Hover + click tracker (below content so child MouseAreas get priority) ──
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: pill.interactive && !pill.expanded
        acceptedButtons: pill.interactive && !pill.expanded ? Qt.LeftButton : Qt.NoButton
        onClicked: pill.clicked()
    }

    // ── Content slot (default children go here, on top for input) ──
    Item {
        id: contentContainer
        anchors.fill: parent
    }
}
