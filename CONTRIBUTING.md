# Contributing to NgrokMonitor

Thanks for considering a contribution! This is a small macOS menu bar utility — bug reports, fixes, and focused features are all welcome.

## Prerequisites

- macOS 13 (Ventura) or later
- Xcode 15+ command-line tools (`xcode-select --install`)
- Swift 5.9+ (ships with Xcode 15)
- [ngrok](https://ngrok.com/download) installed and authenticated (for runtime testing)

## Building

```bash
git clone https://github.com/dnc4104/ngrok_monitoring.git
cd ngrok_monitoring
swift build -c release        # produces .build/release/NgrokMonitor (binary only)
./build.sh                    # produces ~/Applications/NgrokMonitor.app (proper bundle)
```

Open in Xcode if you prefer a graphical debugger:

```bash
open Package.swift
```

## Running

The binary on its own won't show notifications or register for launch-at-login — those features require a proper `.app` bundle. Always test against the `.app` produced by `./build.sh`.

```bash
open ~/Applications/NgrokMonitor.app
```

## Code Layout

```
Sources/NgrokMonitor/
  main.swift                    # @main entry point + AppDelegate
  Constants.swift               # ngrok search paths, timeouts
  Networking.swift              # local port probe helper
  Models.swift                  # API decoders + TrafficLogEntry
  NgrokProcessManager.swift     # process lifecycle
  TrafficMonitor.swift          # API polling + inactivity detection
  MenuBarController.swift       # NSStatusItem + menu wiring
  Resources/
    bundle.plist                # copied to Info.plist by build.sh
    ngrok-black.png
    ngrok-green.png
    NgrokMonitor.entitlements   # hardened runtime entitlements
```

## Pull Requests

1. Fork and create a topic branch.
2. Keep PRs focused — one feature or fix per PR.
3. Run `swift build` and `./build.sh` locally; both must succeed.
4. Manually verify the affected menu paths (start, stop, auto-stop, tunnel URLs).
5. Add a note under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

## Releasing

See [RELEASING.md](RELEASING.md) for the signing, notarization, and publishing flow.

## Reporting Issues

Include:
- macOS version (`sw_vers`)
- `ngrok --version` output
- Steps to reproduce
- Console output if available (Console.app → filter by "NgrokMonitor")
