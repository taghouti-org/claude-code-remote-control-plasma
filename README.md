# Claude Remote Control for KDE Plasma 6

Start [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) automatically at boot, so you can open sessions on your computer from [claude.ai/code](https://claude.ai/code) or the Claude mobile app at any time, and see its status in a Plasma panel widget.

## What you get

- **`claude-remote-control.service`**: a systemd user service that runs `claude remote-control` in a folder of your choice, starts at boot (even before you log in), and recovers by itself after network drops or crashes. A **watchdog restarts it if it stays disconnected for 60 seconds**, since Remote Control can otherwise sit in "Reconnecting" indefinitely.
- **`claude-rc`**: a terminal command to check, start, stop or restart it.
- **Claude Remote Control widget** (Plasma 6): a panel icon that shows whether it's connected. Click it for a popup with:
  - status (connected / connecting / stopped)
  - number of sessions in use
  - the folder sessions start in
  - **Start/Stop**, **Restart** and **Open in browser** buttons

## Quick Install

```bash
curl -L https://gist.github.com/taghouttarek/2e3825d96ce8a8ef0c97bfe5f96752e2/raw/install-claude-rc.sh | bash
```

Sessions start in `~/claude-remote` by default. To use another folder:

```bash
curl -L https://gist.github.com/taghouttarek/2e3825d96ce8a8ef0c97bfe5f96752e2/raw/install-claude-rc.sh | CLAUDE_RC_DIR=~/projects/myapp bash
```

Then add the widget: right-click the panel → **Add Widgets…** → search **"Claude Remote Control"**.

### One-time step: trust the folder

Remote Control only runs in a folder Claude trusts. If the installer says so, run this once and choose **"Yes, I trust this folder"**:

```bash
cd ~/claude-remote && claude
```

The service retries every 30 seconds and connects as soon as the folder is trusted.

> Your home folder itself can't be used: Claude never saves trust for the home directory, for security. Use a subfolder.

## Usage

```bash
claude-rc            # status, plus the claude.ai link for this computer
claude-rc stop       # stop accepting remote sessions
claude-rc start
claude-rc restart
claude-rc logs       # follow the service log
claude-rc json       # machine-readable status (used by the widget)
claude-rc run        # what the service runs (Remote Control with a quiet log)
```

Then open [claude.ai/code](https://claude.ai/code) or the Claude app, pick this computer's environment, and start a session.

## Requirements

- [Claude Code](https://code.claude.com), logged in with a Claude account that has a subscription
- systemd, Python 3 (for the trust check)
- KDE Plasma 6 for the widget (tested on Plasma 6.6, Kubuntu 26.04); the service and `claude-rc` work on any desktop

## What gets installed

| File | Purpose |
|------|---------|
| `~/.config/systemd/user/claude-remote-control.service` | Runs Remote Control; enabled at boot |
| `~/.local/bin/claude-rc` | Helper command |
| `~/.local/src/plasma-claude-rc/` | Widget source |
| `~/.local/share/plasma/plasmoids/org.taghouti.clauderc/` | Installed widget |

The installer also runs `loginctl enable-linger` so your user services start at boot without logging in.

## Uninstall

```bash
systemctl --user disable --now claude-remote-control.service
rm ~/.config/systemd/user/claude-remote-control.service ~/.local/bin/claude-rc
systemctl --user daemon-reload
kpackagetool6 -t Plasma/Applet -r org.taghouti.clauderc
rm -rf ~/.local/src/plasma-claude-rc
```

Remove the widget from the panel first if it's there. Lingering stays on; turn it off with `loginctl disable-linger` if nothing else needs it.

## How it works

1. The service runs `claude-rc run`, which starts `claude remote-control` as a persistent server in the chosen folder. It registers this computer as an environment on claude.ai and accepts up to 32 concurrent sessions there.
2. Remote Control redraws its status display several times a second; under systemd that becomes ~300 identical journal lines a minute. `claude-rc run` passes on only lines that changed (connection state, session count, new session links), so the log stays small.
3. It also records the connection state (`up`/`down`) in `$XDG_RUNTIME_DIR/claude-rc.state` whenever it changes ("Reconnected after …" counts as up). If the state stays `down` for 60 seconds, the watchdog stops Remote Control and systemd starts it again 5 seconds later. Change the limit with `Environment=CLAUDE_RC_WATCHDOG_SECS=120` in the service.
4. `claude-rc json` reads the service state from systemd, the connection state from the state file, and the session count (`Capacity: n/32`) and environment link from the current run's journal.
5. The widget runs `claude-rc json` every 5 seconds (every 2 seconds while its popup is open), and calls `claude-rc start|stop|restart` for the buttons.

---

First published as a [gist](https://gist.github.com/taghouttarek/2e3825d96ce8a8ef0c97bfe5f96752e2).
