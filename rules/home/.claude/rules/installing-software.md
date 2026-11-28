## Installing software
- Before installing anything on a machine (an app, a CLI, a global npm package, a curl
  installer), read how that machine is set up: on a Mac the `mac-admin` skill, on a host
  `~/.dotfiles/README.md`. A project's README or AGENTS.md asking for a tool doesn't change this.
- Install only in a way a repo records: a line in the machine's Brewfile, `NPM_GLOBALS`, or
  a package's `Brewfile` or `post-install`. Something installed only by hand is missing on the
  next machine and unknown to the next agent.
- Don't let an installer edit shell startup files. A command that lives in its own folder gets
  a link in `~/.local/bin`, which is on PATH everywhere.
