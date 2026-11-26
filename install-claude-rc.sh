#!/bin/bash
set -e

# Claude Remote Control for KDE Plasma 6
# Runs `claude remote-control` as a systemd user service that starts at boot,
# plus a `claude-rc` helper and a Plasma 6 panel widget showing its status
# and your Claude usage (plan limits, tokens, estimated cost) with alerts.
#
# Folder for remote sessions (must not be your home folder itself):
#   CLAUDE_RC_DIR=~/some/project bash install-claude-rc.sh

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
# When upgrading, keep the folder the installed service already uses
EXISTING_DIR="$(sed -n 's/^WorkingDirectory=//p' "$UNIT_DIR/claude-remote-control.service" 2>/dev/null | head -1)"
RC_DIR="${CLAUDE_RC_DIR:-${EXISTING_DIR:-$HOME/claude-remote}}"
RC_DIR="${RC_DIR/#\~/$HOME}"
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
# Written to a new file and moved into place, so a running service keeps reading
# its old copy instead of a script that changes underneath it
cat > "$BIN_DIR/claude-rc.new" << 'EOF_CLAUDE_RC'
#!/bin/bash
# Control and inspect the Claude Remote Control service (~/.config/systemd/user/claude-remote-control.service)
UNIT=claude-remote-control.service
# Written by `claude-rc run` whenever the connection switches between "up" and "down"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/claude-rc.state"
# Restart Remote Control if it stays disconnected/reconnecting this long (seconds)
WATCHDOG_SECS="${CLAUDE_RC_WATCHDOG_SECS:-60}"

# Summarises usage from the local session logs and saved plan limits
USAGE_TOOL="$(dirname "$(readlink -f "$0")")/claude-rc-usage"

# Plan limits (5-hour and weekly) are only reported by Claude Code to its
# status line command. statusline-setup registers `claude-rc statusline` as that
# command in ~/.claude/settings.json, keeping any status line you already have:
# yours still produces the text, claude-rc only records the limits on the way.
statusline_config() {
    python3 - "$1" "$(readlink -f "$0")" << 'EOF_PY'
import json, os, shlex, shutil, sys, time
action, helper = sys.argv[1], sys.argv[2]
path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "settings.json")
try:
    with open(path, encoding="utf-8") as fh:
        settings = json.load(fh)
except FileNotFoundError:
    settings = {}
except ValueError:
    sys.exit("%s is not valid JSON; fix it first, nothing was changed." % path)
ours = shlex.quote(helper) + " statusline"
current = settings.get("statusLine")
command = current.get("command", "") if isinstance(current, dict) else ""
if action == "statusline-setup":
    if command.startswith(ours):
        print("Already set up."); sys.exit(0)
    if command:
        new = dict(current, command=ours + " -- sh -c " + shlex.quote(command))
        print("Kept your existing status line; claude-rc now records the plan limits it receives.")
    else:
        new = {"type": "command", "command": ours}
        print("Status line set. It shows the model and how much of each plan limit is used.")
    settings["statusLine"] = new
else:
    if not command.startswith(ours):
        print("claude-rc is not the status line command; nothing to remove."); sys.exit(0)
    wrapped = command[len(ours):].strip()
    if wrapped.startswith("-- sh -c "):
        settings["statusLine"] = dict(current, command=shlex.split(wrapped[len("-- sh -c "):])[0])
        print("Restored your own status line.")
    else:
        del settings["statusLine"]
        print("Status line removed.")
if os.path.exists(path):
    shutil.copy2(path, "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S")))
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print("Updated %s (a backup was saved next to it)." % path)
if action == "statusline-setup":
    print("Plan limits appear in the widget after your next Claude Code message.")
EOF_PY
}

status_json() {
    local state inv log connected capacity url
    state=$(systemctl --user is-active "$UNIT")
    inv=$(systemctl --user show -p InvocationID --value "$UNIT")
    connected=false; capacity=""; url=""
    if [ -n "$inv" ]; then
        log=$(journalctl --user _SYSTEMD_INVOCATION_ID="$inv" -o cat -n 60 --no-pager -q 2>/dev/null \
              | sed 's/\x1b\][^\x1b]*\x1b\\//g; s/\x1b\[[0-9;?]*[a-zA-Z]//g')
        [ "$(cat "$STATE_FILE" 2>/dev/null)" = up ] && connected=true
        capacity=$(echo "$log" | grep -oE 'Capacity: [0-9]+/[0-9]+' | tail -1 | cut -d' ' -f2)
        url=$(echo "$log" | grep -oE 'https://claude\.ai/code\?environment=[A-Za-z0-9_]+' | tail -1)
    fi
    [ "$state" = active ] || connected=false
    dir=$(systemctl --user show -p WorkingDirectory --value "$UNIT" | sed "s|^$HOME|~|")
    printf '{"state":"%s","connected":%s,"sessions":"%s","url":"%s","enabled":"%s","dir":"%s"}\n' \
        "$state" "$connected" "$capacity" "$url" "$(systemctl --user is-enabled "$UNIT" 2>/dev/null)" "$dir"
}

