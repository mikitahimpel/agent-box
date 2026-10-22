#!/usr/bin/env bash
# Checks and installs the agent-box setup on macOS, Linux and WSL.
#
#   agent-box               check only, change nothing (same as ./setup.sh)
#   agent-box install       install or fix everything that is missing
#   agent-box sync          git pull this repo, then install
#   agent-box off [host]    shut a Windows/WSL host down (default: the configured host)
#
# Options (install saves them to ~/.config/agent-box/config for later runs):
#   --role host|client      default: macOS -> client, WSL/Linux -> host
#   --host NAME             Tailscale name of the host (default: pc)
#   --user NAME             Linux user on the host, for clients (asked if missing)
#   --vault NAME            Proton Pass vault agents may read (default: Agents)
#
# A "host" runs agents, a "client" is where you work from. The environment
# variables AGENT_ROLE, AGENT_HOST, AGENT_USER and PASS_VAULT work too.
# Written for bash 3.2 so it runs on stock macOS.

set -uo pipefail

# Follows symlinks without readlink -f, which older macOS lacks.
resolve_path() {
  local p="$1" t
  while [ -L "$p" ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  echo "$p"
}
SCRIPT="$(resolve_path "$0")"
REPO_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
SCRIPT="$REPO_DIR/$(basename "$SCRIPT")"

CONFIG_FILE="$HOME/.config/agent-box/config"
config_get() { [ -f "$CONFIG_FILE" ] && sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -n 1; }

# Precedence: command-line flags, then environment, then saved config, then defaults.
ROLE="${AGENT_ROLE:-$(config_get AGENT_ROLE)}"
AGENT_HOST="${AGENT_HOST:-$(config_get AGENT_HOST)}"
AGENT_USER="${AGENT_USER:-$(config_get AGENT_USER)}"
PASS_VAULT="${PASS_VAULT:-$(config_get PASS_VAULT)}"

TOKEN_SERVICE="proton-pass-agent"
TOKEN_FILE="$HOME/.config/pass-agent/token"
BIN_DIR="$HOME/.local/bin"
HERDR_CONFIG="$HOME/.config/herdr/config.toml"
HERDR_UNIT="$HOME/.config/systemd/user/herdr.service"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
SHARED_CLAUDE="$REPO_DIR/claude"
SHUTDOWN_FLAG="$HOME/.agent-box/shutdown"
SSH_CONFIG="$HOME/.ssh/config"
MARK_START="# >>> agent-box >>>"
MARK_END="# <<< agent-box <<<"

export PATH="$BIN_DIR:$HOME/.claude/local:$PATH"

MODE=check

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
  C_OK=$'\033[32m' C_WARN=$'\033[33m' C_ERR=$'\033[31m' C_DIM=$'\033[2m' C_OFF=$'\033[0m'
else
  C_OK="" C_WARN="" C_ERR="" C_DIM="" C_OFF=""
fi

N_OK=0 N_MISSING=0 N_FIXED=0 N_FAILED=0
NOTES=""

ok()      { N_OK=$((N_OK + 1));           printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$1"; }
missing() { N_MISSING=$((N_MISSING + 1)); printf '  %s○%s %s %s(missing)%s\n' "$C_WARN" "$C_OFF" "$1" "$C_DIM" "$C_OFF"; }
fixed()   { N_FIXED=$((N_FIXED + 1));     printf '  %s✓%s %s %s(installed)%s\n' "$C_OK" "$C_OFF" "$1" "$C_DIM" "$C_OFF"; }
failed()  { N_FAILED=$((N_FAILED + 1));   printf '  %s✗%s %s\n' "$C_ERR" "$C_OFF" "$1"; }
info()    { printf '    %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
section() { printf '\n%s\n' "$1"; }
note()    { NOTES="${NOTES}  • $1"$'\n'; }
die()     { printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$1" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }

# step <description> <check-fn> <install-fn>
# The check function must succeed when the component is in the wanted state.
step() {
  if "$2"; then ok "$1"; return 0; fi
  if [ "$MODE" = check ]; then missing "$1"; return 1; fi
  info "installing: $1"
  if "$3" && "$2"; then fixed "$1"; return 0; fi
  failed "$1"
  return 1
}

need_tty() {
  [ -t 0 ] || { info "needs an interactive terminal"; return 1; }
}

# replace_block <file> <content>: writes content between the managed markers,
# replacing an earlier managed block and leaving the rest of the file alone.
replace_block() {
  local file="$1" content="$2" tmp
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  awk -v s="$MARK_START" -v e="$MARK_END" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] == "") n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$file" > "$tmp"
  { cat "$tmp"; [ -s "$tmp" ] && echo; echo "$MARK_START"; printf '%s\n' "$content"; echo "$MARK_END"; } > "$file"
  rm -f "$tmp"
}

# block_matches <file> <content>: the managed block exists and equals content.
block_matches() {
  [ -f "$1" ] || return 1
  [ "$(awk -v s="$MARK_START" -v e="$MARK_END" '
    $0 == s { inside = 1; next }
    $0 == e { inside = 0; next }
    inside
  ' "$1")" = "$2" ]
}

# ---------------------------------------------------------------- platform

detect_platform() {
  case "$(uname -s)" in
    Darwin) echo mac ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    *) echo unknown ;;
  esac
}

PLATFORM="$(detect_platform)"

apt_install() {
  have apt-get || { info "apt-get not found; install manually: $*"; return 1; }
  sudo apt-get update -qq && sudo apt-get install -y -qq "$@"
}

has_systemd() { [ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ]; }

# ---------------------------------------------------------------- common

check_base_tools() { have curl && have git && have jq; }
install_base_tools() {
  case "$PLATFORM" in
    mac)
      if have brew; then brew install curl git jq
      else info "install Homebrew (https://brew.sh), then rerun"; return 1; fi ;;
    *) apt_install curl git jq ;;
  esac
}

