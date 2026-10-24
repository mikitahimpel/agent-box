#!/usr/bin/env bash
# Checks and installs the agent-box setup on macOS, Linux and WSL.
#
#   agent-box               check only, change nothing (same as ./setup.sh)
#   agent-box install       install or fix everything that is missing
#   agent-box sync          git pull this repo, then install
#   agent-box off [host]    shut a host down (default: this host, or the first on a client)
#   agent-box add [user@]address [--host name]
#                           from a client: set up a Linux machine reachable over SSH
#                           (e.g. pi@raspberrypi.local) as a host and connect to it
#
# Options (install saves them to ~/.config/agent-box/config for later runs):
#   --role host|client      default: macOS -> client, WSL/Linux -> host
#   --host NAME             on a host: its Tailscale name (default: the current one,
#                           else asked)
#   --host [USER@]NAME,...  on a client: the hosts to connect to (default: hosts found
#                           on Tailscale that run agent-box, plus earlier ones)
#   --user NAME             Linux user for client hosts given without USER@ (asked if missing)
#   --vault NAME            Proton Pass vault agents may read (default: Agents)
#   --autonomous on|off     Claude works without prompts inside its sandbox (default: off)
#
# A "host" runs agents, a "client" is where you work from. The environment
# variables AGENT_ROLE, AGENT_HOST, AGENT_HOSTS, AGENT_USER, PASS_VAULT and
# AGENT_AUTONOMOUS work too.
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
AGENT_HOSTS="${AGENT_HOSTS:-$(config_get AGENT_HOSTS)}"
AGENT_USER="${AGENT_USER:-$(config_get AGENT_USER)}"
PASS_VAULT="${PASS_VAULT:-$(config_get PASS_VAULT)}"
AUTONOMOUS="${AGENT_AUTONOMOUS:-$(config_get AGENT_AUTONOMOUS)}"

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

# Anything here owned by root (left by an earlier `sudo`) makes the installers
# fail with "permission denied".
OWNED_DIRS=".local .config .claude .ssh"
foreign_files() {
  local d
  for d in $OWNED_DIRS; do
    [ -e "$HOME/$d" ] && find "$HOME/$d" ! -user "$(id -u)" -print -quit 2>/dev/null
  done
}
check_home_owned() { [ -z "$(foreign_files)" ]; }
install_home_owned() {
  local d
  info "taking back files in your home folder owned by another user (root)"
  for d in $OWNED_DIRS; do
    [ -e "$HOME/$d" ] && sudo chown -R "$(id -u):$(id -g)" "$HOME/$d"
  done
  return 0
}