run_server() {
    # Used by the service. Runs Remote Control and:
    # - passes on only lines that changed. Remote Control redraws its status block
    #   several times a second, which would otherwise flood the journal. Lines are
    #   keyed with digits masked, so "Capacity: 1/32" -> "2/32" is still logged;
    #   all connection-state lines share one key so state changes are always logged.
    # - records the connection state ("up"/"down") in $STATE_FILE when it changes.
    # - watchdog: if the state stays "down" for $WATCHDOG_SECS, stops Remote Control
    #   so systemd restarts it (it can sit in "Reconnecting" for a long time).
    local claude_bin="${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
    echo down > "$STATE_FILE"
    "$claude_bin" remote-control "$@" > >(awk -v sf="$STATE_FILE" '
        function setstate(s) { if (s != cur) { cur = s; print s > sf; close(sf) } }
        {
            line = $0
            plain = line
            gsub(/\033\][^\033]*\033\\/, "", plain)
            gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", plain)
            if (plain ~ /^[[:space:]]*$/) next
            if (plain ~ /Reconnected after/) setstate("up")
            else if (plain ~ /Reconnecting|Disconnected|Connecting/) setstate("down")
            else if (plain ~ /Connected/) setstate("up")
            if (plain ~ /Connected|Connecting|Reconnecting|Disconnected|Reconnected/) key = "state"
            else { key = plain; gsub(/[0-9]+/, "N", key) }
            if (last[key] != plain) { last[key] = plain; print line; fflush() }
        }') 2>&1 &
    local pid=$!
    trap 'kill -TERM "$pid" 2>/dev/null' TERM INT

    while kill -0 "$pid" 2>/dev/null; do
        sleep 10 & wait $!
        if [ "$(cat "$STATE_FILE" 2>/dev/null)" = down ]; then
            local down_for=$(( $(date +%s) - $(stat -c %Y "$STATE_FILE") ))
            if [ "$down_for" -ge "$WATCHDOG_SECS" ]; then
                echo "claude-rc watchdog: not connected for ${down_for}s, restarting Remote Control"
                kill -TERM "$pid" 2>/dev/null
                for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
                kill -KILL "$pid" 2>/dev/null
                exit 1
            fi
        fi
    done
    wait "$pid"
}

case "$1" in
    run) shift; run_server "$@" ;;
    start|stop|restart) systemctl --user "$1" "$UNIT" ;;
    json) status_json ;;
    logs) journalctl --user -u "$UNIT" -f -o cat ;;
    usage) exec "$USAGE_TOOL" ;;
    statusline) shift; exec "$USAGE_TOOL" --statusline "$@" ;;
    statusline-setup|statusline-remove) statusline_config "$1" ;;
    ""|status) status_json | python3 -c '
import json, sys
d = json.load(sys.stdin)
conn = "connected" if d["connected"] else "not connected"
print("Claude Remote Control: %s, %s, sessions %s, folder %s, start at boot: %s"
      % (d["state"], conn, d["sessions"] or "-", d["dir"], d["enabled"]))
if d["url"]:
    print(d["url"])' ;;
    *) echo "usage: claude-rc [status|json|usage|start|stop|restart|logs|run|statusline-setup|statusline-remove]" >&2; exit 2 ;;
esac
EOF_CLAUDE_RC
chmod +x "$BIN_DIR/claude-rc.new"
mv -f "$BIN_DIR/claude-rc.new" "$BIN_DIR/claude-rc"

echo "==> Installing the claude-rc-usage helper..."
cat > "$BIN_DIR/claude-rc-usage.new" << 'EOF_CLAUDE_RC'
#!/usr/bin/env python3
"""Summarises Claude Code usage from the local session logs (~/.claude/projects).

Prints one JSON object: the current 5-hour window, today, the last 7 days and a
per-model breakdown, in tokens and in API-equivalent cost. Nothing leaves the
machine. Results are cached per log file, so repeated runs only read new lines.

With --statusline it acts as a Claude Code status line command instead: it
saves the plan limits Claude Code reports (rate_limits) for the summary above,
then prints a short status line, or runs the command given after "--" and
prints that command's output.
"""
import glob
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

LOG_ROOT = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "claude-rc")
CACHE_FILE = os.path.join(CACHE_DIR, "usage-cache.json")
CACHE_VERSION = 2
LIMITS_FILE = os.path.join(CACHE_DIR, "limits.json")
LIMIT_WINDOWS = ("five_hour", "seven_day")
DAYS = 7
WINDOW = 5 * 3600  # Claude's usage window, in seconds

# USD per million tokens: (input, output, cache write, cache read). Used only
# for an API-equivalent estimate; subscription plans are not billed this way.
PRICES = {
    "claude-fable-5": (8.0, 40.0, 10.0, 0.20),
    "claude-mythos-5": (8.0, 40.0, 10.0, 0.20),
    "claude-opus-5-5": (4.0, 20.0, 5.0, 0.20),
    "claude-opus-5": (5.0, 25.0, 6.25, 0.50),
    "claude-opus-4": (5.0, 25.0, 6.25, 0.50),
    "claude-sonnet-5": (2.0, 10.0, 2.5, 0.10),
    "claude-sonnet-4": (3.0, 15.0, 3.75, 0.30),
    "claude-haiku-5": (0.10, 0.50, 0.125, 0.01),
    "claude-haiku-4": (1.0, 5.0, 1.25, 0.10),
}


def price_for(model):
    best = None
    for prefix, price in PRICES.items():
        if model.startswith(prefix) and (best is None or len(prefix) > len(best[0])):
            best = (prefix, price)
    return best[1] if best else None


def short_model(model):
    name = model.replace("claude-", "")
    parts = name.split("-")
    if len(parts) >= 2 and parts[1].isdigit():
        version = ".".join(p for p in parts[1:3] if p.isdigit() and len(p) < 3)
        return "%s %s" % (parts[0].capitalize(), version)
    return name


