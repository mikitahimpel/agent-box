#!/usr/bin/env bash
# Checks and installs the agent PC setup on macOS, Linux and WSL.
#
#   ./setup.sh               check only, change nothing
#   ./setup.sh install       install or fix everything that is missing
#   ./setup.sh install --role host|client
#
# Roles: "host" is the machine agents run on (WSL/Linux, reachable as $PC_HOST),
# "client" is the machine you work from (your Mac). Defaults: macOS -> client,
# WSL/Linux -> host.
#
# Settings (environment variables):
#   PC_HOST     Tailscale name of the host           (default: pc)
#   PC_USER     Linux user on the host, client only  (asked if missing)
#   PASS_VAULT  Proton Pass vault agents may read    (default: Agents)
#
# Written for bash 3.2 so it runs on stock macOS.

set -uo pipefail

PC_HOST="${PC_HOST:-pc}"
PC_USER="${PC_USER:-}"
PASS_VAULT="${PASS_VAULT:-Agents}"

TOKEN_SERVICE="proton-pass-agent"
TOKEN_FILE="$HOME/.config/pass-agent/token"
BIN_DIR="$HOME/.local/bin"
HERDR_CONFIG="$HOME/.config/herdr/config.toml"
HERDR_UNIT="$HOME/.config/systemd/user/herdr.service"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
SSH_CONFIG="$HOME/.ssh/config"
MARK_START="# >>> agent-pc-setup >>>"
MARK_END="# <<< agent-pc-setup <<<"

export PATH="$BIN_DIR:$HOME/.claude/local:$PATH"

MODE=check
ROLE=""

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
# Managed by agent-pc-setup; local edits are overwritten.
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

claude_md_block() {
  cat <<EOF
## Secrets
- Secrets live in Proton Pass vault "$PASS_VAULT". Never hardcode, log or print them.
- Put references in .env files: \`API_KEY=pass://$PASS_VAULT/<item>/<field>\`
- Run commands that need secrets via: \`pp run --env-file .env -- <command>\`
- Set PROTON_PASS_AGENT_REASON to a short reason before reading secrets.
EOF
}
check_claude_md() { block_matches "$CLAUDE_MD" "$(claude_md_block)"; }
install_claude_md() { replace_block "$CLAUDE_MD" "$(claude_md_block)"; }

check_pp_works() { "$BIN_DIR/pp" info >/dev/null 2>&1; }

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
  ts_prefs | jq -e --arg h "$PC_HOST" '.RunSSH == true and .Hostname == $h' >/dev/null
}
install_tailscale_up() {
  need_tty || return 1
  if ts_running; then
    sudo tailscale set --ssh --hostname="$PC_HOST"
  else
    sudo tailscale up --ssh --hostname="$PC_HOST"
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
Description=Herdr server (agent-pc-setup)

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
  printf 'Host %s\n    HostName %s\n    User %s' "$PC_HOST" "$PC_HOST" "$PC_USER"
}
current_ssh_user() {
  awk -v s="$MARK_START" -v e="$MARK_END" '
    $0 == s { inside = 1; next }
    $0 == e { inside = 0; next }
    inside && $1 == "User" { print $2 }
  ' "$SSH_CONFIG" 2>/dev/null
}
check_ssh_config() {
  [ -n "$PC_USER" ] || PC_USER="$(current_ssh_user)"
  [ -n "$PC_USER" ] && block_matches "$SSH_CONFIG" "$(ssh_block)"
}
install_ssh_config() {
  if [ -z "$PC_USER" ]; then
    need_tty || { info "set PC_USER=<linux user on $PC_HOST>"; return 1; }
    printf '    Linux user on %s: ' "$PC_HOST"
    read -r PC_USER
    [ -n "$PC_USER" ] || return 1
  fi
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  replace_block "$SSH_CONFIG" "$(ssh_block)"
  chmod 600 "$SSH_CONFIG"
}

check_ssh_reachable() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$PC_HOST" true </dev/null >/dev/null 2>&1; }
install_ssh_reachable() {
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$PC_HOST" true </dev/null \
    || { info "is $PC_HOST turned on and online in Tailscale?"; return 1; }
}

check_herdr_machine() {
  herdr machine list --json 2>/dev/null \
    | jq -e --arg l "$PC_HOST" '[.. | objects | .label? // empty] | index($l) != null' >/dev/null
}
install_herdr_machine() {
  need_tty || return 1
  herdr machine add "$PC_HOST" --label "$PC_HOST"
}

# ---------------------------------------------------------------- main

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    check|install) MODE="$1" ;;
    --role) ROLE="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[ "$PLATFORM" != unknown ] || die "unsupported OS: $(uname -s)"
if [ -z "$ROLE" ]; then
  if [ "$PLATFORM" = mac ]; then ROLE=client; else ROLE=host; fi
fi
case "$ROLE" in host|client) ;; *) die "--role must be host or client" ;; esac
[ "$ROLE" = host ] && [ "$PLATFORM" = mac ] && die "macOS is supported as a client only"

printf 'agent-pc-setup · %s · role: %s · mode: %s\n' "$PLATFORM" "$ROLE" "$MODE"

section "Base"
step "curl, git, jq"                      check_base_tools          install_base_tools
step "~/.local/bin on login-shell PATH"   check_path_in_login_shell install_path_in_login_shell

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
    step "Tailscale up as '$PC_HOST' with Tailscale SSH" check_tailscale_up install_tailscale_up
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
step "CLAUDE.md secrets instructions"     check_claude_md           install_claude_md
if have pass-cli && check_token && check_pp; then
  step "pp can log in"                    check_pp_works            check_pp_works
fi

if [ "$ROLE" = client ]; then
  section "Connection to $PC_HOST"
  step "SSH config for '$PC_HOST'"        check_ssh_config          install_ssh_config
  if check_ssh_config; then
    step "$PC_HOST reachable over SSH"    check_ssh_reachable       install_ssh_reachable
  fi
  if have herdr && check_ssh_reachable; then
    step "herdr machine '$PC_HOST' saved" check_herdr_machine       install_herdr_machine
  fi
fi

if [ "$ROLE" = client ]; then
  note "Keep Tailscale connected on this machine (it is the only login to $PC_HOST)."
fi
if [ "$ROLE" = host ]; then
  note "Tailscale admin console: disable key expiry for '$PC_HOST'."
  note "Tailscale admin console → Access controls: SSH rule action \"accept\" (see README)."
  note "Inside WSL, log in once: 'claude', and 'gh auth login' if agents push to GitHub."
fi

printf '\n%d ok · %d installed · %d missing · %d failed\n' "$N_OK" "$N_FIXED" "$N_MISSING" "$N_FAILED"
if [ -n "$NOTES" ]; then printf '\nManual steps:\n%s' "$NOTES"; fi
if [ "$MODE" = check ] && [ "$N_MISSING" -gt 0 ]; then
  printf '\nRun %s./setup.sh install%s to fix missing items.\n' "$C_WARN" "$C_OFF"
fi

[ "$N_MISSING" -eq 0 ] && [ "$N_FAILED" -eq 0 ]
