# Ngrok Monitor

A native macOS menu bar app for managing [ngrok](https://ngrok.com) tunnels with automatic inactivity shutdown.

> Stop forgetting that ngrok is running. NgrokMonitor sits in your menu bar, shows your live tunnel URLs, and auto-stops the agent when no traffic comes in for a while.

## Features

- **Menu bar presence** — lightweight icon, no Dock entry
- **One-click start/stop** — runs `ngrok start --all`
- **Global start/stop shortcut** — record your own hotkey in Preferences (⌘,)
- **Live tunnel URLs** — click any URL to open it in your browser
- **Recent traffic** — last few requests with method + path
- **Auto-stop on inactivity** — configurable 1 / 5 / 10 / 30 minute timeout
- **System notifications** when ngrok auto-stops
- **Launch at login** via `SMAppService`
- **`ngrok update`** straight from the menu
- **Local control API** — start/stop ngrok and read status from scripts or an agent ([details](#control-api))

## Install

### From a release (recommended)

1. Download `NgrokMonitor-x.y.z.zip` from the [latest GitHub Release](../../releases/latest).
2. Unzip and drag `NgrokMonitor.app` to `/Applications`.
3. Launch it. The globe icon will appear in your menu bar.

Signed and notarized builds need no Gatekeeper workaround.

### From source

```bash
git clone https://github.com/dnc4104/ngrok_monitoring.git
cd ngrok_monitoring
./build.sh
open ~/Applications/NgrokMonitor.app
```

`./build.sh` produces an **unsigned** development bundle. macOS may refuse to open it on first launch — clear the quarantine attribute once:

```bash
xattr -dr com.apple.quarantine ~/Applications/NgrokMonitor.app
```

## Requirements

- macOS 13.0 (Ventura) or later
- [ngrok](https://ngrok.com/download) installed and authenticated

```bash
brew install ngrok
ngrok config add-authtoken <your-token>
```

Configure your tunnels in `~/Library/Application Support/ngrok/ngrok.yml` (or `~/.config/ngrok/ngrok.yml`, or legacy `~/.ngrok2/ngrok.yml`):

```yaml
version: "3"
tunnels:
  web:
    addr: 3000
    proto: http
  api:
    addr: 8080
    proto: http
```

The "Edit ngrok config…" menu item opens the first config file it finds.

## Control API

NgrokMonitor exposes a tiny HTTP control server so other tools on your Mac — a
script, a Makefile, or an automation agent — can bring ngrok up on demand and
tear it down, driving the app exactly as if you'd used the menu. Starting ngrok
this way keeps the menu-bar icon, the inactivity auto-stop timer, and the
traffic view all in sync.

It listens on **loopback only** at `127.0.0.1:4042` (nothing off your machine
can reach it):

| Method & path | Does | Auth |
|---|---|---|
| `GET /status` | Reports whether ngrok is running and lists tunnel URLs | none |
| `POST /start` | Starts ngrok (`ngrok start --all`); replies once tunnels are up | header |
| `POST /stop`  | Stops ngrok | header |

`/start` and `/stop` require the header `X-NgrokMonitor-Control` (any value).
This stops a malicious web page you happen to have open from triggering a
start/stop via a cross-origin request — browsers can't set a custom header
cross-origin without a CORS preflight the server never answers. Any local
process that can set the header can drive it, which is the same trust level as
that process simply running `ngrok` itself.

```bash
# Is ngrok up? What are the URLs?
curl -s 127.0.0.1:4042/status

# Start it (and get the tunnel URLs back once they're live)
curl -s -X POST -H 'X-NgrokMonitor-Control: 1' 127.0.0.1:4042/start

# Stop it
curl -s -X POST -H 'X-NgrokMonitor-Control: 1' 127.0.0.1:4042/stop
```

All responses are JSON, e.g. `{"running":true,"tunnels":["https://…"]}`.

`/start` is idempotent: if ngrok is already running (even one you started
outside the app), it adopts that instance and returns its tunnels rather than
failing. If startup fails (ngrok not installed, bad config, session limit), the
call returns `500` with the error text in the body.

## How it works

The app monitors traffic by polling the local ngrok API at `http://127.0.0.1:4040/api/requests/http` every 10 seconds. If no new requests arrive within the configured timeout, it gracefully stops the ngrok process and shows a notification.

## Privacy & transparency

This app runs entirely locally and only talks to:
- the `ngrok` process it spawns
- the local ngrok agent API at `127.0.0.1:4040`
- its own control server, which **listens on loopback only** at `127.0.0.1:4042` (see [Control API](#control-api))

**No data leaves your machine via this app.** No analytics, no telemetry, no remote calls — full stop. The control server is bound to `127.0.0.1`, so it's reachable only from this Mac, never over the network.

The source is MIT-licensed and open for inspection. If you want to confirm the released binary matches the published source, build it yourself with `./build.sh` and compare against the notarized `.app` from the [latest release](../../releases/latest). The hot paths to audit if you're skeptical:

- [NgrokProcessManager.swift](Sources/NgrokMonitor/NgrokProcessManager.swift) — every subprocess we spawn
- [TrafficMonitor.swift](Sources/NgrokMonitor/TrafficMonitor.swift) and [MenuBarController.swift](Sources/NgrokMonitor/MenuBarController.swift) — every `URLSession` request (all go to `127.0.0.1:4040`)
- [ControlServer.swift](Sources/NgrokMonitor/ControlServer.swift) — the loopback control listener and everything it will do
- [NgrokMonitor.entitlements](NgrokMonitor.entitlements) — what the OS lets us do

## Troubleshooting

**Menu shows "ngrok (version unknown)"** — the app couldn't find `ngrok` on `PATH`. It searches `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `~/.local/bin`, `~/bin`. Install with `brew install ngrok` or symlink it into one of those.

**"Launch at login" fails with "Operation not permitted"** — login-item registration requires a properly bundled `.app` in `/Applications` or `~/Applications`. Make sure you're launching the bundle, not the raw binary in `.build/release/`.

**No tunnels appear after starting** — check that your `ngrok.yml` actually defines tunnels and that `ngrok start --all` works from a regular terminal.

**Gatekeeper blocks the app** — only happens for unsigned dev builds. See the install section.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Release process is documented in [RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE) © David Nguyen
