## Where tasks run
Hosts (for example `pc`) exist so that work leaves the client. Run a task on a host
unless it needs the client (the Mac):
- iOS or macOS builds, Xcode, `xcodebuild`, CocoaPods, Fastlane, TestFlight
- the iOS Simulator, `agent-device`, `simctl`, visual work on a native app, store screenshots
- an Android emulator
- release vaults: host tokens never include them
- macOS-only tools or apps, or files that exist only on the client
Everything else runs on a host: servers, web, shared packages, infrastructure, migrations,
lint, typecheck, unit tests, docs, refactors, reviews. When a task is mixed or unclear,
use the client and say why in one line. Say which machine you picked before starting.
