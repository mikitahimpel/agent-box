## iOS Simulator
- Drive the iOS Simulator with `agent-device` (skills `ios-simulator`, `agent-device`), not
  computer use: it taps through XCTest and leaves the user's cursor alone.
- Use computer use for the simulator only when agent-device cannot do the step, and say why.
- Screenshots: `agent-device screenshot` or `xcrun simctl io booted screenshot <path>`.