check_claude() { have claude; }
install_claude() { curl -fsSL https://claude.ai/install.sh | bash; }

check_herdr() { have herdr; }
install_herdr() { curl -fsSL https://herdr.dev/install.sh | sh; }

check_herdr_claude() { herdr integration status 2>&1 | grep '^claude: current' >/dev/null; }
install_herdr_claude() { herdr integration install claude; }

check_pass_cli() { have pass-cli; }
install_pass_cli() { curl -fsSL https://proton.me/download/pass-cli/install.sh | bash; }

# Agent tokens look like pst_<token>::<key>.
valid_token() {
  case "$1" in *[[:space:]]*) return 1 ;; pst_?*::?*) return 0 ;; *) return 1 ;; esac
}
stored_token() {
  if [ "$PLATFORM" = mac ]; then
    security find-generic-password -s "$TOKEN_SERVICE" -w 2>/dev/null
  else
    cat "$TOKEN_FILE" 2>/dev/null
  fi
}
check_token() { valid_token "$(stored_token)"; }
install_token() {
  need_tty || return 1
  local raw token try
  info "Create an agent token at pass.proton.me → Settings → Access tokens"
  info "(vault: $PASS_VAULT, expiry: 1 year, 'Use for AI agent' on), then paste it."
  for try in 1 2 3; do
    printf '    token (hidden): '
    read -rs raw; echo
    # Terminals may wrap a paste in escape codes or add spaces; keep only the token.
    token="$(printf '%s' "$raw" | LC_ALL=C tr -d '\000-\037\177' | sed 's/\[20[01]~//g' \
      | grep -o 'pst_[^[:space:]]*::[^[:space:]]*' | head -n 1)"
    valid_token "$token" && break
    info "Not accepted. Paste the whole token: it begins with pst_ and has :: in the middle."
    info "Got ${#raw} characters; pst_ $(case "$raw" in *pst_*) echo found ;; *) echo missing ;; esac), :: $(case "$raw" in *::*) echo found ;; *) echo missing ;; esac)."
    token=""
  done
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
export PATH="$BIN_DIR:\$PATH"
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

# Autonomous mode: Bash runs inside Claude's sandbox without prompts, file edits
# are auto-approved, and Claude refuses to start if the sandbox is unavailable.
# Hosts outside allowedDomains still prompt; add them to claude/allowed-domains.txt.
autonomous_settings() {
  local domains
  domains="$(grep -Ev '^[[:space:]]*(#|$)' "$SHARED_CLAUDE/allowed-domains.txt" 2>/dev/null | jq -R . | jq -s .)"
  jq -n --argjson domains "${domains:-[]}" '{
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false,
      autoAllowBashIfSandboxed: true,
      network: { allowedDomains: $domains }
    },
    permissions: { defaultMode: "acceptEdits" }
  }'
}
# Current settings with autonomous mode merged in; domains are added, never removed.
merged_claude_settings() {
  local current="{}"
  [ -s "$CLAUDE_SETTINGS" ] && current="$(cat "$CLAUDE_SETTINGS")"
  printf '%s' "$current" | jq --argjson want "$(autonomous_settings)" '
    (.sandbox.network.allowedDomains // []) as $have
    | . * $want
    | .sandbox.network.allowedDomains = (($have + $want.sandbox.network.allowedDomains) | unique)
  '
}
check_autonomous() {
  [ -s "$CLAUDE_SETTINGS" ] || return 1
  [ "$(merged_claude_settings | jq -S .)" = "$(jq -S . "$CLAUDE_SETTINGS" 2>/dev/null)" ]
}
install_autonomous() {
  local tmp
  tmp="$(mktemp)"
  merged_claude_settings > "$tmp" || { rm -f "$tmp"; return 1; }
  mkdir -p "$CLAUDE_DIR"
  [ -f "$CLAUDE_SETTINGS" ] && cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"
  mv "$tmp" "$CLAUDE_SETTINGS"
}

check_bwrap_works() { bwrap --ro-bind / / true >/dev/null 2>&1; }
install_bwrap_works() {
  info "bubblewrap can't create a sandbox here. On Ubuntu 24.04+ AppArmor may block it;"
  info "see Troubleshooting at https://code.claude.com/docs/en/sandboxing"
  return 1
}

# ---------------------------------------------------------------- github

# Each machine gets its own SSH key on GitHub, so a lost machine is cut off by
# deleting one key. Any key that already works (ssh-agent, Keychain, a custom
# IdentityFile) is left alone.

check_gh() { have gh; }
install_gh() {
  case "$PLATFORM" in
    mac)
      if have brew; then brew install gh
      else info "install the GitHub CLI (https://cli.github.com), then rerun"; return 1; fi ;;
    *) apt_install gh ;;
  esac
}

check_gh_auth() { gh auth status -h github.com >/dev/null 2>&1; }
install_gh_auth() {
  need_tty || return 1
  info "if no browser opens, go to https://github.com/login/device on any device and enter the code"
  gh auth login -h github.com -p https -s admin:public_key -w
}

check_gh_protocol() { [ "$(gh config get -h github.com git_protocol 2>/dev/null)" = ssh ]; }
install_gh_protocol() { gh config set -h github.com git_protocol ssh; }

