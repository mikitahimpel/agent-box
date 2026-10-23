#!/usr/bin/env bash
# agent-box on macOS, Linux and WSL:
#
#   curl -fsSL https://raw.githubusercontent.com/mikitahimpel/agent-box/main/install.sh | bash
#
# Gets agent-box into ~/agent-box (or updates the copy this machine already
# uses) and runs `setup.sh install`. Safe to rerun. Arguments after
# `bash -s --` are passed on to setup.sh.

set -euo pipefail

# Everything is inside main so a partial download runs nothing.
main() {
  local repo="https://github.com/mikitahimpel/agent-box.git"
  local dir="${AGENT_BOX_DIR:-$HOME/agent-box}"
  local cmd

  if [ -L "$HOME/.local/bin/agent-box" ]; then
    cmd=("$HOME/.local/bin/agent-box" sync "$@")
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
    if [ -d "$dir/.git" ]; then
      git -C "$dir" pull --ff-only
    else
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
