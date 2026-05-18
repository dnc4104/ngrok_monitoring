import Foundation
import os

/// Subsystem-scoped logger for the app. Use via `log.error(...)`, `log.debug(...)`, etc.
let log = Logger(subsystem: "ch.dnconsulting.NgrokMonitor", category: "ngrok-monitor")
