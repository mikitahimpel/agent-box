## Working rules
- Write code a person can review: one function per job with named steps, one statement
  per line, no side effects inside conditions, thresholds as named constants with the
  reason, comments that match the code, lines up to 100 characters. In an Effect codebase
  use Effect throughout (files, processes, typed errors), not half and half.
- For migrations and compatibility, build an honest boundary (a WebView, a subprocess,
  IPC) or rewrite openly. Never re-implement another library's API under its names.
- Once a task's work is accepted (PR merged, or the user says nothing more is needed),
  remove its worktree: check that `git status` is clean, every commit is pushed or merged
  and no agent works there, then `git worktree remove` without `--force`. Keep worktrees
  with open PRs; if a check fails, leave it and tell the user.

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
