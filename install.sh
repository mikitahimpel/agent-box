#!/usr/bin/env bash
# agent-box on macOS, Linux and WSL:
#
#   curl -fsSL https://raw.githubusercontent.com/mikitahimpel/agent-box/main/install.sh | bash
#
# The first step on a new machine: gets agent-box into ~/.local/share/packages/agent-box,
# where the dotfiles install keeps it, and runs `setup.sh install` for the machine state
# (GitHub login, Proton Pass token, Tailscale). Then install the dotfiles, which link the
# packages and update agent-box from then on. Safe to rerun: on a machine that has
# agent-box already, it runs `agent-box install`. Arguments after `bash -s --` are passed
# on to setup.sh.

set -euo pipefail

# Everything is inside main so a partial download runs nothing.
main() {
  local repo="https://github.com/mikitahimpel/agent-box.git"
  local dir="${AGENT_BOX_DIR:-$HOME/.local/share/packages/agent-box}"
  local cmd

  if [ -L "$HOME/.local/bin/agent-box" ]; then
    cmd=("$HOME/.local/bin/agent-box" install "$@")
  else
    if ! command -v git >/dev/null 2>&1; then
      case "$(uname -s)" in
        Darwin)
          xcode-select --install 2>/dev/null || true
          echo "Install the Command Line Tools from the dialog, then run this command again."
          exit 1 ;;
        *) sudo apt-get update -qq && sudo apt-get install -y -qq git ;;
      esac
    fi
    if [ ! -d "$dir/.git" ]; then
      mkdir -p "$(dirname "$dir")"
      git clone -q "$repo" "$dir"
    fi
    cmd=("$dir/setup.sh" install "$@")
  fi

  # Piped into bash, stdin is this script; setup.sh's prompts need the terminal.
  if (exec </dev/tty) 2>/dev/null; then
    exec "${cmd[@]}" </dev/tty
  else
    exec "${cmd[@]}"
  fi
}

main "$@"
