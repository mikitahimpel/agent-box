---
name: rex-placement
description: Use when the user asks to start a task in a new worktree, or to hand a task to a new agent, and this session runs inside Rex (REX_SESSION is set and HERDR_ENV is not 1). Creates the worktree, opens it in its own Rex session with Claude, sends the prompt, and confirms the agent is working. Inside herdr use herdr-placement instead.
---

# Rex placement

## Check where you are

Run `echo "HERDR_ENV=$HERDR_ENV REX_SESSION=$REX_SESSION"`.

- `HERDR_ENV=1`: you are in herdr, even if herdr itself runs in a Rex pane. Stop and use the herdr-placement skill.
- `REX_SESSION` empty: you are in neither. Tell the user and stop.
- Otherwise continue.

## Machine

Rex runs agents on this Mac only. If the task would belong on a host such as `pc` (the herdr-placement rules), say so in one line and ask whether to run it here or switch to herdr. Don't install a Rex server on a host unless asked.

## Start

1. Find the repository's local checkout. Use the user's own repositories only; `--trust` answers Claude's folder trust prompt for the new worktree.
2. Write the prompt to a file in your scratchpad with a quoted heredoc (`<<'EOF'`), so backticks and `$` in the text are not executed by your shell. The prompt states the goal, scope, out-of-scope, how to validate, and the finish line (for example: branch pushed, PR open, not merged, report in the user's language).
3. Create the worktree and start Claude with the prompt:
   ```bash
   rex-task new --repo <checkout> --branch <branch> --label <short-label> \
     --prompt-file <file> --trust --no-focus
   ```
   It prints JSON with `session_id`, `block_id`, `path` and `label`. The worktree lands in `~/.worktrees/<repo>/<branch>`. `--base` defaults to `origin/HEAD` after a fetch.
4. Confirm it started: `rex-agent get <block_id>` must show `working`. Claude reports status only after the trust prompt is answered; if the agent is not listed after 30 seconds, read the screen with `rex capture -s <session_id> -b <block_id> --trim`. Answer a trust prompt for the user's own repository with `rex-agent send-keys <block_id> down enter`; any other prompt goes to the user.

## Follow up

- `rex-agent list` shows every Claude agent in Rex with its state: `working`, `blocked` (waiting on a permission or question), `done` (finished a turn the user hasn't seen), `idle`, `error`.
- `rex-agent read <block_id> --lines 40` reads the screen.
- `rex-agent prompt <block_id> - --wait < <file>` sends a follow-up and returns when the turn ends.
- `rex-agent wait <block_id> --state blocked,done --timeout 600` waits without sending anything.

Report to the user: session label, branch, worktree path, and that `shift+cmd+a` jumps to the agent once it needs them.