# The first default key ssh offers, if any.
github_pubkey() {
  local k
  for k in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$k.pub" ] && { echo "$HOME/.ssh/$k.pub"; return 0; }
  done
  return 1
}
github_has_key() {
  local key
  key="$(cut -d' ' -f1,2 "$1")"
  gh api user/keys --jq '.[].key' 2>/dev/null | grep -xF "$key" >/dev/null
}

# ssh -T to GitHub always exits 1, so look at the greeting instead.
check_github_ssh() {
  local out
  out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com </dev/null 2>&1)"
  case "$out" in *"successfully authenticated"*) return 0 ;; esac
  return 1
}
install_github_ssh() {
  have gh && check_gh_auth || { info "needs gh logged in to GitHub first"; return 1; }
  local pub
  if ! pub="$(github_pubkey)"; then
    pub="$HOME/.ssh/id_ed25519.pub"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N "" -C "agent-box $(hostname)" -f "${pub%.pub}" || return 1
  fi
  if ! gh api user/keys >/dev/null 2>&1; then
    need_tty || return 1
    info "gh needs permission to add SSH keys to your account"
    info "if no browser opens, go to https://github.com/login/device on any device and enter the code"
    gh auth refresh -h github.com -s admin:public_key || return 1
  fi
  if ! github_has_key "$pub"; then
    gh ssh-key add "$pub" --title "agent-box $(hostname)" || return 1
  fi
  ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
    git@github.com </dev/null >/dev/null 2>&1
  check_github_ssh || info "$pub is on GitHub but ssh can't use it; if it has a passphrase, ssh-add it"
  return 0
}

check_git_identity() { [ -n "$(git config --global user.name)" ] && [ -n "$(git config --global user.email)" ]; }
install_git_identity() {
  have gh && check_gh_auth || { info "set git config --global user.name / user.email"; return 1; }
  local user name login id
  user="$(gh api user)" || return 1
  name="$(printf '%s' "$user" | jq -r '.name // .login')"
  login="$(printf '%s' "$user" | jq -r .login)"
  id="$(printf '%s' "$user" | jq -r .id)"
  [ -n "$(git config --global user.name)" ] || git config --global user.name "$name"
  [ -n "$(git config --global user.email)" ] \
    || git config --global user.email "$id+$login@users.noreply.github.com"
}

check_agent_box_cmd() { [ "$(readlink "$BIN_DIR/agent-box" 2>/dev/null)" = "$SCRIPT" ]; }
install_agent_box_cmd() { mkdir -p "$BIN_DIR" && ln -sfn "$SCRIPT" "$BIN_DIR/agent-box"; }

config_body() {
  printf 'AGENT_ROLE=%s\n' "$ROLE"
  if [ "$ROLE" = host ]; then printf 'AGENT_HOST=%s\n' "$AGENT_HOST"
  else printf 'AGENT_HOSTS=%s\n' "$AGENT_HOSTS"; fi
  printf 'PASS_VAULT=%s\nAGENT_AUTONOMOUS=%s\n' "$PASS_VAULT" "$AUTONOMOUS"
}
check_config_saved() { [ -f "$CONFIG_FILE" ] && config_body | cmp -s - "$CONFIG_FILE"; }
install_config_saved() { mkdir -p "$(dirname "$CONFIG_FILE")" && config_body > "$CONFIG_FILE"; }

# ---------------------------------------------------------------- shutdown

# `agent-box off`: shuts a host down. A WSL host can't power off Windows itself,
# so it leaves a flag that the Windows task "agent-box remote shutdown" polls every
# minute. Other Linux hosts power off directly, which needs passwordless sudo.
OFF_SCRIPT='if grep -qi microsoft /proc/version; then
  mkdir -p ~/.agent-box && touch ~/.agent-box/shutdown && echo "Windows turns off within about 2 minutes."