check_path_in_login_shell() {
  local shell="${SHELL:-/bin/bash}"
  "$shell" -lc 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0 ;; *) exit 1 ;; esac' </dev/null >/dev/null 2>&1
}
install_path_in_login_shell() {
  local rc
  case "${SHELL:-}" in
    */zsh) rc="$HOME/.zprofile" ;;
    *) rc="$HOME/.profile" ;;
  esac
  replace_block "$rc" 'export PATH="$HOME/.local/bin:$PATH"'
}

check_claude() { have claude; }
install_claude() { curl -fsSL https://claude.ai/install.sh | bash; }

check_herdr() { have herdr; }
install_herdr() { curl -fsSL https://herdr.dev/install.sh | sh; }

check_herdr_claude() { herdr integration status 2>&1 | grep '^claude: current' >/dev/null; }
install_herdr_claude() { herdr integration install claude; }

check_pass_cli() { have pass-cli; }
install_pass_cli() { curl -fsSL https://proton.me/download/pass-cli/install.sh | bash; }

check_token() {
  if [ "$PLATFORM" = mac ]; then
    security find-generic-password -s "$TOKEN_SERVICE" >/dev/null 2>&1
  else
    [ -s "$TOKEN_FILE" ]
  fi
}
install_token() {
  need_tty || return 1
  local token
  info "Create an agent token at pass.proton.me → Settings → Access tokens"
  info "(vault: $PASS_VAULT, expiry: 1 year, 'Use for AI agent' on), then paste it."
  printf '    token (hidden): '
  read -rs token; echo
  [ -n "$token" ] || return 1
  if [ "$PLATFORM" = mac ]; then
    security add-generic-password -U -a "$USER" -s "$TOKEN_SERVICE" -w "$token"
  else
    mkdir -p "$(dirname "$TOKEN_FILE")" && chmod 700 "$(dirname "$TOKEN_FILE")"
    ( umask 077; printf '%s' "$token" > "$TOKEN_FILE" )
  fi
}

pp_script() {
  cat <<EOF
#!/usr/bin/env bash
# pp: pass-cli that logs in with the stored agent token when the session has expired.
# Managed by agent-box; local edits are overwritten.
set -euo pipefail
export PROTON_PASS_SESSION_DIR="\${PROTON_PASS_SESSION_DIR:-\$HOME/.local/state/pass-agent}"
export PROTON_PASS_AGENT_REASON="\${PROTON_PASS_AGENT_REASON:-agent on \$(hostname)}"

if ! pass-cli info >/dev/null 2>&1; then
  if [[ "\$(uname)" == Darwin ]]; then
    token=\$(security find-generic-password -s $TOKEN_SERVICE -w)
  else
    token=\$(<"$TOKEN_FILE")
  fi
  PROTON_PASS_PERSONAL_ACCESS_TOKEN="\$token" pass-cli login >/dev/null
fi

exec pass-cli "\$@"
EOF
}
check_pp() { [ -x "$BIN_DIR/pp" ] && pp_script | cmp -s - "$BIN_DIR/pp"; }
install_pp() { mkdir -p "$BIN_DIR" && pp_script > "$BIN_DIR/pp" && chmod 755 "$BIN_DIR/pp"; }

# The managed CLAUDE.md block: shared instructions from the repo, then the
# generated sections. Rerun install after editing claude/CLAUDE.md.
claude_md_block() {
  if [ -s "$SHARED_CLAUDE/CLAUDE.md" ]; then
    cat "$SHARED_CLAUDE/CLAUDE.md"
    echo
  fi
  cat <<EOF
## Secrets
- Secrets live in Proton Pass vault "$PASS_VAULT". Never hardcode, log or print them.
- Put references in .env files: \`API_KEY=pass://$PASS_VAULT/<item>/<field>\`
- Run commands that need secrets via: \`pp run --env-file .env -- <command>\`
- Set PROTON_PASS_AGENT_REASON to a short reason before reading secrets.
EOF
  if [ "$ROLE" = host ]; then
    cat <<EOF

## Dev servers
- This machine is reached over Tailscale as "$AGENT_HOST". Bind dev servers to 0.0.0.0
  (for example \`--host 0.0.0.0\`) so they open from the user's other machines.
- When a server is up, give the user its URL as http://$AGENT_HOST:<port>.
EOF
  fi
}
check_claude_md() { block_matches "$CLAUDE_MD" "$(claude_md_block)"; }
install_claude_md() { replace_block "$CLAUDE_MD" "$(claude_md_block)"; }

check_pp_works() { "$BIN_DIR/pp" info >/dev/null 2>&1; }

# Shared skills, commands and agents live in claude/<kind>/<name> in this repo
# and are symlinked into ~/.claude/<kind>/<name>.
SHARED_KINDS="skills commands agents"
shared_items() {
  local kind item
  for kind in $SHARED_KINDS; do
    for item in "$SHARED_CLAUDE/$kind"/*; do
      [ -e "$item" ] && echo "$kind/$(basename "$item")"
    done
  done
}
# Links into this repo whose target was deleted from the repo.
stale_shared_links() {
  local kind link target
  for kind in $SHARED_KINDS; do
    for link in "$CLAUDE_DIR/$kind"/*; do
      [ -L "$link" ] || continue
      target="$(readlink "$link")"
      case "$target" in "$SHARED_CLAUDE/"*) [ -e "$target" ] || echo "$link" ;; esac
    done
  done
}
check_shared_claude() {
  local rel
  for rel in $(shared_items); do
    [ "$(readlink "$CLAUDE_DIR/$rel" 2>/dev/null)" = "$SHARED_CLAUDE/$rel" ] || return 1
  done
  [ -z "$(stale_shared_links)" ]
}
install_shared_claude() {
  local rel target link
  for link in $(stale_shared_links); do rm -f "$link"; done
  for rel in $(shared_items); do
    target="$CLAUDE_DIR/$rel"
    [ "$(readlink "$target" 2>/dev/null)" = "$SHARED_CLAUDE/$rel" ] && continue
    if [ -e "$target" ] || [ -L "$target" ]; then
      info "~/.claude/$rel exists and isn't from agent-box; move it into claude/$rel or delete it"
      return 1
    fi
    mkdir -p "$(dirname "$target")" && ln -s "$SHARED_CLAUDE/$rel" "$target" || return 1
  done
}

check_agent_box_cmd() { [ "$(readlink "$BIN_DIR/agent-box" 2>/dev/null)" = "$SCRIPT" ]; }
install_agent_box_cmd() { mkdir -p "$BIN_DIR" && ln -sfn "$SCRIPT" "$BIN_DIR/agent-box"; }

config_body() {
  printf 'AGENT_ROLE=%s\nAGENT_HOST=%s\nAGENT_USER=%s\nPASS_VAULT=%s\n' \
    "$ROLE" "$AGENT_HOST" "$AGENT_USER" "$PASS_VAULT"
}
check_config_saved() { [ -f "$CONFIG_FILE" ] && config_body | cmp -s - "$CONFIG_FILE"; }
install_config_saved() { mkdir -p "$(dirname "$CONFIG_FILE")" && config_body > "$CONFIG_FILE"; }

# ---------------------------------------------------------------- shutdown

# `agent-box off`: asks a Windows/WSL host to shut down. The Windows task
# "agent-box remote shutdown" polls `_shutdown-pending` every minute.
request_shutdown() {
  local target="${1:-$AGENT_HOST}"
  if [ "$ROLE" = host ] && [ "$target" = "$AGENT_HOST" ]; then
    mkdir -p "$(dirname "$SHUTDOWN_FLAG")" && touch "$SHUTDOWN_FLAG" || exit 1
  else
    ssh -o ConnectTimeout=10 "$target" 'mkdir -p ~/.agent-box && touch ~/.agent-box/shutdown' \
      || die "couldn't reach $target"
  fi
  echo "Shutdown requested for $target; Windows turns off within about 2 minutes."
}

# Succeeds once for a request made in the last 5 minutes. Old requests are
# dropped, so a flag left over from before a reboot never shuts the PC down again.
shutdown_pending() {
  [ -f "$SHUTDOWN_FLAG" ] || return 1
  local fresh
  fresh="$(find "$SHUTDOWN_FLAG" -mmin -5)"
  rm -f "$SHUTDOWN_FLAG"
  [ -n "$fresh" ]
}

# ---------------------------------------------------------------- host

WSL_CONF_WANTED='[boot]
systemd=true

[automount]
enabled=false'

check_wsl_conf() {
  [ -f /etc/wsl.conf ] \
    && grep -Eq '^\s*systemd\s*=\s*true' /etc/wsl.conf \
    && grep -Eq '^\s*enabled\s*=\s*false' /etc/wsl.conf
}
install_wsl_conf() {
  [ -f /etc/wsl.conf ] && sudo cp /etc/wsl.conf "/etc/wsl.conf.bak.$(date +%s)"
  printf '%s\n' "$WSL_CONF_WANTED" | sudo tee /etc/wsl.conf >/dev/null || return 1
  note "WSL config changed: run 'wsl --shutdown' in Windows PowerShell, reopen Ubuntu, rerun this script."
}

check_systemd_running() { has_systemd; }
install_systemd_running() {
  info "systemd is not PID 1 yet; restart WSL ('wsl --shutdown') and rerun"
  return 1
}

check_sandbox_deps() { have bwrap && have socat; }
install_sandbox_deps() { apt_install bubblewrap socat; }

check_tailscale() { have tailscale; }
install_tailscale() {
  if [ "$PLATFORM" = mac ]; then
    if have brew; then brew install --cask tailscale
    else info "install Tailscale from the Mac App Store, then rerun"; return 1; fi
  else
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
}

check_tailscaled() { systemctl is-enabled tailscaled >/dev/null 2>&1 && systemctl is-active tailscaled >/dev/null 2>&1; }
install_tailscaled() { sudo systemctl enable --now tailscaled; }

ts_running() { [ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" = Running ]; }
ts_prefs() { tailscale debug prefs 2>/dev/null || sudo -n tailscale debug prefs 2>/dev/null; }

check_tailscale_up() {
  ts_running || return 1
  ts_prefs | jq -e --arg h "$AGENT_HOST" '.RunSSH == true and .Hostname == $h' >/dev/null
}
install_tailscale_up() {
  need_tty || return 1
  if ts_running; then
    sudo tailscale set --ssh --hostname="$AGENT_HOST"
  else
    sudo tailscale up --ssh --hostname="$AGENT_HOST"
  fi
}

check_herdr_shell_mode() { [ -f "$HERDR_CONFIG" ] && grep -Eq '^\s*shell_mode\s*=\s*"login"' "$HERDR_CONFIG"; }
install_herdr_shell_mode() {
  mkdir -p "$(dirname "$HERDR_CONFIG")"
  touch "$HERDR_CONFIG"
  local tmp
  tmp="$(mktemp)"
  if grep -Eq '^\s*\[terminal\]' "$HERDR_CONFIG"; then
    awk '
      /^[[:space:]]*shell_mode[[:space:]]*=/ { next }
      { print }
      /^[[:space:]]*\[terminal\]/ { print "shell_mode = \"login\"" }
    ' "$HERDR_CONFIG" > "$tmp"
  else
    { cat "$HERDR_CONFIG"; printf '\n[terminal]\nshell_mode = "login"\n'; } > "$tmp"
  fi
  mv "$tmp" "$HERDR_CONFIG"
}

herdr_unit() {
  cat <<EOF
[Unit]
Description=Herdr server (agent-box)

[Service]
ExecStart=$(command -v herdr) server
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}
check_herdr_service() {
  have herdr && [ -f "$HERDR_UNIT" ] && herdr_unit | cmp -s - "$HERDR_UNIT" \
    && systemctl --user is-enabled herdr >/dev/null 2>&1 \
    && systemctl --user is-active herdr >/dev/null 2>&1
}
install_herdr_service() {
  have herdr || return 1
  mkdir -p "$(dirname "$HERDR_UNIT")"
  herdr_unit > "$HERDR_UNIT"
  systemctl --user daemon-reload && systemctl --user enable --now herdr
}

check_linger() { loginctl show-user "$USER" -p Linger 2>/dev/null | grep 'Linger=yes' >/dev/null; }
install_linger() { sudo loginctl enable-linger "$USER"; }

# ---------------------------------------------------------------- client

check_tailscale_client() { have tailscale || [ -d /Applications/Tailscale.app ]; }

ssh_block() {
  printf 'Host %s\n    HostName %s\n    User %s' "$AGENT_HOST" "$AGENT_HOST" "$AGENT_USER"
}
current_ssh_user() {
  awk -v s="$MARK_START" -v e="$MARK_END" '
    $0 == s { inside = 1; next }
    $0 == e { inside = 0; next }
    inside && $1 == "User" { print $2 }
  ' "$SSH_CONFIG" 2>/dev/null
}
check_ssh_config() {
  [ -n "$AGENT_USER" ] || AGENT_USER="$(current_ssh_user)"
  [ -n "$AGENT_USER" ] && block_matches "$SSH_CONFIG" "$(ssh_block)"
}
install_ssh_config() {
  if [ -z "$AGENT_USER" ]; then
    need_tty || { info "set AGENT_USER=<linux user on $AGENT_HOST>"; return 1; }
    printf '    Linux user on %s: ' "$AGENT_HOST"
    read -r AGENT_USER
    [ -n "$AGENT_USER" ] || return 1
  fi
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  replace_block "$SSH_CONFIG" "$(ssh_block)"
  chmod 600 "$SSH_CONFIG"
}

check_ssh_reachable() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$AGENT_HOST" true </dev/null >/dev/null 2>&1; }
install_ssh_reachable() {
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$AGENT_HOST" true </dev/null \
    || { info "is $AGENT_HOST turned on and online in Tailscale?"; return 1; }
}

check_herdr_machine() {
  herdr machine list --json 2>/dev/null \
    | jq -e --arg l "$AGENT_HOST" '[.. | objects | .label? // empty] | index($l) != null' >/dev/null
}
install_herdr_machine() {
  need_tty || return 1
  herdr machine add "$AGENT_HOST" --label "$AGENT_HOST"
}

# ---------------------------------------------------------------- main

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SCRIPT"; }

OFF_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    check|install|sync) MODE="$1" ;;
    off) MODE=off; case "${2:-}" in ""|-*) ;; *) OFF_TARGET="$2"; shift ;; esac ;;
    _shutdown-pending) shutdown_pending; exit $? ;;
    --role) ROLE="${2:-}"; shift ;;
    --host) AGENT_HOST="${2:-}"; shift ;;
    --user) AGENT_USER="${2:-}"; shift ;;
    --vault) PASS_VAULT="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[ "$PLATFORM" != unknown ] || die "unsupported OS: $(uname -s)"
if [ -z "$ROLE" ]; then
  if [ "$PLATFORM" = mac ]; then ROLE=client; else ROLE=host; fi
fi
AGENT_HOST="${AGENT_HOST:-pc}"
PASS_VAULT="${PASS_VAULT:-Agents}"
case "$ROLE" in host|client) ;; *) die "--role must be host or client" ;; esac
[ "$ROLE" = host ] && [ "$PLATFORM" = mac ] && die "macOS is supported as a client only"

if [ "$MODE" = off ]; then
  request_shutdown "$OFF_TARGET"
  exit 0
fi
if [ "$MODE" = sync ]; then
  git -C "$REPO_DIR" pull --ff-only || die "git pull failed in $REPO_DIR"
  MODE=install
fi

printf 'agent-box · %s · role: %s · mode: %s\n' "$PLATFORM" "$ROLE" "$MODE"

section "Base"
step "curl, git, jq"                      check_base_tools          install_base_tools
step "~/.local/bin on login-shell PATH"   check_path_in_login_shell install_path_in_login_shell
step "agent-box command"                  check_agent_box_cmd       install_agent_box_cmd

if [ "$ROLE" = host ]; then
  if [ "$PLATFORM" = wsl ]; then
    section "WSL"
    step "/etc/wsl.conf (systemd on, Windows drives hidden)" check_wsl_conf install_wsl_conf
  fi
  step "systemd running"                  check_systemd_running     install_systemd_running
  SYSTEMD=0; has_systemd && SYSTEMD=1

  section "Network"
  step "Tailscale installed"              check_tailscale           install_tailscale
  if [ "$SYSTEMD" = 1 ]; then
    step "tailscaled enabled at boot"     check_tailscaled          install_tailscaled
    step "Tailscale up as '$AGENT_HOST' with Tailscale SSH" check_tailscale_up install_tailscale_up
  else
    info "skipping Tailscale service steps until systemd runs"
  fi
fi

if [ "$ROLE" = client ]; then
  section "Network"
  step "Tailscale installed"              check_tailscale_client    install_tailscale
fi

section "Agents"
step "Claude Code"                        check_claude              install_claude
step "herdr"                              check_herdr               install_herdr
have herdr && step "herdr ↔ Claude integration" check_herdr_claude install_herdr_claude
step "shared Claude config (claude/ in this repo)" check_shared_claude install_shared_claude
if [ "$ROLE" = host ]; then
  step "Claude sandbox deps (bubblewrap, socat)" check_sandbox_deps install_sandbox_deps
  step "herdr panes use login shells"     check_herdr_shell_mode    install_herdr_shell_mode
  if [ "$SYSTEMD" = 1 ]; then
    step "herdr server starts at boot"    check_herdr_service       install_herdr_service
    step "user services run without login (linger)" check_linger   install_linger
  fi
fi

section "Secrets (Proton Pass)"
step "pass-cli"                           check_pass_cli            install_pass_cli
step "agent token stored"                 check_token               install_token
step "pp wrapper"                         check_pp                  install_pp
step "CLAUDE.md agent-box section"        check_claude_md           install_claude_md
if have pass-cli && check_token && check_pp; then
  step "pp can log in"                    check_pp_works            check_pp_works
fi

if [ "$ROLE" = client ]; then
  section "Connection to $AGENT_HOST"
  step "SSH config for '$AGENT_HOST'"        check_ssh_config          install_ssh_config
  if check_ssh_config; then
    step "$AGENT_HOST reachable over SSH"    check_ssh_reachable       install_ssh_reachable
  fi
  if have herdr && check_ssh_reachable; then
    step "herdr machine '$AGENT_HOST' saved" check_herdr_machine       install_herdr_machine
  fi
fi

section "Settings"
step "saved to ~/.config/agent-box/config" check_config_saved       install_config_saved

if [ "$ROLE" = client ]; then
  note "Keep Tailscale connected on this machine (it is the only login to $AGENT_HOST)."
fi
if [ "$ROLE" = host ]; then
  note "Tailscale admin console: disable key expiry for '$AGENT_HOST'."
  note "Tailscale admin console → Access controls: SSH rule action \"accept\" (see README)."
  note "Inside WSL, log in once: 'claude', and 'gh auth login' if agents push to GitHub."
fi

printf '\n%d ok · %d installed · %d missing · %d failed\n' "$N_OK" "$N_FIXED" "$N_MISSING" "$N_FAILED"
if [ -n "$NOTES" ]; then printf '\nManual steps:\n%s' "$NOTES"; fi
if [ "$MODE" = check ] && [ "$N_MISSING" -gt 0 ]; then
  printf '\nRun %sagent-box install%s (or ./setup.sh install) to fix missing items.\n' "$C_WARN" "$C_OFF"
fi

[ "$N_MISSING" -eq 0 ] && [ "$N_FAILED" -eq 0 ]