def parse_ts(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def read_new_lines(path, entry, cutoff):
    """Adds the usage records appended to `path` since the last run."""
    msgs = entry["msgs"]
    with open(path, "rb") as fh:
        fh.seek(entry["offset"])
        while True:
            start = fh.tell()
            line = fh.readline()
            if not line:
                break
            if not line.endswith(b"\n"):
                fh.seek(start)  # half-written line: read it next time
                break
            entry["offset"] = fh.tell()
            if b'"usage"' not in line or b'"assistant"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            msg = rec.get("message")
            if rec.get("type") != "assistant" or not isinstance(msg, dict):
                continue
            usage = msg.get("usage")
            model = msg.get("model") or ""
            if not isinstance(usage, dict) or not model.startswith("claude"):
                continue
            ts = parse_ts(rec.get("timestamp"))
            if ts is None or ts < cutoff:
                continue
            # A response is logged once per content block with the same ids;
            # keep one record per response, with the largest counts seen.
            key = "%s|%s" % (msg.get("id") or rec.get("uuid"), rec.get("requestId") or "")
            new = [
                ts,
                model,
                int(usage.get("input_tokens") or 0),
                int(usage.get("output_tokens") or 0),
                int(usage.get("cache_creation_input_tokens") or 0),
                int(usage.get("cache_read_input_tokens") or 0),
            ]
            old = msgs.get(key)
            if old:
                new = [min(old[0], ts), model] + [max(a, b) for a, b in zip(old[2:], new[2:])]
            msgs[key] = new


def load_records(now):
    cutoff = now - (DAYS + 1) * 86400
    try:
        with open(CACHE_FILE, encoding="utf-8") as fh:
            cache = json.load(fh)
        if cache.get("version") != CACHE_VERSION:
            cache = {}
    except (OSError, ValueError):
        cache = {}
    files = cache.get("files", {})
    seen = {}
    for path in glob.glob(os.path.join(LOG_ROOT, "*", "**", "*.jsonl"), recursive=True):
        try:
            st = os.stat(path)
        except OSError:
            continue
        if st.st_mtime < cutoff:
            continue
        entry = files.get(path)
        if not entry or st.st_size < entry["offset"]:
            entry = {"offset": 0, "msgs": {}}
        if st.st_size > entry["offset"]:
            try:
                read_new_lines(path, entry, cutoff)
            except OSError:
                continue
        entry["msgs"] = {k: v for k, v in entry["msgs"].items() if v[0] >= cutoff}
        seen[path] = entry
    try:
        write_json(CACHE_FILE, {"version": CACHE_VERSION, "files": seen})
    except OSError:
        pass  # caching is only an optimisation
    # The same response can appear in more than one file (resumed sessions).
    merged = {}
    for entry in seen.values():
        for key, rec in entry["msgs"].items():
            old = merged.get(key)
            merged[key] = rec if not old else [min(old[0], rec[0]), rec[1]] + [max(a, b) for a, b in zip(old[2:], rec[2:])]
    return sorted(merged.values(), key=lambda r: r[0])


def empty_total():
    return {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "tokens": 0, "cost": 0.0, "messages": 0}


def add(total, rec):
    _ts, model, inp, out, cw, cr = rec
    total["input"] += inp
    total["output"] += out
    total["cache_write"] += cw
    total["cache_read"] += cr
    total["tokens"] += inp + out + cw + cr
    total["messages"] += 1
    price = price_for(model)
    if price:
        total["cost"] += (inp * price[0] + out * price[1] + cw * price[2] + cr * price[3]) / 1e6
    else:
        total["unpriced"] = True


def finish(total):
    total["cost"] = round(total["cost"], 4)
    return total


def current_window(records, now):
    """The 5-hour window in progress: it opens with the first message sent
    after the previous window closed, on the hour, and lasts five hours."""
    start = None
    members = []
    for rec in records:
        if start is None or rec[0] >= start + WINDOW:
            start = rec[0] - rec[0] % 3600
            members = []
        members.append(rec)
    if start is None or now >= start + WINDOW:
        return {"active": False}
    total = empty_total()
    for rec in members:
        add(total, rec)
    elapsed = max(60.0, now - start)
    remaining = start + WINDOW - now
    out = finish(total)
    out.update({
        "active": True,
        "start": int(start),
        "end": int(start + WINDOW),
        "remaining_seconds": int(remaining),
        "elapsed_fraction": round(min(1.0, (now - start) / WINDOW), 4),
        "tokens_per_minute": int(total["tokens"] / (elapsed / 60)),
        "cost_per_hour": round(total["cost"] / (elapsed / 3600), 4),
        "projected_cost": round(total["cost"] / elapsed * WINDOW, 4),
    })
    return out


def summarise(records, now):
    local_now = datetime.fromtimestamp(now).astimezone()
    midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    first_day = midnight - timedelta(days=DAYS - 1)
    days = []
    for i in range(DAYS):
        day = first_day + timedelta(days=i)
        row = empty_total()
        row["date"] = day.strftime("%Y-%m-%d")
        row["label"] = day.strftime("%a")
        days.append(row)
    week = empty_total()
    models = {}
    for rec in records:
        index = (datetime.fromtimestamp(rec[0]).astimezone().date() - first_day.date()).days
        if not 0 <= index < DAYS:
            continue
        add(days[index], rec)
        add(week, rec)
        add(models.setdefault(rec[1], empty_total()), rec)
    model_rows = []
    for model, total in models.items():
        row = finish(total)
        row["model"] = model
        row["name"] = short_model(model)
        model_rows.append(row)
    model_rows.sort(key=lambda r: (r["cost"], r["tokens"]), reverse=True)
    return {
        "generated": int(now),
        "window": current_window(records, now),
        "today": dict(finish(days[-1])),
        "week": finish(week),
        "days": [finish(d) for d in days],
        "models": model_rows,
    }


def write_json(path, data):
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    os.replace(tmp, path)


def read_limits(now):
    """Plan limits saved by the status line, or None when there are none."""
    try:
        with open(LIMITS_FILE, encoding="utf-8") as fh:
            saved = json.load(fh)
    except (OSError, ValueError):
        return None
    out = {"updated": int(saved.get("updated") or 0)}
    out["age_seconds"] = max(0, int(now - out["updated"]))
    for name in LIMIT_WINDOWS:
        win = saved.get(name)
        if not isinstance(win, dict) or win.get("used_percentage") is None:
            continue
        resets_at = int(win.get("resets_at") or 0)
        if resets_at and resets_at <= now:
            # The window has rolled over since the last report.
            out[name] = {"used": 0.0, "resets_at": 0, "remaining_seconds": 0, "rolled_over": True}
        else:
            out[name] = {
                "used": round(float(win["used_percentage"]), 1),
                "resets_at": resets_at,
                "remaining_seconds": max(0, int(resets_at - now)) if resets_at else 0,
                "rolled_over": False,
            }
    return out if any(name in out for name in LIMIT_WINDOWS) else None


def statusline(argv):
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except ValueError:
        data = {}
    limits = data.get("rate_limits") if isinstance(data, dict) else None
    saved = {}
    if isinstance(limits, dict):
        for name in LIMIT_WINDOWS:
            win = limits.get(name)
            if isinstance(win, dict) and isinstance(win.get("used_percentage"), (int, float)):
                saved[name] = {"used_percentage": win["used_percentage"], "resets_at": win.get("resets_at") or 0}
    if saved:
        # Claude Code may report only one of the windows; keep the other.
        try:
            with open(LIMITS_FILE, encoding="utf-8") as fh:
                merged = json.load(fh)
            if not isinstance(merged, dict):
                merged = {}
        except (OSError, ValueError):
            merged = {}
        merged.update(saved)
        merged["updated"] = int(time.time())
        try:
            write_json(LIMITS_FILE, merged)
        except OSError:
            pass
    if argv:
        # Wrap the user's own status line command: same input, its output.
        try:
            done = subprocess.run(argv, input=raw, text=True, capture_output=True, timeout=10)
            sys.stdout.write(done.stdout)
        except (OSError, subprocess.SubprocessError):
            pass
        return 0
    parts = []
    model = data.get("model") if isinstance(data, dict) else None
    if isinstance(model, dict) and model.get("display_name"):
        parts.append(str(model["display_name"]))
    labels = {"five_hour": "5h", "seven_day": "7d"}
    for name in LIMIT_WINDOWS:
        if name in saved:
            parts.append("%s %d%%" % (labels[name], round(saved[name]["used_percentage"])))
    print(" · ".join(parts))
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--statusline":
        rest = sys.argv[2:]
        return statusline(rest[1:] if rest[:1] == ["--"] else rest)
    now = time.time()
    if not os.path.isdir(LOG_ROOT):
        print(json.dumps({"error": "No Claude Code session logs found in %s" % LOG_ROOT, "limits": read_limits(now)}))
        return 0
    summary = summarise(load_records(now), now)
    summary["limits"] = read_limits(now)
    print(json.dumps(summary, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_CLAUDE_RC
chmod +x "$BIN_DIR/claude-rc-usage.new"
mv -f "$BIN_DIR/claude-rc-usage.new" "$BIN_DIR/claude-rc-usage"

echo "==> Installing claude-remote-control.service..."
cat > "$UNIT_DIR/claude-remote-control.service" << EOF_CLAUDE_RC
[Unit]
Description=Claude Code Remote Control server ($RC_DIR)
Documentation=https://code.claude.com/docs/en/remote-control

[Service]
WorkingDirectory=$RC_DIR
Environment=CLAUDE_BIN=$CLAUDE_BIN
# claude-rc run drops the repeated status redraws so the journal stays small
ExecStart=$BIN_DIR/claude-rc run
# Retry until the network is up at boot, after crashes, and when the claude-rc
# watchdog stops it after 60 s without a connection
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF_CLAUDE_RC
systemctl --user daemon-reload
systemctl --user enable --now claude-remote-control.service

echo "==> Letting it start at boot, before you log in..."
loginctl enable-linger "$(id -un)" || echo "   (couldn't enable lingering; it will start when you log in instead)"

if command -v kpackagetool6 >/dev/null; then
    echo "==> Installing the Plasma 6 widget..."
    mkdir -p "$SRC_DIR/contents/ui" "$SRC_DIR/contents/config"
    cat > "$SRC_DIR/metadata.json" << 'EOF_CLAUDE_RC'
{
    "KPlugin": {
        "Id": "org.taghouti.clauderc",
        "Name": "Claude Remote Control",
        "Description": "Shows and controls the Claude Code Remote Control service, and tracks your Claude usage with alerts.",
        "Icon": "network-connect",
        "Authors": [{ "Name": "Tarek" }],
        "Category": "System Information",
        "License": "GPL",
        "Version": "2.0"
    },
    "KPackageStructure": "Plasma/Applet",
    "X-Plasma-API-Minimum-Version": "6.0"
}
EOF_CLAUDE_RC
    cat > "$SRC_DIR/contents/config/main.xml" << 'EOF_CLAUDE_RC'
<?xml version="1.0" encoding="UTF-8"?>
<kcfg xmlns="http://www.kde.org/standards/kcfg/1.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://www.kde.org/standards/kcfg/1.0 http://www.kde.org/standards/kcfg/1.0/kcfg.xsd">
  <kcfgfile name=""/>
  <group name="General">
    <entry name="showUsage" type="Bool"><default>true</default></entry>
    <entry name="panelText" type="String"><default>none</default></entry>
    <entry name="usageInterval" type="Int"><default>60</default></entry>
    <entry name="alertLimits" type="Bool"><default>true</default></entry>
    <entry name="warnPercent" type="Int"><default>80</default></entry>
    <entry name="criticalPercent" type="Int"><default>95</default></entry>
    <entry name="alertReset" type="Bool"><default>true</default></entry>
    <entry name="dailyBudget" type="Int"><default>0</default></entry>
    <entry name="windowBudget" type="Int"><default>0</default></entry>
    <entry name="disconnectMinutes" type="Int"><default>5</default></entry>
    <entry name="firedAlerts" type="String"><default>{}</default></entry>
  </group>
</kcfg>
EOF_CLAUDE_RC
    cat > "$SRC_DIR/contents/config/config.qml" << 'EOF_CLAUDE_RC'
import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: "Usage and alerts"
        icon: "office-chart-bar"
        source: "configGeneral.qml"
    }
}
EOF_CLAUDE_RC
    cat > "$SRC_DIR/contents/ui/configGeneral.qml" << 'EOF_CLAUDE_RC'
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property alias cfg_showUsage: showUsage.checked
    property string cfg_panelText
    property alias cfg_usageInterval: usageInterval.value
    property alias cfg_alertLimits: alertLimits.checked
    property alias cfg_warnPercent: warnPercent.value
    property alias cfg_criticalPercent: criticalPercent.value
    property alias cfg_alertReset: alertReset.checked
    property alias cfg_dailyBudget: dailyBudget.value
    property alias cfg_windowBudget: windowBudget.value
    property alias cfg_disconnectMinutes: disconnectMinutes.value
    property string cfg_firedAlerts

    readonly property var panelChoices: [
        { id: "none", label: "Icon only" },
        { id: "limit", label: "5-hour limit used (%)" },
        { id: "cost", label: "Cost of the current 5-hour window" }
    ]

    Kirigami.FormLayout {
        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Usage"
        }
        QQC2.CheckBox {
            id: showUsage
            Kirigami.FormData.label: "Popup:"
            text: "Show Claude usage"
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: "Next to the panel icon:"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 16
            model: page.panelChoices.map(c => c.label)
            currentIndex: Math.max(0, page.panelChoices.findIndex(c => c.id === page.cfg_panelText))
            onActivated: index => page.cfg_panelText = page.panelChoices[index].id
        }
        QQC2.SpinBox {
            id: usageInterval
            Kirigami.FormData.label: "Refresh usage every:"
            from: 15
            to: 900
            stepSize: 15
            textFromValue: value => value + " s"
            valueFromText: text => parseInt(text) || 60
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Plan limit alerts"
        }
        QQC2.CheckBox {
            id: alertLimits
            Kirigami.FormData.label: "Notify:"
            text: "When the 5-hour or weekly limit is nearly used up"
        }
        QQC2.SpinBox {
            id: warnPercent
            Kirigami.FormData.label: "Warning at:"
            enabled: alertLimits.checked
            from: 10
            to: Math.max(10, criticalPercent.value - 1)
            textFromValue: value => value + " %"
            valueFromText: text => parseInt(text) || 80
        }
        QQC2.SpinBox {
            id: criticalPercent
            Kirigami.FormData.label: "Critical at:"
            enabled: alertLimits.checked
            from: 11
            to: 100
            textFromValue: value => value + " %"
            valueFromText: text => parseInt(text) || 95
        }
        QQC2.CheckBox {
            id: alertReset
            Kirigami.FormData.label: " "
            text: "When a nearly used-up limit resets"
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            opacity: 0.75
            text: "Plan limits come from Claude Code's status line. Turn that on once with: claude-rc statusline-setup"
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Budget alerts"
        }
        QQC2.SpinBox {
            id: dailyBudget
            Kirigami.FormData.label: "Daily budget:"
            from: 0
            to: 10000
            stepSize: 5
            textFromValue: value => value === 0 ? "Off" : "$" + value
            valueFromText: text => parseInt(text.replace("$", "")) || 0
        }
        QQC2.SpinBox {
            id: windowBudget
            Kirigami.FormData.label: "Per 5-hour window:"
            from: 0
            to: 10000
            stepSize: 5
            textFromValue: value => value === 0 ? "Off" : "$" + value
            valueFromText: text => parseInt(text.replace("$", "")) || 0
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            opacity: 0.75
            text: "Budgets use the API-equivalent cost estimated from local session logs. A subscription is not billed this way; treat it as a measure of how much you are using."
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Remote Control alerts"
        }
        QQC2.SpinBox {
            id: disconnectMinutes
            Kirigami.FormData.label: "Notify when disconnected for:"
            from: 0
            to: 120
            textFromValue: value => value === 0 ? "Off" : value + " min"
            valueFromText: text => parseInt(text) || 0
        }
    }
}
EOF_CLAUDE_RC
    cat > "$SRC_DIR/contents/ui/main.qml" << 'EOF_CLAUDE_RC'