else
  sudo -n systemctl poweroff && echo "Powering off."
fi'
request_shutdown() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    if [ "$ROLE" = host ]; then target="$AGENT_HOST"; else target="$(host_names | head -n 1)"; fi
  fi
  echo "Shutting down $target."
  if [ "$ROLE" = host ] && [ "$target" = "$AGENT_HOST" ]; then
    sh -c "$OFF_SCRIPT" || exit 1
  else
    ssh -o ConnectTimeout=10 "$target" "$OFF_SCRIPT" || die "couldn't shut down $target"
  fi
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

# The name this machine already has on the tailnet, if it's logged in.
current_ts_name() {
  have tailscale || return 0
  local n
  n="$(ts_prefs | jq -r '.Hostname // empty' 2>/dev/null)"
  [ -n "$n" ] || n="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | cut -d. -f1)"
  echo "$n"
}

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

# A client lists its hosts in AGENT_HOSTS as space-separated [user@]name entries.
host_name() { echo "${1#*@}"; }
host_user() { case "$1" in *@*) echo "${1%@*}" ;; esac; }
host_names() { local h; for h in $AGENT_HOSTS; do host_name "$h"; done; }

# The Mac App Store build of Tailscale has no CLI on PATH.
ts() {
  if have tailscale; then tailscale "$@"
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    /Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"
  else return 1; fi
}

# with_timeout <seconds> <cmd...>: a Tailscale SSH "check" rule would otherwise
# wait for a browser login forever.
with_timeout() {
  local secs="$1" pid watcher rc
  shift
  "$@" & pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null
  return $rc
}

# Online Linux peers with Tailscale SSH on: possible hosts.
tailnet_ssh_peers() {
  ts status --json 2>/dev/null | jq -r '
    .Peer[]? | select(.OS == "linux" and .Online and ((.sshHostKeys // []) | length > 0))
    | .DNSName | split(".")[0]'
}
# Users worth trying on a new host: those of known hosts and ~/.ssh/config, then ours.
candidate_users() {
  {
    for h in $AGENT_HOSTS; do host_user "$h"; done
    awk 'tolower($1) == "user" { print $2 }' "$SSH_CONFIG" 2>/dev/null
    echo "$USER"
  } | awk 'NF && !seen[$0]++'
}
# probe_host <name>: prints user@name if a candidate user can log in and the
# machine has agent-box installed.
probe_host() {
  local u rc
  for u in $(candidate_users); do
    with_timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "$u@$1" 'test -e ~/.local/bin/agent-box' </dev/null >/dev/null 2>&1
    rc=$?
    [ "$rc" = 0 ] && { echo "$u@$1"; return 0; }
    [ "$rc" = 255 ] || return 1
  done
  return 1
}
# Prints user@name for agent-box hosts on the tailnet that aren't in AGENT_HOSTS yet.
discover_hosts() {
  local n known
  known=" $(host_names | tr '\n' ' ') "
  for n in $(tailnet_ssh_peers); do
    case "$known" in *" $n "*) continue ;; esac
    probe_host "$n"
  done
}

ssh_block() {
  local h n sep=""
  for h in $AGENT_HOSTS; do
    n="$(host_name "$h")"
    printf '%sHost %s\n    HostName %s\n    User %s' "$sep" "$n" "$n" "$(host_user "$h")"
    sep=$'\n\n'
  done
}
hosts_without_user() { local h; for h in $AGENT_HOSTS; do [ -n "$(host_user "$h")" ] || echo "$h"; done; }
check_ssh_config() { [ -z "$(hosts_without_user)" ] && block_matches "$SSH_CONFIG" "$(ssh_block)"; }
install_ssh_config() {
  local h u list=""
  for h in $AGENT_HOSTS; do
    if [ -z "$(host_user "$h")" ]; then
      need_tty || { info "give the user as --host <user>@$h"; return 1; }
      printf '    Linux user on %s: ' "$h"
      read -r u
      [ -n "$u" ] || return 1
      h="$u@$h"
    fi
    list="${list:+$list }$h"
  done
  AGENT_HOSTS="$list"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  replace_block "$SSH_CONFIG" "$(ssh_block)"
  chmod 600 "$SSH_CONFIG"
}

# The per-host steps below act on CUR_HOST.
check_ssh_reachable() {
  with_timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 "$CUR_HOST" true </dev/null >/dev/null 2>&1
}
install_ssh_reachable() {
  local out
  out="$(with_timeout 20 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$CUR_HOST" true </dev/null 2>&1)" \
    && return 0
  case "$out" in
    *"additional check"*)
      info "Tailscale SSH asks for a browser check on every login, which herdr can't do."
      info "At https://login.tailscale.com/admin/acls change the \"ssh\" rule's \"action\" from"
      info "\"check\" to \"accept\" and save. This is once for all your machines." ;;
    *) info "is $CUR_HOST turned on and online in Tailscale?" ;;
  esac
  return 1
}

