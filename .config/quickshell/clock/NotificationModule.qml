pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Shapes

ShellRoot {
    id: root

    enum Mode { Idle, Compact, Big }

    // Two separate Wayland layer surfaces sharing the same state. The big
    // critical pill lives in bigPanel (below) so each surface gets its own
    // Hyprland blur pass — when they were one surface, the overlap region
    // between pill and bigPill combined alphas in ways that suppressed blur
    // under the big pill.
    readonly property bool _active: centerOpen || _isExpanded

    // Bell counter — alias of `notifCount` so the live list size can't drift
    // out of sync with the notification center (notifCount is Repeater-driven).
    readonly property int unreadCount: notifCount

    // Single source of truth: the currently-shown toast is the newest live
    // notification in `notifServer.trackedNotifications`, unless auto-hide
    // has "parked" it or the center is open (in which case there's no toast
    // to show). Dismissing a notification just removes it from tracked —
    // this binding re-evaluates and either picks the next-newest or becomes
    // null. No manual currentToast assignments anywhere.
    readonly property var _newestTracked: {
        const xs = notifs
        return xs && xs.length > 0 ? xs[xs.length - 1] : null
    }
    // Reference to the notification we've visually hidden but left tracked
    // (auto-expire, or user was in the center when it arrived). Cleared when
    // a new notification arrives so the fresh one surfaces as a toast.
    property var _autoHiddenToast: null
    readonly property var currentToast:
        !centerOpen
            && _newestTracked !== null
            && _newestTracked !== _autoHiddenToast
        ? _newestTracked : null
    readonly property bool hasToast: currentToast !== null

    readonly property alias server: notifServer
    readonly property alias bellAnchor: pill
    property bool centerOpen: false

    // Cached notification content. Updated whenever a new toast arrives;
    // persists across dismiss so hover-peek can show the last one. Summary
    // and body are tracked separately: compact/peek shows summary (short
    // glanceable line); big pill shows body (the detail that doesn't fit
    // in the compact form).
    property string _lastAppName: ""
    property string _lastSummary: ""
    property string _lastBody: ""
    property string _lastIcon: ""
    property string _lastTime: ""

    // Outer pill morphs through three `mode` states, all rendered as sub-pills
    // or overlays *inside* the single `pill`:
    //   Mode.Idle    — bell-only (flat or chipped by hover/peek)
    //   Mode.Compact — bell sub-pill + toast sub-pill side-by-side (36 tall)
    //   Mode.Big     — full-width rich content (276 × 54, critical only, 5s)
    // centerOpen is orthogonal: overrides width/height via activeWidth/Height.
    property int mode: NotificationModule.Mode.Idle

    // Geometric constants.
    readonly property int emptyPillWidth: 40
    readonly property int pillBottomMargin: 8
    readonly property int leftEdgePad: 8
    readonly property int currentPillWidth: pill ? pill.implicitWidth : emptyPillWidth
    // Right edge of whichever pill is currently widest on screen — either the
    // main pill (compact/center) or the critical bigPill (which extends past
    // the main pill's right edge during its 5s morph). Workspace panel uses
    // this so it stays clear of the bigPill during critical notifications.
    readonly property int currentPillRightEdge: {
        const mainRight = leftEdgePad + currentPillWidth
        // bigPill rests invisibly at toastSub dimensions when not critical
        // (shaderEnabled gate: _isBig || height > 25). Only count its width
        // while it's actually visually present — otherwise the workspace pill
        // would be shoved ~90px further right than the bell pill it sees.
        const bigVisible = bigPill && (_isBig || bigPill.height > 25)
        const bigRight = bigVisible ? (bigPill.x + bigPill.implicitWidth) : 0
        return Math.max(mainRight, bigRight)
    }

    readonly property int bigPillFullWidth: 276
    readonly property int bigPillHeight: 54
    readonly property int compactPillHeight: 36

    // Notification center (expanded pill) constants.
    readonly property int centerWidth: 302
    readonly property int centerCornerRadius: 16
    readonly property int centerTopPad: 16
    readonly property int centerSidePad: 16
    readonly property int centerBottomPad: 8
    readonly property int centerHeaderHeight: 26
    readonly property int centerGapAboveLine: 12
    readonly property int centerGapBelowLine: 12

    // Live list of tracked notifications for the expanded center.
    readonly property var notifs: notifServer && notifServer.trackedNotifications
        ? notifServer.trackedNotifications.values
        : []

    // Receipt timestamps (notif.id -> ms epoch), populated in onNotification.
    property var receivedAt: ({})

    // Palette — every color used by this module. Keeping them here makes the
    // theme easy to reshape and eliminates duplicated Qt.rgba literals.
    readonly property color fgPrimary:   Qt.rgba(1, 1, 1, 0.8)
    readonly property color fgSecondary: Qt.rgba(1, 1, 1, 0.5)
    readonly property color fgTertiary:  Qt.rgba(1, 1, 1, 0.3)
    readonly property color bgSubtle:    Qt.rgba(1, 1, 1, 0.10)
    readonly property color bgHover:     Qt.rgba(1, 1, 1, 0.18)
    readonly property color bgXRest:     Qt.rgba(1, 1, 1, 0.15)
    readonly property color bgXHot:      Qt.rgba(1, 1, 1, 0.35)
    readonly property color bgBig:       Qt.rgba(1, 1, 1, 0.20)
    readonly property color noColor:     Qt.rgba(0, 0, 0, 0)

    // Reactive notification count — bound to the Repeater deep inside the
    // center body. Repeater.count updates on model add/remove; using this
    // avoids the snapshot-nature of `trackedNotifications.values`.
    readonly property int notifCount: notifList ? notifList.count : 0

    // Cap for the notification list so the expanded pill fits inside the
    // fixed 500-tall mainPanel surface. Chrome (75) + body + bottomMargin (7)
    // + X overhang (~3) must all fit — past this point the Flickable scrolls.
    readonly property int maxCenterBodyHeight: 400

    // Computed height of the expanded pill: 75 of fixed chrome + body.
    // Empty body is a fixed 152 placeholder; populated body estimated at
    // 76px per item (36 chrome + up to 2 lines × 20px), capped at
    // maxCenterBodyHeight. Reading ListView.contentHeight directly caused
    // a binding loop via centerBody.height → ListView.height → contentHeight.
    readonly property int centerBodyHeight: notifCount === 0
        ? 152
        : Math.min(maxCenterBodyHeight, notifCount * 76)
    readonly property int centerHeight: centerTopPad + centerHeaderHeight + centerGapAboveLine
        + 1 + centerGapBelowLine + centerBodyHeight + centerBottomPad

    // Reusable X button (used by the compact-toast overlay AND each notification
    // item in the expanded center). Always 18×18, rounded-9, with an x.svg glyph.
    // Callers supply the `baseAlpha` (rest color) and wire `onClicked`.
    component XButton: Rectangle {
        id: xBtn
        signal clicked()
        property real baseAlpha: 0.15
        property real hotAlpha:  0.35
        readonly property alias hovered: _xMouse.containsMouse

        width: 18
        height: 18
        radius: 9
        color: _xMouse.containsMouse
            ? Qt.rgba(1, 1, 1, hotAlpha)
            : Qt.rgba(1, 1, 1, baseAlpha)
        Behavior on color { ColorAnimation { duration: 150 } }

        Image {
            anchors.centerIn: parent
            width: 12
            height: 12
            source: Qt.resolvedUrl("x.svg")
            sourceSize: Qt.size(24, 24)
            fillMode: Image.PreserveAspectFit
            smooth: true
        }

        MouseArea {
            id: _xMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: xBtn.clicked()
        }
    }

    // Hover-peek: when idle and any part of the pill (bell, toast card, or
    // the X overlay) is hovered, show the cached toast in compact form.
    // Each inner MouseArea steals hover in its own region, so we OR them all
    // together — missing any one creates dead zones where peek dies mid-move.
    // Requires at least one live notification; cached `_lastBody` alone is
    // not enough, else peek resurrects content the user already dismissed.
    readonly property bool _peekable: mode === NotificationModule.Mode.Idle
        && notifCount > 0
        && (bellHover.containsMouse
            || bellClick.containsMouse
            || toastInvoke.containsMouse
            || toastX.hovered)
        && (_lastSummary !== "" || _lastBody !== "")
    readonly property bool _isExpanded: mode !== NotificationModule.Mode.Idle || _peekable
    readonly property bool _isBig: mode === NotificationModule.Mode.Big

    // Sole state-transition handler — fires whenever the derived currentToast
    // flips (new arrival, user dismiss, auto-hide, center open/close, any of
    // the paths the old code had to mutate explicitly). Starts/stops timers,
    // caches content, and drives `mode` — nothing else touches those.
    onCurrentToastChanged: {
        criticalCompactTimer.stop()
        criticalBigTimer.stop()
        if (currentToast) {
            _lastAppName = currentToast.appName || "Notification"
            _lastSummary = currentToast.summary || ""
            _lastBody    = currentToast.body || ""
            _lastIcon    = currentToast.image || currentToast.appIcon || ""
            _lastTime    = Qt.formatTime(new Date(), "h:mmap").toLowerCase()
            mode = NotificationModule.Mode.Compact
            // Urgency-driven lifetime. Ignore sender's expireTimeout.
            //   Critical: 60s total (350ms compact morph + 5s big hold +
            //             ~54.65s compact after).
            //   Normal:   5s.
            //   Low:      2.5s (glance-and-go).
            toastLifeTimer.interval =
                currentToast.urgency === NotificationUrgency.Critical ? 60000
                : currentToast.urgency === NotificationUrgency.Low ? 2500
                : 5000
            toastLifeTimer.restart()
            if (currentToast.urgency === NotificationUrgency.Critical) {
                criticalCompactTimer.restart()
            }
        } else {
            mode = NotificationModule.Mode.Idle
            toastLifeTimer.stop()
        }
    }

    // When the user closes the center, mark whatever's newest as "already
    // seen" so closing doesn't resurface old notifications as fresh toasts.
    // A genuinely new arrival (below, in NotificationServer.onNotification)
    // clears this marker.
    onCenterOpenChanged: {
        if (!centerOpen) _autoHiddenToast = _newestTracked
    }

    NotificationServer {
        id: notifServer
        bodySupported: true
        actionsSupported: true
        imageSupported: true
        keepOnReload: true

        onNotification: (notif) => {
            notif.tracked = true

            // Record receipt time for the expanded center's timestamp column.
            const next = Object.assign({}, root.receivedAt)
            next[notif.id] = Date.now()
            root.receivedAt = next

            // Clear the auto-hide marker so this new notification surfaces
            // as a toast (if the center isn't already open). Everything else
            // — currentToast selection, mode, timers, caches — is driven by
            // the derived currentToast binding via onCurrentToastChanged.
            root._autoHiddenToast = null
        }
    }

    // Critical: 350ms compact → grow to big.
    Timer {
        id: criticalCompactTimer
        interval: 350
        repeat: false
        onTriggered: {
            root.mode = NotificationModule.Mode.Big
            criticalBigTimer.restart()
        }
    }
    // Critical: 5s in big → shrink back to compact (stays expanded).
    Timer {
        id: criticalBigTimer
        interval: 5000
        repeat: false
        onTriggered: root.mode = NotificationModule.Mode.Compact
    }

    // Auto-dismiss the active compact toast after a fixed window. Restarted
    // each time `currentToast` changes (new notif or promoted from dismiss).
    // Sender-supplied `expireTimeout` is ignored — apps commonly pass 0 /
    // -1 which would mean "never" and "server default" per the spec, and
    // we'd rather the shell always reclaims screen real estate.
    //   - Low      (urgency 0): 2.5s
    //   - Normal   (urgency 1): 5s
    //   - Critical (urgency 2): 60s  (350ms compact + 5s big + ~54.65s compact-after)
    Timer {
        id: toastLifeTimer
        interval: 5000
        repeat: false
        // Auto-expiry *hides* the toast but keeps the notification tracked
        // in the center for later review. Only user-initiated X / Clear
        // actually calls dismiss() on the Notification (which removes it
        // from notifServer.trackedNotifications).
        onTriggered: root.hideActiveToast()
    }

    // Remove a notification's receivedAt entry. Called from every dismiss path
    // so the map doesn't grow unbounded over long sessions.
    function _forgetReceivedAt(id) {
        if (id === undefined || !(id in receivedAt)) return
        const next = Object.assign({}, receivedAt)
        delete next[id]
        receivedAt = next
    }

    // Safe dismiss — a notification may have been destroyed externally between
    // when we captured the ref and when we call .dismiss(). Log & continue.
    function _safeDismiss(n) {
        if (!n) return
        try { n.dismiss() }
        catch (e) { console.warn("[NotifModule] dismiss failed:", e) }
    }

    // Dismiss the currently-shown toast. Removes the Notification from
    // notifServer.trackedNotifications; the `currentToast` derivation
    // automatically re-picks the next-newest (or becomes null) and
    // `onCurrentToastChanged` handles timers/mode.
    function dismissToast() {
        const t = currentToast
        if (!t) return
        const id = t.id
        _safeDismiss(t)
        _forgetReceivedAt(id)
    }

    // Called by the auto-expire timer — hides the visible toast without
    // dismissing the underlying Notification, so it stays in the center's
    // list for later review. The marker points at the current newest; the
    // derivation then yields null until either a new notification arrives
    // (which clears the marker in onNotification) or this one is dismissed
    // via the center.
    function hideActiveToast() {
        _autoHiddenToast = _newestTracked
    }

    // Invoke the notification's default action (what the spec calls "default")
    // — this is what opens Slack at the message, Claude Code at the terminal,
    // etc. Falls back to the first action if no explicit default is declared.
    // Always dismisses the toast afterwards so the pill returns to idle.
    function invokeActiveToast() {
        const t = currentToast
        if (!t) { dismissToast(); return }
        const actions = t.actions
        if (actions && actions.length > 0) {
            for (let i = 0; i < actions.length; i++) {
                if (actions[i].identifier === "default") {
                    actions[i].invoke()
                    dismissToast()
                    return
                }
            }
            actions[0].invoke()
        }
        dismissToast()
    }

    function clearAllNotifs() {
        const list = notifs.slice()
        for (let i = 0; i < list.length; i++) {
            const n = list[i]
            if (!n) continue
            const id = n.id
            _safeDismiss(n)
            _forgetReceivedAt(id)
        }
        // unreadCount tracks notifCount automatically, so no explicit reset.
    }

    function _formatTime(ms) {
        if (!ms) return ""
        const d = new Date(ms)
        const h = d.getHours() % 12 || 12
        const mm = d.getMinutes().toString().padStart(2, '0')
        const ap = d.getHours() >= 12 ? "pm" : "am"
        return h + ":" + mm + ap
    }

    // Dismiss the expanded center when the user clicks outside either pill.
    HyprlandFocusGrab {
        active: root.centerOpen
        windows: [mainPanel, bigPanel]
        onCleared: root.centerOpen = false
    }

    // ════════════════════════════════════════════════════════════════════
    // Main panel — hosts the bell + toast-carrier pill and the X overlay.
    // ════════════════════════════════════════════════════════════════════
    PanelWindow {
        id: mainPanel

        anchors.bottom: true
        anchors.left: true
        margins.bottom: 0
        margins.left: 0
        // Surface size is CONSTANT — same pattern as the music pill's 286×286
        // panel. The pill animates inside a static canvas; Hyprland never
        // resizes the layer-shell surface, so there is no frame race between
        // Qt's anchor recompute (pill.bottom_in_panel) and the compositor's
        // surface-top update — which previously caused the bell to teleport
        // at the end of the close animation when an inflation timer flipped
        // implicitHeight back from 500 → 70. The `mask` below restricts
        // input to the pill + X overlay so the rest of the 800×500
        // transparent area remains click-through for adjacent panels.
        implicitWidth: 800
        implicitHeight: 500
        color: "transparent"

        // Top (not Overlay) so bigPanel — which stays at Overlay — is always
        // rendered above mainPanel. Same-layer stacking within Overlay was
        // flipping the big pill underneath mainPanel's pill in the overlap
        // region; splitting layers guarantees the z-order.
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-clock"
        exclusionMode: ExclusionMode.Ignore

        // Only the pill and its X button capture clicks — the rest of the
        // 800-wide transparent surface falls through so other panels (settings
        // popup, clock, etc.) stay interactive next to the bell.
        mask: Region {
            item: pill
            Region { item: toastX }
        }

        // Catches clicks in transparent panel regions (outside the pill) when the
        // center is open — FocusGrab alone only fires for clicks routed to other
        // windows, not for clicks that land on the (transparent) PanelWindow itself.
        MouseArea {
            anchors.fill: parent
            enabled: root.centerOpen
            z: -100
            onClicked: root.centerOpen = false
        }

    // No explicit Connections { target: currentToast } anymore — external
    // close of any notification updates notifServer.trackedNotifications,
    // which flows into `_newestTracked` → `currentToast`, which triggers
    // `onCurrentToastChanged`. All state transitions go through that one
    // handler.

    // ════════════════════════════════════════════════════════════════════
    // Outer notification pill — hosts bell + optional toast sub-pill inside,
    // morphs to big (critical) or to notification center (centerOpen).
    // ════════════════════════════════════════════════════════════════════
    Pill {
        id: pill
        // Pinned to the left edge of the panel (8px inside the 800-wide
        // transparent surface). Growth extends rightward — the workspace
        // panel chases via notifMod.currentPillRightEdge so the 8px gap
        // stays constant as the pill expands/contracts.
        x: root.leftEdgePad
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.pillBottomMargin
        // Parent pill is ALWAYS compact-height. On critical, only the toast
        // content extracts itself into a separate bigPill above; the parent
        // keeps its expanded (bell + reserved toast slot) width so the bell
        // does not shift.
        pillHeight: root.compactPillHeight
        interactive: false

        // Expansion: when centerOpen is true, morph into the notification center
        // pill (302 × centerHeight, corner radius 16). Pill.qml's Behaviors on
        // implicitWidth/implicitHeight/_cornerRadius handle the animation.
        activeWidth:        root.centerOpen ? root.centerWidth : -1
        activeHeight:       root.centerOpen ? root.centerHeight : -1
        activeCornerRadius: root.centerOpen ? root.centerCornerRadius : -1

        // Chip mode = bell wrapped in a visible sub-pill bg. Purely a hover
        // affordance — never auto-activated by toast arrival. When a toast
        // arrives, nothing should be "hovered" until the user's cursor lands
        // on the bell (chipMode) or the toast sub-pill (its own bg).
        readonly property bool chipMode: bellClick.containsMouse

        // Bell sub-pill content width. Symmetric p=4 when no count, asymmetric
        // pl=4 pr=8 gap=4 when count shown.
        readonly property int bellSubWidth: root.unreadCount > 0
            ? (4 + 20 + 4 + unreadText.implicitWidth + 8)
            : (4 + 20 + 4)
        // Toast sub-pill: p=4 left + (icon 16 + gap 4 when icon is actually
        // shown) + text (max 220 before ellipsis, +30% on hover → 286) +
        // right padding. Right padding is 4 at rest, 12 when hovered — the
        // extra 8 carves space for the X overlay so it doesn't visually
        // overlap the text.
        //
        // Icon space must be conditional on visibility: when the sender
        // didn't provide an app-icon, the text's anchors shift to
        // parent.left so the bubble should shrink by 20px accordingly,
        // else the bubble has phantom empty space to the right of the text.
        readonly property int toastTextMax: 220
        // Use TextMetrics (not Text.implicitWidth) for the natural width.
        // Text.implicitWidth gets clamped to the anchored/elided width when
        // `elide: ElideRight + maximumLineCount: 1` + anchors.right are all
        // set — which is a binding loop: bubble.width depends on it, and it
        // depends on bubble.width via anchors. First-pass small width would
        // persist forever, eliding notifications that should have fit.
        readonly property int toastSubWidth: 4
            + (toastIcon.visible ? (16 + 4) : 0)
            + Math.min(toastTextMetrics.advanceWidth, toastTextMax)
            + (toastInvoke.containsMouse ? 12 : 4)

        collapsedWidth: {
            // _isExpanded is true for compact, big, AND peek — we keep the
            // toast-reserved width during big so the parent does not shrink
            // when the toast sub-pill hides.
            if (root._isExpanded) return 4 + bellSubWidth + toastSubWidth + 6
            if (chipMode) {
                return root.unreadCount > 0
                    ? (4 + bellSubWidth + 6)   // outer pl=4 pr=6
                    : (6 + bellSubWidth + 6)   // outer px=6
            }
            // Flat (idle, not hovered): outer px=10, bell centered, no chip bg.
            return 10 + 20 + (root.unreadCount > 0 ? 4 + unreadText.implicitWidth : 0) + 10
        }
        expandedWidth: collapsedWidth

        // ── Bell sub-pill background (visible only in chipMode) ──
        Rectangle {
            id: bellSubBg
            visible: !root.centerOpen
            x: root._isExpanded ? 4 : (root.unreadCount > 0 ? 4 : 6)
            y: (pill.height - height) / 2
            width: pill.bellSubWidth
            height: 28
            radius: 14
            color: pill.chipMode ? root.bgSubtle : root.noColor
            Behavior on color { ColorAnimation  { duration: 200 } }
            Behavior on x     { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        }

        // Bell glyph position, flattened from a 3-level ternary so the state
        // table reads clearly:
        //   centerOpen → slot at 16 (header position)
        //   chip-with-count / toast showing → 8 (outer pl=4 + sub pl=4)
        //   chip-without-count / flat → 10 (centered in a 40-wide pill)
        readonly property int _bellX: {
            if (root.centerOpen) return root.centerSidePad
            // _isExpanded covers compact/big/peek — bell always at x=8 in the
            // pl=4 pr=6 chip layout whenever toast width is reserved.
            if (root._isExpanded) return 8
            if (pill.chipMode && root.unreadCount > 0) return 8
            return 10
        }
        readonly property int _bellY: root.centerOpen
            ? root.centerTopPad
            : (root.compactPillHeight - 20) / 2

        // Bell glyph. Stays visible in big mode (parent pill does not collapse);
        // slides to header slot when center opens.
        Image {
            id: bellGlyph
            x: pill._bellX
            y: pill._bellY
            width: 20; height: 20
            source: Qt.resolvedUrl("bell.svg")
            sourceSize: Qt.size(40, 40)
            fillMode: Image.PreserveAspectFit
            smooth: true
            Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        }

        // Count / header text. Position follows the bell.
        // Collapsed: "6". Expanded: "6 Notifications".
        Text {
            id: unreadText
            visible: root.centerOpen || root.unreadCount > 0
            x: bellGlyph.x + 20 + 4
            // Vertically centered on the bell glyph (20px tall). Previous
            // `bellGlyph.y + 4` offset left the text baseline sitting below
            // the bell's visual center because 12px Geist's ascent puts the
            // cap height near the middle of the box — using verticalCenter
            // on the Text box matches the bell cleanly in both states.
            anchors.verticalCenter: bellGlyph.verticalCenter
            text: root.centerOpen
                ? (root.notifCount + " Notifications")
                : root.unreadCount.toString()
            color: root.fgPrimary
            font.family: "Geist"
            font.pixelSize: 12
            font.weight: Font.Medium
            font.letterSpacing: -0.12
        }

        // ── Toast sub-pill (right of bell sub-pill, inside the same outer pill) ──
        // Rounded-pill hover bg, independent of the bell's chip bg — so that
        // hovering the toast highlights only the toast, and the bell stays bare.
        Rectangle {
            id: toastSub
            visible: !root._isBig && !root.centerOpen && root._isExpanded
            x: 4 + pill.bellSubWidth
            y: (pill.height - height) / 2
            width: pill.toastSubWidth
            height: 24
            radius: 12
            // Driven by the dedicated top-stacked toastInvoke MouseArea
            // below — bellHover (also hover-enabled on the full pill) would
            // otherwise capture hover first and leave an inner MouseArea's
            // containsMouse flag flaky.
            color: toastInvoke.containsMouse ? root.bgSubtle : root.noColor
            Behavior on color { ColorAnimation { duration: 200 } }

            Image {
                id: toastIcon
                x: 4
                anchors.verticalCenter: parent.verticalCenter
                width: 16; height: 16
                source: root._lastIcon
                visible: source != ""
                sourceSize: Qt.size(32, 32)
                fillMode: Image.PreserveAspectFit
                smooth: true
            }
            Text {
                id: toastText
                anchors.left: toastIcon.visible ? toastIcon.right : parent.left
                anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                // Explicit width from TextMetrics, NOT anchors.right. Anchoring
                // both sides created a feedback loop (bubble.width ↔ text.width)
                // where the text would settle at a clamped value before the
                // metrics propagated, eliding short text that should have fit.
                // No Behavior: if width animates between values, the text
                // briefly has less room than its glyphs need and elides mid-
                // animation, causing a visible `"...→full→..."` flash. Snap
                // instantly instead — the outer pill still animates via its
                // own implicitWidth Behavior, hiding the width-jump here.
                width: Math.min(toastTextMetrics.advanceWidth, pill.toastTextMax)
                // Compact/peek shows the summary (short glance line). Fall
                // back to body for notifications that only send a body.
                text: root._lastSummary !== "" ? root._lastSummary : root._lastBody
                // Figma 341:668 (resting): rgba(255,255,255,0.7).
                // Figma 276:16321 (hover): brightens to full primary (0.8).
                color: toastInvoke.containsMouse ? root.fgPrimary : Qt.rgba(1, 1, 1, 0.7)
                Behavior on color { ColorAnimation { duration: 200 } }
                font.family: "Geist"
                font.pixelSize: 12
                font.weight: Font.Medium
                font.letterSpacing: -0.12
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            // Mirrors toastText's font + content and exposes the TRUE natural
            // width (advanceWidth). Used by toastSubWidth to break the binding
            // loop caused by Text.implicitWidth getting clamped when the Text
            // element is anchors-bound with elide + maximumLineCount.
            TextMetrics {
                id: toastTextMetrics
                text: toastText.text
                font: toastText.font
            }
        }

        // Full-pill hover detector — drives peek/chip-mode reveal. Click here
        // only OPENS the center; empty-pill clicks inside the expanded state
        // do nothing (so the user doesn't dismiss by clicking near an item).
        MouseArea {
            id: bellHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onClicked: if (!root.centerOpen) root.centerOpen = true
        }

        // Dedicated bell-glyph click target — declared AFTER bellHover so it
        // takes priority in the bell region. Toggles the center (opens when
        // closed, closes when open), giving the user a single predictable
        // control to flip the expanded view.
        MouseArea {
            id: bellClick
            x: pill._bellX - 4
            y: pill._bellY - 4
            width: 28
            height: 28
            hoverEnabled: true  // drives chipMode — bell-only hover state
            acceptedButtons: Qt.LeftButton
            onClicked: root.centerOpen = !root.centerOpen
        }

        // Toast-sub-pill click target — declared after bellHover/bellClick
        // so it wins clicks and hover over the toast region. Drives the
        // toast sub-pill's hover bg and invokes the notification's default
        // action (opens the source app's window when clicked, mirroring
        // what clicking a notification in GNOME/KDE does).
        MouseArea {
            id: toastInvoke
            x: toastSub.x
            y: toastSub.y
            width: toastSub.width
            height: toastSub.height
            visible: toastSub.visible
            enabled: toastSub.visible
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton
            onClicked: root.invokeActiveToast()
        }

        // ── Expanded content (Clear button, separator, body) ──────────────
        // Appears inside the morphing pill when centerOpen is true. Pill's
        // clip:true naturally hides everything until the pill grows wide/tall
        // enough to contain it.

        // Clear button (top-right of header row, same y as bell).
        Rectangle {
            id: clearBtn
            visible: root.centerOpen && root.notifCount > 0
            x: root.centerWidth - 45 - root.centerSidePad
            y: root.centerTopPad
            width: 45
            height: root.centerHeaderHeight
            radius: 13
            color: clearMouse.containsMouse ? root.bgHover : root.bgSubtle
            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
                anchors.centerIn: parent
                text: "Clear"
                color: root.fgPrimary
                font.family: "Geist"
                font.pixelSize: 10
                font.weight: Font.Medium
                font.letterSpacing: -0.1
            }

            MouseArea {
                id: clearMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.clearAllNotifs()
            }
        }

        // Separator line below header.
        Rectangle {
            id: centerSeparator
            visible: root.centerOpen
            x: root.centerSidePad
            y: root.centerTopPad + root.centerHeaderHeight + root.centerGapAboveLine
            width: root.centerWidth - 2 * root.centerSidePad
            height: 1
            color: root.bgSubtle
        }

        // Body container.
        Item {
            id: centerBody
            visible: root.centerOpen
            x: root.centerSidePad
            y: centerSeparator.y + 1 + root.centerGapBelowLine
            width: root.centerWidth - 2 * root.centerSidePad
            height: root.centerBodyHeight

            // Empty placeholder
            Text {
                visible: root.notifCount === 0
                anchors.centerIn: parent
                text: "No notifications"
                color: root.fgTertiary
                font.family: "Geist"
                font.pixelSize: 14
                font.weight: Font.Medium
            }

            // List of notification items — extends 8px into the side padding
            // on both sides for a wider hover target, matching Figma.
            //
            // Flickable + Column + Repeater instead of ListView because:
            //   1. Column auto-sizes to actual delegate heights (ListView's
            //      implicit height padding left empty space at the top when
            //      one short notification didn't fill a 76px slot estimate).
            //   2. Default TopToBottom flow; newest-first ordering is achieved
            //      by reversing the model's values array. BottomToTop with a
            //      single item anchored items to the bottom.
            //   3. Flickable wraps Column for scroll support when content
            //      exceeds the view's height cap.
            Flickable {
                id: notifList
                visible: root.notifCount > 0
                x: -8
                width: 286
                height: parent.height
                clip: true
                contentHeight: notifCol.height
                boundsBehavior: Flickable.StopAtBounds

                // Preserve the `count` property consumers relied on when this
                // was a ListView / Repeater — the parent reads notifList.count
                // to drive notifCount.
                readonly property alias count: notifRepeater.count

                Column {
                    id: notifCol
                    width: 286

                    Repeater {
                        id: notifRepeater
                        // Reversed snapshot: newest-first. `notifs` re-emits
                        // on trackedNotifications changes, so the slice stays
                        // fresh. Small N; the Repeater recreate cost is fine.
                        model: {
                            const arr = root.notifs
                            return arr ? arr.slice().reverse() : []
                        }

                        delegate: Rectangle {
                        id: item
                        required property var modelData
                        required property int index

                        readonly property string _body: modelData ? (modelData.body || modelData.summary || "") : ""
                        readonly property string _app: modelData ? (modelData.appName || "Notification") : ""
                        readonly property string _icon: modelData ? (modelData.image || modelData.appIcon || "") : ""
                        readonly property real _ts: (modelData && root.receivedAt)
                            ? (root.receivedAt[modelData.id] || 0)
                            : 0

                        width: 286
                        height: itemBody.contentHeight + 36  // 8 top-pad + 16 header + 4 gap + 8 bot-pad
                        radius: 12
                        color: itemHover.containsMouse ? root.bgSubtle : root.noColor
                        Behavior on color { ColorAnimation { duration: 150 } }

                        MouseArea {
                            id: itemHover
                            anchors.fill: parent
                            hoverEnabled: true
                        }

                        // X button — shared component. Positioned 5px inside the
                        // right edge and 3px above the top of the item.
                        XButton {
                            id: itemX
                            visible: itemHover.containsMouse || hovered
                            anchors.right: parent.right
                            anchors.rightMargin: 5
                            anchors.top: parent.top
                            anchors.topMargin: -3
                            onClicked: {
                                if (!item.modelData) return
                                const id = item.modelData.id
                                root._safeDismiss(item.modelData)
                                root._forgetReceivedAt(id)
                            }
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
                                    // QML warns when Row children anchor themselves,
                                    // so use Row's built-in cross-axis alignment.
                                    Image {
                                        width: 16; height: 16
                                        source: item._icon
                                        visible: source != ""
                                        sourceSize: Qt.size(32, 32)
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                    }
                                    Text {
                                        text: item._app
                                        color: root.fgSecondary
                                        font.family: "Geist"
                                        font.pixelSize: 12
                                        font.weight: Font.Medium
                                    }
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root._formatTime(item._ts)
                                    color: root.fgSecondary
                                    font.family: "Geist"
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                }
                            }

                            Text {
                                id: itemBody
                                anchors.top: itemHeader.bottom
                                anchors.topMargin: 4
                                anchors.left: parent.left
                                anchors.right: parent.right
                                text: item._body
                                color: root.fgPrimary
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
                        } // close delegate Rectangle
                    } // close Repeater
                } // close Column
            } // close Flickable (notifList)
        } // close centerBody Item
        } // end pill

        // ── X button — overlays top-right corner of the parent pill while
        // in compact/peek mode. Sibling of pill inside mainPanel, so its
        // anchors resolve (QML requires parent-or-sibling relationship).
        // Big-mode X lives in bigPanel.
        XButton {
            id: toastX
            // Show only when the cursor is over the toast card (or the X
            // itself) — hovering elsewhere on the pill (e.g. the bell) no
            // longer reveals the X, matching the Figma's hover behavior.
            visible: !root.centerOpen && !root._isBig && root._isExpanded
                && (toastInvoke.containsMouse || hovered)
            anchors.right: pill.right
            anchors.rightMargin: 5
            anchors.top: pill.top
            anchors.topMargin: -3
            baseAlpha: 0.15
            onClicked: root.dismissToast()
        }
    } // end mainPanel

    // ════════════════════════════════════════════════════════════════════
    // Big panel — own layer surface so Hyprland can blur behind bigPill
    // without the overlap-alpha issue that killed blur when both pills
    // shared one surface. Matches mainPanel's anchoring/width so the
    // bigPill lines up horizontally with the toast sub-pill's x offset.
    // ════════════════════════════════════════════════════════════════════
    PanelWindow {
        id: bigPanel

        anchors.bottom: true
        anchors.left: true
        margins.bottom: 0
        margins.left: 0
        // Constant 800 for the same reason as mainPanel — surface-width toggles
        // cause bigPill.x to jump mid-animation.
        implicitWidth: 800
        // Fixed 500 to match mainPanel — bigPill anchors to bigPanel.bottom,
        // so a stable surface height keeps bigPill's absolute y in lockstep
        // with toastSub's (which lives in mainPanel) during the morph.
        implicitHeight: 500
        color: "transparent"

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-clock"
        exclusionMode: ExclusionMode.Ignore

        // Input mask — only bigPill and its X button capture clicks. The
        // rest of the 800-wide panel falls through to mainPanel below, so
        // the bell (and the compact toast, which shares bigPill's rest
        // geometry) stays hoverable/clickable when bigPill is invisible.
        // Gated on the same threshold as shaderEnabled: when bigPill is
        // resting at toastSub's dimensions (no shader drawn), the mask
        // collapses to zero area so toastSub receives pointer events.
        readonly property bool _maskActive: root._isBig || bigPill.height > 25
        mask: Region {
            x: bigPill.x
            y: bigPill.y
            width:  bigPanel._maskActive ? bigPill.width  : 0
            height: bigPanel._maskActive ? bigPill.height : 0
            Region {
                x: bigToastX.x
                y: bigToastX.y
                width:  bigPanel._maskActive ? bigToastX.width  : 0
                height: bigPanel._maskActive ? bigToastX.height : 0
            }
        }

        Pill {
            id: bigPill
            // Align to where the toast sub-pill sits inside mainPanel: both
            // panels share left-edge anchoring, so the same math yields the
            // same absolute x (leftEdgePad + outer pl=4 + bellSubWidth).
            x: root.leftEdgePad + 4 + pill.bellSubWidth
            anchors.bottom: parent.bottom
            // Compact-state bottom aligns with the toast sub-pill's bottom
            // (6px above the bell pill's bottom edge). Big-state bottom
            // aligns with the bell pill's bottom. Animating the margin +
            // Pill's Behavior on height together produces a continuous
            // morph from toastSub geometry to big geometry.
            anchors.bottomMargin: root._isBig
                ? root.pillBottomMargin
                : root.pillBottomMargin + 6
            Behavior on anchors.bottomMargin {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
            // Interactive so Pill's internal mouseArea drives `hovered`,
            // which in turn swaps restFill1/2 → hoverFill1/2 per Figma
            // 295:16784. clicked() signal is unwired — clicks in the body
            // are a no-op (dismiss goes through bigToastX).
            interactive: true

            // Figma fill gradient alphas (295:16777 rest, 295:16784 hover).
            // Neutral white brighter-on-hover, not the default amber.
            restFill1:  Qt.rgba(1, 1, 1, 0.048)
            restFill2:  Qt.rgba(1, 1, 1, 0.12)
            hoverFill1: Qt.rgba(1, 1, 1, 0.08)
            hoverFill2: Qt.rgba(1, 1, 1, 0.20)
            // No glow — Figma shows only a fill brighten on hover.
            glowEnabled: false

            // 300ms morph — matches the compact-pill cadence for a snappy
            // grow from the toast position.
            animationDuration: 300
            // Fill/glow snap instantly — a 5s-long glow crossfade on top of
            // the size morph would read as the pill slowly "filling in" from
            // clear, which feels wrong for an alert. Only size animates.
            animateShader: false

            // Start at the compact toast's dimensions (24 × toastSubWidth) so
            // the morph appears to grow OUT OF the compact toast, and ends at
            // the big pill's full size (54 × 276). shaderEnabled below hides
            // the pill fill/border while in compact state so it doesn't ghost
            // over toastSub underneath.
            pillHeight:     root._isBig ? root.bigPillHeight    : 24
            collapsedWidth: root._isBig ? root.bigPillFullWidth : pill.toastSubWidth
            expandedWidth:  collapsedWidth
            // Lock the corner radius to the full-pill value; without this,
            // Pill._cornerRadius = height/2 would jump as pillHeight changes.
            activeCornerRadius: root.bigPillHeight / 2
            // Fill/border visible only once the pill has grown past the
            // compact size — keeps bigPill invisible when it's resting at
            // toastSub dimensions, visible throughout the morph in both
            // directions. Symmetric: growth crosses 24 quickly, shrink
            // shows the fill all the way down to ~24.
            shaderEnabled: root._isBig || height > 25

            // Content only renders once the pill has grown enough to hold
            // it without the 24×24 icon and multi-line text being squished
            // or clipped. Threshold mirrors shaderEnabled: appears on grow,
            // disappears on shrink.
            readonly property bool _contentVisible: root._isBig || height > 40

            Image {
                id: bigImage
                x: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 24; height: 24
                source: root._lastIcon
                visible: bigPill._contentVisible && source != ""
                sourceSize: Qt.size(48, 48)
                fillMode: Image.PreserveAspectFit
                smooth: true
            }
            // Column auto-sizes to its children's actual rendered heights
            // (font ascent + descent), so the block stays tight and the
            // verticalCenter anchor lands the visual middle of the text on
            // the pill's centerline — the previous fixed-height Item left
            // extra baseline slack below the body, pushing it visibly low.
            Column {
                id: bigTextCol
                visible: bigPill._contentVisible
                anchors.left: bigImage.visible ? bigImage.right : parent.left
                anchors.leftMargin: bigImage.visible ? 8 : 12
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Item {
                    width: parent.width
                    height: bigAppName.implicitHeight

                    Text {
                        id: bigAppName
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root._lastAppName
                        color: root.fgPrimary
                        font.family: "Geist"
                        font.pixelSize: 12
                        font.weight: Font.Normal
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root._lastTime
                        color: root.fgSecondary
                        font.family: "Geist"
                        font.pixelSize: 12
                        font.weight: Font.Normal
                    }
                }
                Text {
                    width: parent.width
                    // Big pill reveals the detail that the compact toast
                    // couldn't fit — prefer body, fall back to summary when
                    // the notification only sent a summary.
                    text: root._lastBody !== "" ? root._lastBody : root._lastSummary
                    color: root.fgPrimary
                    font.family: "Geist"
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    font.letterSpacing: -0.14
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }
        }

        // X button for big mode — anchored to bigPill inside this panel.
        // Uses bigPill.hovered (Pill.qml's internal MouseArea alias) so the
        // hover source is SHARED with the Pill's own fill/hover-color logic;
        // a previous dedicated MouseArea on top intercepted hover events and
        // left bigPill.hovered false (the hover fill only activated on click,
        // when the click event punched through).
        XButton {
            id: bigToastX
            visible: !root.centerOpen && root._isBig && (hovered || bigPill.hovered)
            anchors.right: bigPill.right
            anchors.rightMargin: 4
            anchors.top: bigPill.top
            anchors.topMargin: -5
            baseAlpha: 0.20
            onClicked: root.dismissToast()
        }
    } // end bigPanel
} // end ShellRoot