// Claude Remote Control: shows the state of claude-remote-control.service (via the claude-rc helper),
// lets you start, stop and restart it or open its environment on claude.ai, and tracks Claude usage
// (plan limits, tokens, estimated cost) with desktop alerts.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import org.kde.notification

PlasmoidItem {
    id: root

    readonly property string helper: "$HOME/.local/bin/claude-rc"
    readonly property string statusCmd: helper + " json"
    readonly property string usageCmd: helper + " usage"

    // ---- Remote Control state
    property string svcState: "unknown"
    property bool connected: false
    property string sessions: ""
    property string envUrl: ""
    property string workDir: ""
    property bool atBoot: false
    property bool busy: false
    property double downSince: 0

    readonly property bool running: svcState === "active"
    readonly property string statusText: !running ? (svcState === "activating" ? "Starting…" : "Stopped")
                                         : connected ? "Connected" : "Connecting…"

    // ---- usage state (see `claude-rc usage`)
    property var usage: null
    property string usageError: ""
    property string copiedNote: ""

    readonly property var cfg: Plasmoid.configuration
    readonly property var limits: usage && usage.limits ? usage.limits : null
    readonly property var win: usage && usage.window && usage.window.active ? usage.window : null
    readonly property bool limitsStale: !!limits && limits.age_seconds > 6 * 3600

    // 0 = fine, 1 = warning, 2 = critical; drives the dot on the panel icon.
    readonly property int alertLevel: {
        let level = 0;
        if (limits && !limitsStale) {
            for (const name of ["five_hour", "seven_day"]) {
                const w = limits[name];
                if (!w) continue;
                if (w.used >= cfg.criticalPercent) level = Math.max(level, 2);
                else if (w.used >= cfg.warnPercent) level = Math.max(level, 1);
            }
        }
        if (usage && usage.today && cfg.dailyBudget > 0 && usage.today.cost >= cfg.dailyBudget) level = Math.max(level, 1);
        if (win && cfg.windowBudget > 0 && win.cost >= cfg.windowBudget) level = Math.max(level, 1);
        return level;
    }
    readonly property color alertColor: alertLevel === 2 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor

    readonly property string panelLabel: {
        if (cfg.panelText === "limit") {
            return limits && limits.five_hour && !limitsStale ? Math.round(limits.five_hour.used) + "%" : "";
        }
        if (cfg.panelText === "cost") return win ? fmtCost(win.cost) : "";
        return "";
    }

    Plasmoid.icon: connected ? "network-connect" : "network-disconnect"
    toolTipMainText: "Claude Remote Control"
    toolTipSubText: {
        const parts = [statusText + (running && sessions ? " · sessions " + sessions : "")];
        if (limits && limits.five_hour && !limitsStale) parts.push("5-hour limit: " + Math.round(limits.five_hour.used) + "% used");
        if (limits && limits.seven_day && !limitsStale) parts.push("Weekly limit: " + Math.round(limits.seven_day.used) + "% used");
        if (win) parts.push("This window: " + fmtTokens(win.tokens) + " tokens, about " + fmtCost(win.cost));
        return parts.join("\n");
    }

    // ---- formatting

    function fmtTokens(n) {
        if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
        if (n >= 1e3) return Math.round(n / 1e3) + "K";
        return String(n || 0);
    }

    function fmtCost(c) {
        const v = c || 0;
        return "$" + (v >= 100 ? v.toFixed(0) : v.toFixed(2));
    }

    function fmtDuration(seconds) {
        const s = Math.max(0, seconds || 0);
        const d = Math.floor(s / 86400);
        const h = Math.floor((s % 86400) / 3600);
        const m = Math.floor((s % 3600) / 60);
        if (d > 0) return d + " d " + h + " h";
        if (h > 0) return h + " h " + m + " min";
        return Math.max(1, m) + " min";
    }

    function resetText(w) {
        if (!w) return "";
        if (w.rolled_over) return "has reset";
        return w.resets_at ? "resets in " + fmtDuration(w.remaining_seconds) : "";
    }

    function levelColor(used) {
        return used >= cfg.criticalPercent ? Kirigami.Theme.negativeTextColor
             : used >= cfg.warnPercent ? Kirigami.Theme.neutralTextColor
             : Kirigami.Theme.positiveTextColor;
    }

    // ---- alerts

    Component {
        id: notificationComponent
        Notification {
            componentName: "plasma_workspace"
            eventId: "notification"
            autoDelete: true
        }
    }

    // Sends a notification once per key. Keys include the period they belong to
    // (a window's reset time, a date), so each period alerts once, also across
    // Plasma restarts.
    function alertOnce(key, title, text, critical) {
        let fired = {};
        try { fired = JSON.parse(cfg.firedAlerts || "{}"); } catch (e) { fired = {}; }
        if (fired[key]) return;
        const now = Date.now();
        for (const k in fired) {
            if (now - fired[k] > 9 * 86400 * 1000) delete fired[k];
        }
        fired[key] = now;
        cfg.firedAlerts = JSON.stringify(fired);
        const n = notificationComponent.createObject(root, {
            title: title,
            text: text,
            iconName: critical ? "dialog-warning" : "dialog-information",
            urgency: critical ? Notification.HighUrgency : Notification.NormalUrgency
        });
        n.sendEvent();
    }

    function checkLimitAlerts(previous) {
        if (!limits || limitsStale) return;
        const names = { five_hour: "5-hour", seven_day: "weekly" };
        for (const name in names) {
            const w = limits[name];
            if (!w) continue;
            const label = names[name];
            if (cfg.alertLimits && !w.rolled_over) {
                const tail = " used. It " + resetText(w) + ".";
                if (w.used >= cfg.criticalPercent) {
                    alertOnce(name + "-critical-" + w.resets_at, "Claude " + label + " limit almost reached",
                              Math.round(w.used) + "% of your " + label + " limit" + tail, true);
                } else if (w.used >= cfg.warnPercent) {
                    alertOnce(name + "-warning-" + w.resets_at, "Claude " + label + " limit at " + Math.round(w.used) + "%",
                              Math.round(w.used) + "% of your " + label + " limit" + tail, false);
                }
            }
            // A limit that was nearly used up has started a new period.
            const before = previous && previous[name];
            if (cfg.alertReset && before && before.used >= cfg.warnPercent && before.resets_at
                    && (w.rolled_over || (w.resets_at && w.resets_at !== before.resets_at))) {
                alertOnce(name + "-reset-" + before.resets_at, "Claude " + label + " limit has reset",
                          "Your " + label + " limit started a new period.", false);
            }
        }
    }

    function checkBudgetAlerts() {
        if (!usage) return;
        if (cfg.dailyBudget > 0 && usage.today && usage.today.cost >= cfg.dailyBudget) {
            alertOnce("day-" + usage.today.date, "Claude daily budget reached",
                      "Today's usage is about " + fmtCost(usage.today.cost) + " (budget " + fmtCost(cfg.dailyBudget) + ").", false);
        }
        if (cfg.windowBudget > 0 && win && win.cost >= cfg.windowBudget) {
            alertOnce("window-" + win.end, "Claude 5-hour budget reached",
                      "This 5-hour window is at about " + fmtCost(win.cost) + " (budget " + fmtCost(cfg.windowBudget) + ").", false);
        }
    }

    function checkConnectionAlert() {
        // Only an outage counts: the service is meant to run but is not connected.
        const down = (running && !connected) || svcState === "failed" || svcState === "activating";
        if (!down) {
            downSince = 0;
            return;
        }
        if (downSince === 0) downSince = Date.now();
        const minutes = cfg.disconnectMinutes;
        if (minutes > 0 && Date.now() - downSince >= minutes * 60000) {
            alertOnce("down-" + downSince, "Claude Remote Control is not connected",
                      "It has been disconnected for " + minutes + " min. Sessions cannot be started from claude.ai until it reconnects.", true);
        }
    }

    // ---- data

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
                root.checkConnectionAlert()
            } else if (sourceName === root.usageCmd) {
                try {
                    const u = JSON.parse(data["stdout"])
                    const previous = root.limits
                    root.usageError = u.error || ""
                    root.usage = u
                    root.checkLimitAlerts(previous)
                    root.checkBudgetAlerts()
                } catch (e) {
                    root.usageError = "Usage is unavailable. Re-run the installer to update the claude-rc helper."
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

    function refreshUsage() {
        executable.connectSource(usageCmd)
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

    Timer {
        interval: Math.max(15, root.cfg.usageInterval) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshUsage()
    }

    onExpandedChanged: if (root.expanded) refreshUsage()

    // ---- panel

    compactRepresentation: MouseArea {
        id: compact
        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        readonly property bool showLabel: !vertical && root.panelLabel !== ""
        readonly property int wanted: showLabel ? height + Kirigami.Units.smallSpacing + panelText.implicitWidth : height

        Layout.minimumWidth: vertical ? -1 : wanted
        Layout.preferredWidth: vertical ? -1 : wanted
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded
        Accessible.role: Accessible.Button
        Accessible.name: "Claude Remote Control"

        Kirigami.Icon {
            id: panelIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(parent.width, parent.height)
            height: width
            source: Plasmoid.icon
            active: compact.containsMouse
            opacity: root.connected ? 1 : 0.6

            Rectangle {
                visible: root.alertLevel > 0
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                width: Math.max(6, Math.round(parent.width / 3))
                height: width
                radius: width / 2
                color: root.alertColor
                border.width: 1
                border.color: Kirigami.Theme.backgroundColor
            }
        }
        PlasmaComponents3.Label {
            id: panelText
            visible: compact.showLabel
            anchors.left: panelIcon.right
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.verticalCenter: parent.verticalCenter
            text: root.panelLabel
            color: root.alertLevel > 0 ? root.alertColor : Kirigami.Theme.textColor
        }
    }

    // ---- popup

    // One labelled limit bar: "5-hour limit   42%   resets in 2 h 30 min"
    component LimitBar: ColumnLayout {
        id: bar
        property string label
        property var info: null
        visible: !!info
        spacing: 2
        Layout.fillWidth: true

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label { text: bar.label }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.Label {
                opacity: 0.8
                font: Kirigami.Theme.smallFont
                text: bar.info ? root.resetText(bar.info) : ""
            }
            PlasmaComponents3.Label {
                font.bold: true
                color: bar.info ? root.levelColor(bar.info.used) : Kirigami.Theme.textColor
                text: bar.info ? Math.round(bar.info.used) + "%" : ""
            }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Math.round(Kirigami.Units.smallSpacing * 1.5)
            radius: height / 2
            color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
            Rectangle {
                width: parent.width * Math.min(1, (bar.info ? bar.info.used : 0) / 100)
                height: parent.height
                radius: height / 2
                color: bar.info ? root.levelColor(bar.info.used) : "transparent"
            }
        }
    }

    component Stat: ColumnLayout {
        property string title
        property string value
        property string detail
        spacing: 0
        Layout.fillWidth: true
        PlasmaComponents3.Label { text: parent.title; opacity: 0.7; font: Kirigami.Theme.smallFont }
        PlasmaComponents3.Label { text: parent.value; font.bold: true }
        PlasmaComponents3.Label { text: parent.detail; opacity: 0.7; font: Kirigami.Theme.smallFont; visible: text !== "" }
    }

    fullRepresentation: ColumnLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 21
        Layout.minimumWidth: Kirigami.Units.gridUnit * 17
        spacing: Kirigami.Units.smallSpacing

        // Hidden helper for copying text to the clipboard.
        TextEdit {
            id: clipboardHelper
            visible: false
            function copyText(value) {
                text = value
                selectAll()
                copy()
                text = ""
            }
        }
        Timer { id: copiedTimer; interval: 1500; onTriggered: root.copiedNote = "" }

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
            Layout.fillWidth: true
            elide: Text.ElideMiddle
            text: "Folder: " + (root.workDir || "–") + (root.atBoot ? " · starts at boot" : "")
            opacity: 0.8
        }

        RowLayout {
            Layout.topMargin: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
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
            Item { Layout.fillWidth: true }
            PlasmaComponents3.ToolButton {
                icon.name: "edit-copy"
                enabled: root.envUrl !== ""
                onClicked: {
                    clipboardHelper.copyText(root.envUrl)
                    root.copiedNote = "Link copied"
                    copiedTimer.restart()
                }
                PlasmaComponents3.ToolTip.text: root.copiedNote || "Copy the claude.ai link for this computer"
                PlasmaComponents3.ToolTip.visible: hovered || root.copiedNote !== ""
                Accessible.name: "Copy link"
            }
            PlasmaComponents3.ToolButton {
                icon.name: "configure"
                onClicked: Plasmoid.internalAction("configure").trigger()
                PlasmaComponents3.ToolTip.text: "Usage and alert settings"
                PlasmaComponents3.ToolTip.visible: hovered
                Accessible.name: "Settings"
            }
        }

        PlasmaComponents3.Button {
            Layout.fillWidth: true
            icon.name: "internet-web-browser"
            text: "Open in browser"
            enabled: root.connected && root.envUrl !== ""
            onClicked: Qt.openUrlExternally(root.envUrl)
        }

        // ---------------- usage
        ColumnLayout {
            visible: root.cfg.showUsage
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Separator { Layout.fillWidth: true }

            RowLayout {
                Layout.fillWidth: true
                PlasmaExtras.Heading { level: 4; text: "Claude usage"; Layout.fillWidth: true }
                PlasmaComponents3.ToolButton {
                    icon.name: "view-refresh"
                    onClicked: root.refreshUsage()
                    PlasmaComponents3.ToolTip.text: "Refresh usage"
                    PlasmaComponents3.ToolTip.visible: hovered
                    Accessible.name: "Refresh usage"
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: root.usageError !== ""
                wrapMode: Text.Wrap
                color: Kirigami.Theme.neutralTextColor
                text: root.usageError
            }

            // Plan limits, as reported by Claude Code itself
            LimitBar { label: "5-hour limit"; info: root.limits ? root.limits.five_hour : null }
            LimitBar { label: "Weekly limit"; info: root.limits ? root.limits.seven_day : null }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: root.usage !== null && (root.limits === null || root.limitsStale)
                wrapMode: Text.Wrap
                font: Kirigami.Theme.smallFont
                opacity: 0.75
                text: root.limits === null
                    ? "Plan limits are not available yet. Run \"claude-rc statusline-setup\" once, then use Claude Code."
                    : "Plan limits were last reported " + root.fmtDuration(root.limits.age_seconds) + " ago; they update while Claude Code is in use."
            }

            // Tokens and estimated cost, from local session logs
            RowLayout {
                visible: root.usage !== null && root.usageError === ""
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing

                Stat {
                    title: "This 5-hour window"
                    value: root.win ? root.fmtCost(root.win.cost) : "–"
                    detail: root.win ? root.fmtTokens(root.win.tokens) + " tokens · " + root.fmtDuration(root.win.remaining_seconds) + " left" : "no activity"
                }
                Stat {
                    title: "Today"
                    value: root.usage && root.usage.today ? root.fmtCost(root.usage.today.cost) : "–"
                    detail: root.usage && root.usage.today ? root.fmtTokens(root.usage.today.tokens) + " tokens" : ""
                }
                Stat {
                    title: "Last 7 days"
                    value: root.usage && root.usage.week ? root.fmtCost(root.usage.week.cost) : "–"
                    detail: root.usage && root.usage.week ? root.fmtTokens(root.usage.week.tokens) + " tokens" : ""
                }
            }
            PlasmaComponents3.Label {
                visible: root.win !== null
                Layout.fillWidth: true
                font: Kirigami.Theme.smallFont
                opacity: 0.75
                elide: Text.ElideRight
                text: root.win ? "Current pace: about " + root.fmtCost(root.win.cost_per_hour) + " an hour, "
                                 + root.fmtCost(root.win.projected_cost) + " by the end of this window" : ""
            }

            // Last 7 days, one bar per day
            RowLayout {
                id: chart
                visible: root.usage !== null && !!root.usage.days
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 4.5
                Layout.minimumHeight: Kirigami.Units.gridUnit * 4.5
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                readonly property var days: root.usage && root.usage.days ? root.usage.days : []
                readonly property real peak: Math.max(0.0001, ...days.map(d => d.cost))

                Repeater {
                    model: chart.days
                    ColumnLayout {
                        id: dayColumn
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 2

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Rectangle {
                                anchors.bottom: parent.bottom
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: Math.min(parent.width, Kirigami.Units.gridUnit * 1.6)
                                height: Math.max(2, parent.height * dayColumn.modelData.cost / chart.peak)
                                radius: 2
                                color: dayColumn.index === chart.days.length - 1 ? Kirigami.Theme.highlightColor
                                                                                  : Qt.alpha(Kirigami.Theme.highlightColor, 0.45)
                            }
                            HoverHandler { id: dayHover }
                            PlasmaComponents3.ToolTip.visible: dayHover.hovered
                            PlasmaComponents3.ToolTip.text: dayColumn.modelData.date + ": " + root.fmtCost(dayColumn.modelData.cost)
                                                            + ", " + root.fmtTokens(dayColumn.modelData.tokens) + " tokens"
                        }
                        PlasmaComponents3.Label {
                            Layout.alignment: Qt.AlignHCenter
                            font: Kirigami.Theme.smallFont
                            opacity: dayColumn.index === chart.days.length - 1 ? 1 : 0.7
                            text: dayColumn.modelData.label
                        }
                    }
                }
            }

            // Share of each model over the last 7 days
            Repeater {
                model: root.usage && root.usage.models ? root.usage.models.slice(0, 4) : []
                RowLayout {
                    id: modelRow
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    readonly property real share: root.usage.week.cost > 0 ? modelData.cost / root.usage.week.cost : 0

                    PlasmaComponents3.Label {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                        elide: Text.ElideRight
                        font: Kirigami.Theme.smallFont
                        text: modelRow.modelData.name
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.smallSpacing
                        radius: height / 2
                        color: Qt.alpha(Kirigami.Theme.textColor, 0.12)
                        Rectangle {
                            width: parent.width * Math.min(1, modelRow.share)
                            height: parent.height
                            radius: height / 2
                            color: Qt.alpha(Kirigami.Theme.highlightColor, 0.8)
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                        horizontalAlignment: Text.AlignRight
                        font: Kirigami.Theme.smallFont
                        opacity: 0.8
                        text: root.fmtCost(modelRow.modelData.cost) + " · " + Math.round(modelRow.share * 100) + "%"
                    }
                }
            }

            PlasmaComponents3.Label {
                visible: root.usage !== null && root.usageError === ""
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font: Kirigami.Theme.smallFont
                opacity: 0.6
                text: "Costs are estimates at API list prices from this computer's session logs. A subscription is not billed this way."
            }
        }
    }
}
EOF_CLAUDE_RC
    if kpackagetool6 -t Plasma/Applet -s "$WIDGET_ID" >/dev/null 2>&1; then
        kpackagetool6 -t Plasma/Applet -u "$SRC_DIR"
        echo "   Widget upgraded. Plasma loads the new version after: systemctl --user restart plasma-plasmashell"
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
echo "To see your plan limits (5-hour and weekly) in the widget, run once: claude-rc statusline-setup"