check_herdr_machine() {
  herdr machine list --json 2>/dev/null \
    | jq -e --arg l "$CUR_HOST" '[.. | objects | .label? // empty] | index($l) != null' >/dev/null
}
install_herdr_machine() {
  need_tty || return 1
  herdr machine add "$CUR_HOST" --label "$CUR_HOST"
}

# ---------------------------------------------------------------- add

# `agent-box add`: copies this repo to a Linux machine over plain SSH (password
# is fine, asked once), runs the host install there, then adds it to this
# client's hosts. Afterwards the machine is reached over Tailscale by name.
add_host() {
  local addr="$1" name="$2" base remote_user remote_name entry h hosts=""
  [ "$ROLE" = client ] || die "run 'agent-box add' from a client"
  [ -n "$addr" ] || die "usage: agent-box add [user@]address [--host name]"
  need_tty || exit 1
  base="$(basename "$REPO_DIR")"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  set -- -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/agent-box-%C" -o ControlPersist=600 \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10

  read -r remote_user remote_name <<<"$(ssh "$@" "$addr" 'echo "$(whoami) $(hostname -s)"')"
  [ -n "$remote_user" ] || die "couldn't reach $addr over SSH"
  name="${name:-$remote_name}"
  [ "$(ssh "$@" "$addr" uname -s)" = Linux ] || die "$addr isn't Linux"

  echo "Copying $base to $addr:~/$base"
  if [ "$PLATFORM" = mac ]; then
    COPYFILE_DISABLE=1 tar --no-mac-metadata -C "$(dirname "$REPO_DIR")" -czf - "$base"
  else
    tar -C "$(dirname "$REPO_DIR")" -czf - "$base"
  fi | ssh "$@" "$addr" "tar -xzf - -C ~ 2>/dev/null; test -d ~/$base/.git" \
    || die "copying to $addr failed"

  echo "Setting up $addr as host '$name'"
  ssh -t "$@" "$addr" "~/$base/setup.sh install --role host --host $name" \
    || echo "Some host steps didn't finish; rerun 'agent-box install' on $name later."
  ssh "$@" -O exit "$addr" 2>/dev/null

  entry="$remote_user@$name"
  for h in $AGENT_HOSTS; do
    [ "$(host_name "$h")" = "$name" ] || hosts="${hosts:+$hosts }$h"
  done
  hosts="${hosts:+$hosts }$entry"
  echo "Connecting this machine to $name"
  exec "$SCRIPT" install --host "$(printf '%s' "$hosts" | tr ' ' ',')"
}

# ---------------------------------------------------------------- main

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SCRIPT"; }

