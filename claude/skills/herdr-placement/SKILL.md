---
name: herdr-placement
description: Use when the user asks to start a task in a new herdr worktree, or to hand a task to a new agent through herdr. Decides whether the task runs on the Mac or on an agent-box host such as pc, then creates the worktree and starts the agent there. Only inside herdr (HERDR_ENV=1); in a Rex session without herdr use rex-placement instead. Read the herdr skill for command details.
---

If `HERDR_ENV` is not `1`, stop: this session is not in herdr. In Rex (`REX_SESSION` set), use the rex-placement skill.

# Herdr placement

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

## Start on a host

`herdr machine list --json` lists hosts; `herdr machine status <label> --json` must report `reachable`. Every later command takes `--machine <label>`.

1. Find the host's home with `ssh <label> 'echo $HOME'`. Remote paths must be absolute: a `~` in your command expands to the Mac's home.
2. Projects live in `<home>/code/<repo>`. If the repo is missing there, clone it from the Mac checkout's `origin` URL (`ssh <label> 'git clone <url> <home>/code/<repo>'`). Otherwise `git pull --ff-only` on its default branch.
3. Create the worktree:
   ```bash
   herdr --machine <label> worktree create --cwd <home>/code/<repo> \
     --branch <branch> --base origin/main --label <short-label> --no-focus --trust-repository
   ```
   Take `root_pane.pane_id` from the JSON result.
4. Start the agent: `herdr --machine <label> agent start <name> --kind claude --pane <pane_id>`. If it reports `agent_not_ready`, read the pane. A folder trust prompt for the user's own repository is answered with `send-keys <name> Down Enter`; any other prompt goes to the user.

## Start on the Mac

Same steps without `--machine`, using the local checkout as `--cwd`.

## Hand over the task

- Write the prompt to a file in your scratchpad with a quoted heredoc (`<<'EOF'`), so backticks and `$` in the text are not executed by your shell. Send it with `herdr [--machine <label>] agent prompt <name> "$(cat <file>)"`.
- The prompt states the goal, scope, out-of-scope, the machine's limits (no iOS on hosts, no release vaults), how to validate, and the finish line (for example: branch pushed, PR open, not merged, report in the user's language).
- After sending, `agent get <name>` must show `working`. If it is `idle` and the pane shows `[Pasted text ...]` in the input, send `Enter`.

Report to the user: machine, workspace label, agent name, branch.
