# Changelog

All notable changes to NgrokMonitor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