OFF_TARGET="" HOST_ARG="" ADD_TARGET="" ADD_NAME=""
ORIG_ARGS=()
for _a in "$@"; do [ "$_a" = sync ] || ORIG_ARGS+=("$_a"); done
while [ $# -gt 0 ]; do
  case "$1" in
    check|install|sync) MODE="$1" ;;
    add) MODE=add; case "${2:-}" in ""|-*) ;; *) ADD_TARGET="$2"; shift ;; esac ;;
    off) MODE=off; case "${2:-}" in ""|-*) ;; *) OFF_TARGET="$2"; shift ;; esac ;;
    _shutdown-pending) shutdown_pending; exit $? ;;
    --role) ROLE="${2:-}"; shift ;;
    --host) HOST_ARG="${2:-}"; shift ;;
    --user) AGENT_USER="${2:-}"; shift ;;
    --vault) PASS_VAULT="${2:-}"; shift ;;
    --autonomous) AUTONOMOUS="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[ "$PLATFORM" != unknown ] || die "unsupported OS: $(uname -s)"
if [ -z "$ROLE" ]; then
  if [ "$PLATFORM" = mac ]; then ROLE=client; else ROLE=host; fi
fi
# For add, --host names the new host instead of replacing the host list.
if [ "$MODE" = add ]; then ADD_NAME="$HOST_ARG"; HOST_ARG=""; fi
if [ "$ROLE" = host ]; then
  [ -n "$HOST_ARG" ] && AGENT_HOST="$(host_name "$HOST_ARG")"
  [ -n "$AGENT_HOST" ] || AGENT_HOST="$(current_ts_name)"
  if [ -z "$AGENT_HOST" ]; then
    _default="$(hostname -s | tr '[:upper:]' '[:lower:]')"
    case "$MODE" in install|sync)
      if [ -t 0 ]; then
        printf 'Name for this machine (your other machines reach it by this name) [%s]: ' "$_default"
        read -r AGENT_HOST
      fi ;;
    esac
    AGENT_HOST="${AGENT_HOST:-$_default}"
  fi
else
  [ -n "$HOST_ARG" ] && AGENT_HOSTS="$(printf '%s' "$HOST_ARG" | tr ',' ' ')"
  # Older configs saved a single AGENT_HOST and AGENT_USER.
  [ -n "$AGENT_HOSTS" ] || AGENT_HOSTS="$AGENT_HOST"
  if [ -n "$AGENT_USER" ]; then
    _hosts=""
    for _h in $AGENT_HOSTS; do
      [ -n "$(host_user "$_h")" ] || _h="$AGENT_USER@$_h"
      _hosts="${_hosts:+$_hosts }$_h"
    done
    AGENT_HOSTS="$_hosts"
  fi
fi
PASS_VAULT="${PASS_VAULT:-Agents}"
AUTONOMOUS="${AUTONOMOUS:-off}"
case "$ROLE" in host|client) ;; *) die "--role must be host or client" ;; esac
case "$AUTONOMOUS" in on|off) ;; *) die "--autonomous must be on or off" ;; esac
[ "$ROLE" = host ] && [ "$PLATFORM" = mac ] && die "macOS is supported as a client only"
case "$ROLE:$(uname -m)" in
  host:armv6l|host:armv7l) die "hosts need a 64-bit OS (Claude Code and herdr have no 32-bit ARM builds)" ;;
esac

if [ "$MODE" = add ]; then
  add_host "$ADD_TARGET" "$ADD_NAME"
fi
if [ "$MODE" = off ]; then
  request_shutdown "$OFF_TARGET"
  exit 0
fi
if [ "$MODE" = sync ]; then
  git -C "$REPO_DIR" pull --ff-only || die "git pull failed in $REPO_DIR"
  # Bash has already read part of the old script, so run the updated one.
  exec "$SCRIPT" install "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
fi

printf 'agent-box · %s · role: %s · autonomous: %s · mode: %s\n' "$PLATFORM" "$ROLE" "$AUTONOMOUS" "$MODE"

