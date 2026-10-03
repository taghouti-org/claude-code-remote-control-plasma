#!/bin/bash
set -e

# Claude Remote Control for KDE Plasma 6
# Runs `claude remote-control` as a systemd user service that starts at boot,
# plus a `claude-rc` helper and a Plasma 6 panel widget showing its status.
#
# Folder for remote sessions (must not be your home folder itself):
#   CLAUDE_RC_DIR=~/some/project bash install-claude-rc.sh

RC_DIR="${CLAUDE_RC_DIR:-$HOME/claude-remote}"
RC_DIR="${RC_DIR/#\~/$HOME}"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SRC_DIR="$HOME/.local/src/plasma-claude-rc"
WIDGET_ID="org.taghouti.clauderc"

CLAUDE_BIN="$(command -v claude || true)"
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
if [ -z "$CLAUDE_BIN" ]; then
    echo "claude not found: install Claude Code first (https://code.claude.com)." >&2
    exit 1
fi
if [ "$(realpath -m "$RC_DIR")" = "$(realpath "$HOME")" ]; then
    echo "Remote Control can't run in your home folder itself; set CLAUDE_RC_DIR to a subfolder." >&2
    exit 1
fi

echo "==> Folder for remote sessions: $RC_DIR"
mkdir -p "$RC_DIR" "$BIN_DIR" "$UNIT_DIR"

echo "==> Installing the claude-rc helper..."
cat > "$BIN_DIR/claude-rc" << 'EOF_CLAUDE_RC'
#!/bin/bash
# Control and inspect the Claude Remote Control service (~/.config/systemd/user/claude-remote-control.service)
UNIT=claude-remote-control.service

status_json() {
    local state inv log connected capacity url
    state=$(systemctl --user is-active "$UNIT")
    inv=$(systemctl --user show -p InvocationID --value "$UNIT")
    connected=false; capacity=""; url=""
    if [ -n "$inv" ]; then
        log=$(journalctl --user _SYSTEMD_INVOCATION_ID="$inv" -o cat -n 60 --no-pager -q 2>/dev/null \
              | sed 's/\x1b\][^\x1b]*\x1b\\//g; s/\x1b\[[0-9;?]*[a-zA-Z]//g')
        last=$(echo "$log" | grep -E 'Connected|Connecting|Reconnecting|Disconnected' | tail -1)
        echo "$last" | grep -q 'Connected' && ! echo "$last" | grep -qE 'Disconnected|Reconnecting' && connected=true
        capacity=$(echo "$log" | grep -oE 'Capacity: [0-9]+/[0-9]+' | tail -1 | cut -d' ' -f2)
        url=$(echo "$log" | grep -oE 'https://claude\.ai/code\?environment=[A-Za-z0-9_]+' | tail -1)
    fi
    [ "$state" = active ] || connected=false
    dir=$(systemctl --user show -p WorkingDirectory --value "$UNIT" | sed "s|^$HOME|~|")
    printf '{"state":"%s","connected":%s,"sessions":"%s","url":"%s","enabled":"%s","dir":"%s"}\n' \
        "$state" "$connected" "$capacity" "$url" "$(systemctl --user is-enabled "$UNIT" 2>/dev/null)" "$dir"
}

case "$1" in
    start|stop|restart) systemctl --user "$1" "$UNIT" ;;
    json) status_json ;;
    logs) journalctl --user -u "$UNIT" -f -o cat ;;
    ""|status) status_json | python3 -c '
import json, sys
d = json.load(sys.stdin)
conn = "connected" if d["connected"] else "not connected"
print("Claude Remote Control: %s, %s, sessions %s, folder %s, start at boot: %s"
      % (d["state"], conn, d["sessions"] or "-", d["dir"], d["enabled"]))
if d["url"]:
    print(d["url"])' ;;
    *) echo "usage: claude-rc [status|json|start|stop|restart|logs]" >&2; exit 2 ;;
esac
EOF_CLAUDE_RC
chmod +x "$BIN_DIR/claude-rc"

echo "==> Installing claude-remote-control.service..."
cat > "$UNIT_DIR/claude-remote-control.service" << EOF_CLAUDE_RC
[Unit]
Description=Claude Code Remote Control server ($RC_DIR)
Documentation=https://code.claude.com/docs/en/remote-control

[Service]
WorkingDirectory=$RC_DIR
ExecStart=$CLAUDE_BIN remote-control
# Retry until the network is up at boot, and after crashes or sign-in hiccups
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
EOF_CLAUDE_RC
systemctl --user daemon-reload
systemctl --user enable --now claude-remote-control.service

echo "==> Letting it start at boot, before you log in..."
loginctl enable-linger "$(id -un)" || echo "   (couldn't enable lingering; it will start when you log in instead)"

