---
name: herdr-placement
description: Use when the user asks to start a task in a new herdr worktree, or to hand a task to a new agent through herdr. Decides whether the task runs on the Mac or on an agent-box host such as pc, then creates the worktree and opens the agent in the Herdr app window. Only inside herdr-core (HC_TERMINAL_ID set); in a Rex session without herdr use rex-placement instead. Uses the herdr-app and herdr-core skills, never the old herdr TUI.
---

If `HC_TERMINAL_ID` is not set, stop: this session is not in herdr-core. In Rex (`REX_SESSION` set), use the rex-placement skill.

# Herdr placement

The user watches agents in the Herdr app window. An agent started any other way is invisible to them:

- `hc run --bg ...` starts a terminal with no window.
- The old TUI CLI (`herdr worktree create`, `herdr agent start`) puts it in a TUI session the app does not show. Never use the `herdr` command.

Agent-box hosts (for example `pc`, WSL Ubuntu) exist so that work leaves the Mac. Run a task on a host unless it needs the Mac.

## Decide

Run on the **Mac** when the task needs any of:

- iOS or macOS builds, Xcode, `xcodebuild`, CocoaPods, Fastlane, TestFlight
- the iOS Simulator, `agent-device`, `simctl`, visual iteration on the native app, store screenshots
- an Android emulator (not practical in WSL)
- release vaults (for example `Memoxia Release`): host tokens never include them
- macOS-only tools or apps, or files that exist only on the Mac

Everything else runs on a **host**: servers, web, shared packages, infrastructure, migrations, lint, typecheck, unit tests (including React Native Jest), docs, refactors, reviews.

When the task is mixed or unclear, use the Mac and say why in one line. Tell the user which machine you picked before starting.

## Create the worktree

`hc machine ls` lists hosts; the host must be `connected`.

1. Find the host's home with `ssh <label> 'echo $HOME'`. Remote paths must be absolute: a `~` in your command expands to the Mac's home.
2. Projects live in `<home>/code/<repo>` (or where the user keeps that repo). If the repo is missing, clone it from the Mac checkout's `origin` URL. Otherwise `git fetch origin`.
3. Create the worktree with git, next to the others:
   ```bash
   ssh <label> 'git -C <repo> worktree add -b <branch> <home>/.herdr/worktrees/<repo>/<branch-slug> origin/main'
   ```
   On the Mac, the same `git worktree add` without `ssh`.

## Open the agent in the window

1. Write the prompt to a file in your scratchpad with a quoted heredoc (`<<'EOF'`), so backticks and `$` are not executed by your shell. It states the goal, scope, out-of-scope, the machine's limits (no iOS on hosts, no release vaults), how to validate, the finish line (for example: branch pushed, PR open, not merged), and how to report: `hc send <your HC_TERMINAL_ID> "..."`, with the ID written out.
2. Find the project's space in `herdr-app ls`, matching folder and machine. Without one, create it:
   ```bash
   herdr-app do space.new --name <project> --machine <label> --folder <worktree>
   ```
   (no `--machine` on the Mac). It opens with a shell tab; close that terminal with `hc kill` and `hc rm` once the agent tab exists.
3. Open the agent as a named tab in that space:
   ```bash
   herdr-app do tab.new --space <space-id> --name "<short task>" --argv '["claude"]' --task "$(cat <file>)"
   ```
   If the tab does not start in the worktree, add `--folder <worktree>`; check the exact arguments with `herdr-app commands`.
4. The result names its terminal (`pc/t2z`). `hc ls` must show it `working`; `hc read <terminal> --lines 0` shows its screen. A folder trust prompt for the user's own repository is answered with Enter; any other prompt goes to the user.

Report to the user: machine, space and tab names, branch.