section "Base"
step "home folder files owned by you"     check_home_owned          install_home_owned
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
if [ "$PLATFORM" != mac ] && { [ "$ROLE" = host ] || [ "$AUTONOMOUS" = on ]; }; then
  step "Claude sandbox deps (bubblewrap, socat)" check_sandbox_deps install_sandbox_deps
  have bwrap && step "bubblewrap can create sandboxes" check_bwrap_works install_bwrap_works
fi
if [ "$AUTONOMOUS" = on ]; then
  step "Claude autonomous mode (sandboxed, no prompts)" check_autonomous install_autonomous
fi
if [ "$ROLE" = host ]; then
  step "herdr panes use login shells"     check_herdr_shell_mode    install_herdr_shell_mode
  if [ "$SYSTEMD" = 1 ]; then
    step "herdr server starts at boot"    check_herdr_service       install_herdr_service
    step "user services run without login (linger)" check_linger   install_linger
  fi
fi

section "GitHub"
step "GitHub CLI (gh)"                    check_gh                  install_gh
if have gh; then
  step "gh logged in to GitHub"           check_gh_auth             install_gh_auth
  step "gh uses SSH for git"              check_gh_protocol         install_gh_protocol
fi
step "git over SSH to GitHub"             check_github_ssh          install_github_ssh
step "git name and email"                 check_git_identity        install_git_identity

section "Secrets (Proton Pass)"
step "pass-cli"                           check_pass_cli            install_pass_cli
step "agent token stored (pst_…::…)"     check_token               install_token
step "pp wrapper"                         check_pp                  install_pp
step "CLAUDE.md agent-box section"        check_claude_md           install_claude_md
if have pass-cli && check_token && check_pp; then
  step "pp can log in"                    check_pp_works            check_pp_works
fi

if [ "$ROLE" = client ]; then
  section "Hosts"
  if [ -z "$HOST_ARG" ]; then
    for _h in $(discover_hosts); do
      info "found $_h on Tailscale"
      AGENT_HOSTS="${AGENT_HOSTS:+$AGENT_HOSTS }$_h"
    done
  fi
  if [ -z "$AGENT_HOSTS" ]; then
    info "no hosts yet: set one up (the one-line install on it), then rerun here"
  else
    step "SSH config for $(host_names | paste -sd, - | sed 's/,/, /g')" check_ssh_config install_ssh_config
  fi
  if [ -n "$AGENT_HOSTS" ] && check_ssh_config; then
    for CUR_HOST in $(host_names); do
      step "$CUR_HOST reachable over SSH"    check_ssh_reachable       install_ssh_reachable
      if have herdr && check_ssh_reachable; then
        step "herdr machine '$CUR_HOST' saved" check_herdr_machine     install_herdr_machine
      fi
    done
  fi
fi

section "Settings"
step "saved to ~/.config/agent-box/config" check_config_saved       install_config_saved

if [ "$ROLE" = client ]; then
  note "Keep Tailscale connected on this machine (it is the only login to your hosts)."
fi
if [ "$ROLE" = host ]; then
  note "Tailscale admin console: disable key expiry for '$AGENT_HOST'."
  note "Tailscale admin console → Access controls: SSH rule action \"accept\" (see README)."
  note "Log in to Claude once on this machine: run 'claude'."
fi

printf '\n%d ok · %d installed · %d missing · %d failed\n' "$N_OK" "$N_FIXED" "$N_MISSING" "$N_FAILED"
if [ -n "$NOTES" ]; then printf '\nManual steps:\n%s' "$NOTES"; fi
if [ "$MODE" = check ] && [ "$N_MISSING" -gt 0 ]; then
  printf '\nRun %sagent-box install%s (or ./setup.sh install) to fix missing items.\n' "$C_WARN" "$C_OFF"
fi

[ "$N_MISSING" -eq 0 ] && [ "$N_FAILED" -eq 0 ]