if command -v kpackagetool6 >/dev/null; then
    echo "==> Installing the Plasma 6 widget..."
    mkdir -p "$SRC_DIR/contents/ui"
    cat > "$SRC_DIR/metadata.json" << 'EOF_CLAUDE_RC'
{
    "KPlugin": {
        "Id": "org.taghouti.clauderc",
        "Name": "Claude Remote Control",
        "Description": "Shows and controls the Claude Code Remote Control service (claude-remote-control.service).",
        "Icon": "network-connect",
        "Authors": [{ "Name": "Tarek" }],
        "Category": "System Information",
        "License": "GPL",
        "Version": "1.0"
    },
    "KPackageStructure": "Plasma/Applet",
    "X-Plasma-API-Minimum-Version": "6.0"
}
EOF_CLAUDE_RC
    cat > "$SRC_DIR/contents/ui/main.qml" << 'EOF_CLAUDE_RC'
// Claude Remote Control: shows the state of claude-remote-control.service (via the claude-rc helper)
// and lets you start, stop and restart it or open its environment on claude.ai.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string helper: "$HOME/.local/bin/claude-rc"
    readonly property string statusCmd: helper + " json"

    property string svcState: "unknown"
    property bool connected: false
    property string sessions: ""
    property string envUrl: ""
    property string workDir: ""
    property bool atBoot: false
    property bool busy: false

    readonly property bool running: svcState === "active"
    readonly property string statusText: !running ? (svcState === "activating" ? "Starting…" : "Stopped")
                                         : connected ? "Connected" : "Connecting…"

    Plasmoid.icon: connected ? "network-connect" : "network-disconnect"
    toolTipMainText: "Claude Remote Control"
    toolTipSubText: statusText + (running && sessions ? " · sessions " + sessions : "")

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            if (sourceName === root.statusCmd) {
                try {
                    const s = JSON.parse(data["stdout"])
                    root.svcState = s.state
                    root.connected = s.connected
                    root.sessions = s.sessions
                    root.envUrl = s.url
                    root.workDir = s.dir
                    root.atBoot = s.enabled === "enabled"
                } catch (e) {
                    root.svcState = "unknown"
                    root.connected = false
                }
            } else {
                root.busy = false
                root.refresh()
            }
            disconnectSource(sourceName)
        }
    }

    function refresh() {
        executable.connectSource(statusCmd)
    }

    function run(action) {
        if (busy) {
            return
        }
        busy = true
        executable.connectSource(helper + " " + action)
    }

    Timer {
        interval: root.expanded ? 2000 : 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    compactRepresentation: MouseArea {
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: Plasmoid.icon
            active: parent.containsMouse
            opacity: root.connected ? 1 : 0.6
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        spacing: Kirigami.Units.smallSpacing

        PlasmaExtras.Heading {
            level: 3
            text: "Claude Remote Control"
            Layout.fillWidth: true
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                width: Kirigami.Units.smallSpacing * 2
                height: width
                radius: width / 2
                color: root.connected ? Kirigami.Theme.positiveTextColor
                     : root.running ? Kirigami.Theme.neutralTextColor
                     : Kirigami.Theme.negativeTextColor
            }
            PlasmaComponents3.Label {
                text: root.statusText
            }
        }

        PlasmaComponents3.Label {
            text: "Sessions: " + (root.running && root.sessions ? root.sessions : "–")
            opacity: 0.8
        }
        PlasmaComponents3.Label {
            text: "Folder: " + (root.workDir || "–") + (root.atBoot ? " · starts at boot" : "")
            opacity: 0.8
        }

        RowLayout {
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Button {
                icon.name: root.running ? "media-playback-stop" : "media-playback-start"
                text: root.running ? "Stop" : "Start"
                enabled: !root.busy
                onClicked: root.run(root.running ? "stop" : "start")
            }
            PlasmaComponents3.Button {
                icon.name: "view-refresh"
                text: "Restart"
                enabled: !root.busy && root.running
                onClicked: root.run("restart")
            }
        }

        PlasmaComponents3.Button {
            Layout.fillWidth: true
            icon.name: "internet-web-browser"
            text: "Open in browser"
            enabled: root.connected && root.envUrl !== ""
            onClicked: Qt.openUrlExternally(root.envUrl)
        }
    }
}
EOF_CLAUDE_RC
    if kpackagetool6 -t Plasma/Applet -s "$WIDGET_ID" >/dev/null 2>&1; then
        kpackagetool6 -t Plasma/Applet -u "$SRC_DIR"
    else
        kpackagetool6 -t Plasma/Applet -i "$SRC_DIR"
    fi
else
    echo "==> kpackagetool6 not found: skipping the widget (it needs KDE Plasma 6)."
fi

TRUSTED=$(python3 -c "import json,sys; d=json.load(open('$HOME/.claude.json')); print(d.get('projects',{}).get(sys.argv[1],{}).get('hasTrustDialogAccepted',False))" "$RC_DIR" 2>/dev/null || echo False)
echo
if [ "$TRUSTED" != "True" ]; then
    echo "ONE MORE STEP: Claude must trust $RC_DIR before Remote Control can start there."
    echo "  cd \"$RC_DIR\" && claude      # choose \"Yes, I trust this folder\", then /exit"
    echo "The service retries every 30 s and connects once the folder is trusted."
    echo
fi
echo "Done. Check it with: claude-rc"
echo "Add the widget: right-click the panel > Add Widgets... > search \"Claude Remote Control\"."
