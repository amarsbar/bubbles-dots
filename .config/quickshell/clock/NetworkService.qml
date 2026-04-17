import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // Keyed by SSID: { ssid, signal, security, connected, saved }
    property var networks: ({})
    property string connectedSsid: ""
    property bool wifiEnabled: true
    property bool busy: false
    property string lastError: ""

    property var _savedNames: ({})

    signal scanFinished()
    signal connectResult(string ssid, bool ok, string error)

    readonly property int connectedSignal: {
        const n = networks[connectedSsid]
        return n ? n.signal : 0
    }

    function _isSecured(sec) {
        return sec && sec !== "--" && sec !== ""
    }

    function scan() {
        if (!scanProc.running) scanProc.running = true
    }

    function connect(ssid, password) {
        if (busy) return
        busy = true
        lastError = ""
        connectProc.targetSsid = ssid
        if (password && password.length > 0) {
            connectProc.command = ["nmcli", "-t", "device", "wifi", "connect", ssid, "password", password]
        } else {
            connectProc.command = ["nmcli", "-t", "device", "wifi", "connect", ssid]
        }
        connectProc.running = true
    }

    function disconnect(ssid) {
        if (busy || !ssid) return
        busy = true
        lastError = ""
        disconnectProc.command = ["nmcli", "-t", "connection", "down", "id", ssid]
        disconnectProc.running = true
    }

    function setWifiEnabled(enabled) {
        radioProc.command = ["nmcli", "radio", "wifi", enabled ? "on" : "off"]
        radioProc.running = true
        wifiEnabled = enabled
    }

    // ── Saved connections process ──
    Process {
        id: savedProc
        command: ["nmcli", "-t", "-f", "NAME", "connection", "show"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const names = {}
                const lines = text.split('\n')
                for (const line of lines) {
                    const trimmed = line.trim()
                    if (trimmed) names[trimmed] = true
                }
                root._savedNames = names
            }
        }
    }

    // ── Scan process ──
    Process {
        id: scanProc
        command: ["nmcli", "-t", "-f", "IN-USE,SSID,SECURITY,SIGNAL", "device", "wifi", "list", "--rescan", "auto"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                function parseFields(line) {
                    const out = []
                    let cur = ""
                    for (let i = 0; i < line.length; i++) {
                        const c = line[i]
                        if (c === '\\' && i + 1 < line.length && line[i + 1] === ':') {
                            cur += ':'
                            i++
                        } else if (c === ':') {
                            out.push(cur)
                            cur = ""
                        } else {
                            cur += c
                        }
                    }
                    out.push(cur)
                    return out
                }

                const result = {}
                let connected = ""
                const lines = text.split('\n')
                for (const line of lines) {
                    if (!line) continue
                    const parts = parseFields(line)
                    if (parts.length < 4) continue
                    const inUse  = parts[0]
                    const ssid   = parts[1]
                    const sec    = parts[2]
                    const signal = parseInt(parts[3], 10) || 0
                    if (!ssid) continue
                    const prev = result[ssid]
                    if (!prev || signal > prev.signal) {
                        result[ssid] = {
                            ssid: ssid,
                            signal: signal,
                            security: sec,
                            secured: root._isSecured(sec),
                            connected: inUse === "*",
                            saved: ssid in root._savedNames
                        }
                    }
                    if (inUse === "*") connected = ssid
                }
                console.log("NET-DEBUG scan parsed", Object.keys(result).length, "networks, connected:", connected)
                root.networks = result
                root.connectedSsid = connected
                root.scanFinished()
            }
        }
    }

    // ── Connect process ──
    Process {
        id: connectProc
        running: false
        property string targetSsid: ""
        property string _stderr: ""
        stdout: StdioCollector { onStreamFinished: {} }
        stderr: StdioCollector { onStreamFinished: connectProc._stderr = text }
        onExited: (code, status) => {
            root.busy = false
            const ok = code === 0
            if (!ok) root.lastError = connectProc._stderr.trim()
            else root.lastError = ""
            root.connectResult(connectProc.targetSsid, ok, root.lastError)
            savedProc.running = true
            root.scan()
        }
    }

    // ── Disconnect process ──
    Process {
        id: disconnectProc
        running: false
        onExited: (code, status) => {
            root.busy = false
            savedProc.running = true
            root.scan()
        }
    }

    // ── Radio toggle process ──
    Process {
        id: radioProc
        running: false
        onExited: (code, status) => root.scan()
    }

    // ── Initial + periodic scan ──
    Component.onCompleted: { savedProc.running = true; scan() }
    Timer {
        interval: 15000
        running: true
        repeat: true
        onTriggered: root.scan()
    }
}
