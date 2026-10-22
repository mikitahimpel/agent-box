# Shared Claude config

Everything here is installed on every agent-box machine by `agent-box install`.

| Path | Ends up as |
|---|---|
| `CLAUDE.md` | Top of the agent-box section in `~/.claude/CLAUDE.md` (copied; rerun install after edits) |
| `skills/<name>/` | `~/.claude/skills/<name>` (symlink) |
| `commands/<name>.md` | `~/.claude/commands/<name>.md` (symlink) |
| `agents/<name>.md` | `~/.claude/agents/<name>.md` (symlink) |

Symlinked items update with `git pull`. Run `agent-box sync` to pull and reapply in one step.
Deleting an item from the repo removes its link on the next install.
