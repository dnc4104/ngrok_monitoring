# Changelog

All notable changes to NgrokMonitor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-06-01

### Added
- Configurable global keyboard shortcut to start/stop ngrok from anywhere.
  Record it in the new Preferences window (⌘,); the active binding is shown
  in the menu.
- "Starting…" feedback while ngrok spins up: the menu-bar icon blinks
  green/black, the menu shows a 🟡 status, and repeat shortcut presses are
  ignored until startup resolves.

## [1.0.0] - 2026-05-18

### Added
- Menu bar app for managing ngrok tunnels on macOS.
- One-click start/stop of `ngrok start --all`.
- Live tunnel URL list with click-to-open in browser.
- Recent traffic log (most recent 5 requests, method + path).
- Auto-stop after configurable inactivity timeout (1m / 5m / 10m / 30m).
- System notifications when ngrok auto-stops.
- ngrok version display and `ngrok update` from the menu.
- "Edit ngrok config…" shortcut to open `ngrok.yml`.
- Launch-at-login toggle via `SMAppService`.
- Signed/notarized `.app` distribution.
