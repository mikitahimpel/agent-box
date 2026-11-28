## Working rules
- Write code a person can review: one function per job with named steps, one statement
  per line, no side effects inside conditions, thresholds as named constants with the
  reason, comments that match the code, lines up to 100 characters. In an Effect codebase
  use Effect throughout (files, processes, typed errors), not half and half.
- Write a comment only for a reader who has just the file: a non-obvious why, a hidden
  invariant, a workaround with its cause, or code that looks wrong on purpose. Rename or
  extract before commenting. Never describe the chat, the request or an earlier version.
- For migrations and compatibility, build an honest boundary (a WebView, a subprocess,
  IPC) or rewrite openly. Never re-implement another library's API under its names.
- Once a task's work is accepted (PR merged, or the user says nothing more is needed),
  remove its worktree: check that `git status` is clean, every commit is pushed or merged
  and no agent works there, then `git worktree remove` without `--force`. Keep worktrees
  with open PRs; if a check fails, leave it and tell the user.
