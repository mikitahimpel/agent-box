#!/usr/bin/env bash
# Checks and installs the agent-box setup on macOS, Linux and WSL.
#
#   agent-box               check only, change nothing (same as ./setup.sh)
#   agent-box install       install or fix everything that is missing
#   agent-box sync          git pull this repo, then install
#   agent-box off [host]    shut a host down (default: this host, or the first on a client)
#   agent-box restart [host]  restart a host (same default)
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
#   --token-vaults A,B,...  vaults to pick for this machine's Proton Pass token
#                           (default: described by role when the token is asked)
#   --autonomous on|off     Claude works without prompts inside its sandbox (default: off)
#
# A "host" runs agents, a "client" is where you work from. The environment
# variables AGENT_ROLE, AGENT_HOST, AGENT_HOSTS, AGENT_USER, PASS_VAULT,
# PASS_TOKEN_VAULTS and AGENT_AUTONOMOUS work too.
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
AGENT_WIN_HOSTS="${AGENT_WIN_HOSTS:-$(config_get AGENT_WIN_HOSTS)}"
AGENT_USER="${AGENT_USER:-$(config_get AGENT_USER)}"
PASS_VAULT="${PASS_VAULT:-$(config_get PASS_VAULT)}"
PASS_TOKEN_VAULTS="${PASS_TOKEN_VAULTS:-$(config_get PASS_TOKEN_VAULTS)}"
AUTONOMOUS="${AGENT_AUTONOMOUS:-$(config_get AGENT_AUTONOMOUS)}"

# One Proton Pass token per machine, shared with project tools: Keychain on macOS,
# libsecret on Linux when secret-tool works, else TOKEN_FILE. pass-cli keeps its
# session in its default directory.
TOKEN_SERVICE="proton-pass-token"
TOKEN_ACCOUNT="default"
TOKEN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/proton-pass/token"
# Where agent-box kept its own token and session before.
OLD_TOKEN_SERVICE="proton-pass-agent"
OLD_TOKEN_FILE="$HOME/.config/pass-agent/token"
OLD_SESSION_DIR="$HOME/.local/state/pass-agent"
BIN_DIR="$HOME/.local/bin"
# What the old herdr TUI left on a host; hosts now run herdr-core (hc) instead.
OLD_HERDR_DIR="$HOME/.config/herdr"
OLD_HERDR_UNIT="$HOME/.config/systemd/user/herdr.service"
OLD_HERDR_HOOK="$HOME/.claude/hooks/herdr-agent-state.sh"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
SHARED_CLAUDE="$REPO_DIR/claude"
SHUTDOWN_FLAG="$HOME/.agent-box/shutdown"
RESTART_FLAG="$HOME/.agent-box/restart"
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
# Match login shells and pp even before the login profile has been written.
[ "$PLATFORM" = mac ] || export PROTON_PASS_KEY_PROVIDER="${PROTON_PASS_KEY_PROVIDER:-fs}"

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

login_rc() {
  case "${SHELL:-}" in
    */zsh) echo "$HOME/.zprofile" ;;
    *) echo "$HOME/.profile" ;;
  esac
}
# On Linux pass-cli keeps its local key in the kernel keyring by default, which
# is per login session: hc terminals and SSH logins would each get a different
# key for the one shared session and fail with "file is not a database".
login_shell_block() {
  echo 'export PATH="$HOME/.local/bin:$PATH"'
  if [ "$PLATFORM" != mac ]; then
    echo 'export PROTON_PASS_KEY_PROVIDER="${PROTON_PASS_KEY_PROVIDER:-fs}"'
  fi
}
check_path_in_login_shell() {
  local shell="${SHELL:-/bin/bash}"
  block_matches "$(login_rc)" "$(login_shell_block)" \
    && "$shell" -lc 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0 ;; *) exit 1 ;; esac' </dev/null >/dev/null 2>&1
}
install_path_in_login_shell() { replace_block "$(login_rc)" "$(login_shell_block)"; }

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

# hc starts programs on a Linux host with the login shell's environment, so
# claude must be on that PATH, not only on an interactive shell's.
check_claude_login_path() {
  "${SHELL:-/bin/bash}" -lc 'command -v claude' </dev/null >/dev/null 2>&1
}
install_claude_login_path() {
  info "claude isn't on the PATH of '${SHELL:-/bin/bash} -l'; it should be in ~/.local/bin"
  [ -f "$HOME/.bash_profile" ] && [ "$(login_rc)" = "$HOME/.profile" ] \
    && info "bash reads ~/.bash_profile instead of ~/.profile; source ~/.profile from it"
  return 1
}

# hc (herdr-core) on a host is installed by the client: agent-box there runs
# 'hc machine add --install', as does adding the machine in the Herdr app.
hc_installed() { have herdr-core || [ -x "$BIN_DIR/herdr-core" ]; }

check_pass_cli() { have pass-cli; }
install_pass_cli() { curl -fsSL https://proton.me/download/pass-cli/install.sh | bash; }

# Agent tokens look like pst_<token>::<key>.
valid_token() {
  case "$1" in *[[:space:]]*|pst_*pst_*) return 1 ;; pst_?*::?*) return 0 ;; *) return 1 ;; esac
}
stored_token() {
  if [ "$PLATFORM" = mac ]; then
    security find-generic-password -s "$TOKEN_SERVICE" -a "$TOKEN_ACCOUNT" -w 2>/dev/null
  else
    have secret-tool && secret-tool lookup service "$TOKEN_SERVICE" account "$TOKEN_ACCOUNT" 2>/dev/null && return 0
    cat "$TOKEN_FILE" 2>/dev/null
  fi
}
save_token() {
  if [ "$PLATFORM" = mac ]; then
    security add-generic-password -U -a "$TOKEN_ACCOUNT" -s "$TOKEN_SERVICE" -l "Proton Pass token" -w "$1" || return 1
  elif have secret-tool && printf '%s' "$1" \
      | secret-tool store --label "Proton Pass token" service "$TOKEN_SERVICE" account "$TOKEN_ACCOUNT" 2>/dev/null; then
    rm -f "$TOKEN_FILE"
  else
    mkdir -p "$(dirname "$TOKEN_FILE")" && chmod 700 "$(dirname "$TOKEN_FILE")" || return 1
    ( umask 077; printf '%s' "$1" > "$TOKEN_FILE" ) && chmod 600 "$TOKEN_FILE" || return 1
  fi
  [ "$(stored_token)" = "$1" ]
}
check_token() { valid_token "$(stored_token)"; }

has_old_token() {
  if [ "$PLATFORM" = mac ]; then
    security find-generic-password -s "$OLD_TOKEN_SERVICE" >/dev/null 2>&1
  else
    [ -e "$OLD_TOKEN_FILE" ]
  fi
}
old_token() {
  if [ "$PLATFORM" = mac ]; then
    security find-generic-password -s "$OLD_TOKEN_SERVICE" -w 2>/dev/null
  else
    cat "$OLD_TOKEN_FILE" 2>/dev/null
  fi
}
remove_old_token() {
  local n
  if [ "$PLATFORM" = mac ]; then
    for n in 1 2 3; do security delete-generic-password -s "$OLD_TOKEN_SERVICE" >/dev/null 2>&1 || break; done
  else
    rm -f "$OLD_TOKEN_FILE"
    rmdir "$(dirname "$OLD_TOKEN_FILE")" 2>/dev/null
  fi
  ! has_old_token
}

# What to pick under "vaults" when creating this machine's token.
token_vaults() {
  if [ -n "$PASS_TOKEN_VAULTS" ]; then
    printf '%s\n' "$PASS_TOKEN_VAULTS" | sed 's/ *, */, /g'
  elif [ "$ROLE" = host ]; then
    echo "$PASS_VAULT and your project dev vaults (e.g. Memoxia); never release vaults"
  else
    echo "$PASS_VAULT and your project vaults, release vaults included (e.g. Memoxia, Memoxia Release)"
  fi
}

install_token() {
  local raw token try old
  # An earlier agent-box kept the token elsewhere; move it rather than ask again.
  old="$(old_token)"
  if valid_token "$old"; then
    info "moving the token from the old agent-box storage"
    save_token "$old" && remove_old_token || return 1
    info "it still sees only the vaults it was created for; to add vaults, replace it (README → Secrets)"
    return 0
  fi
  need_tty || return 1
  info "Create this machine's token at pass.proton.me → Settings → Access tokens → New token:"
  info "  name: $(hostname -s), expiry: 1 year, 'Use for AI agent' on"
  info "  vaults: $(token_vaults)"
  if [ "$ROLE" = host ]; then
    case "$(printf '%s' "$PASS_TOKEN_VAULTS" | tr '[:upper:]' '[:lower:]')" in
      *release*) info "  warning: --token-vaults names a release vault; hosts shouldn't get release vaults" ;;
    esac
  fi
  info "pp and project tools on this machine all use it. Paste it here."
  for try in 1 2 3; do
    printf '    token (hidden): '
    read -rs raw; echo
    # Terminals may wrap a paste in escape codes or add spaces; keep only the token.
    # A token pasted twice comes back joined; split at each pst_ and keep the first.
    token="$(printf '%s' "$raw" | LC_ALL=C tr -d '\000-\037\177' | sed 's/\[20[01]~//g' \
      | awk '{ gsub(/pst_/, "\npst_"); print }' | grep -o 'pst_[^[:space:]]*::[^[:space:]]*' | head -n 1)"
    valid_token "$token" && break
    info "Not accepted. Paste the whole token: it begins with pst_ and has :: in the middle."
    info "Got ${#raw} characters; pst_ $(case "$raw" in *pst_*) echo found ;; *) echo missing ;; esac), :: $(case "$raw" in *::*) echo found ;; *) echo missing ;; esac)."
    token=""
  done
  [ -n "$token" ] || return 1
  save_token "$token"
}

# Leftovers of the old storage: a token the new one replaced and pp's own session.
check_no_old_pass() { ! has_old_token && [ ! -e "$OLD_SESSION_DIR" ]; }
install_no_old_pass() {
  check_token || { info "store this machine's token first"; return 1; }
  remove_old_token && rm -rf "$OLD_SESSION_DIR"
}

pp_script() {
  cat <<EOF
#!/usr/bin/env bash
# pp: pass-cli that logs in with this machine's Proton Pass token when the session
# has expired. Uses pass-cli's default session, shared with project tools.
# Managed by agent-box; local edits are overwritten.
set -euo pipefail
export PATH="$BIN_DIR:\$PATH"
export PROTON_PASS_AGENT_REASON="\${PROTON_PASS_AGENT_REASON:-agent on \$(hostname)}"
# Same local key from every login session; see login_shell_block in agent-box.
[[ "\$(uname)" == Darwin ]] || export PROTON_PASS_KEY_PROVIDER="\${PROTON_PASS_KEY_PROVIDER:-fs}"

token() {
  if [[ "\$(uname)" == Darwin ]]; then
    security find-generic-password -s $TOKEN_SERVICE -a $TOKEN_ACCOUNT -w
  else
    if command -v secret-tool >/dev/null 2>&1 \\
      && secret-tool lookup service $TOKEN_SERVICE account $TOKEN_ACCOUNT 2>/dev/null; then
      return 0
    fi
    cat "\${XDG_CONFIG_HOME:-\$HOME/.config}/proton-pass/token"
  fi
}

if ! pass-cli info >/dev/null 2>&1; then
  PROTON_PASS_PERSONAL_ACCESS_TOKEN="\$(token)" pass-cli login >/dev/null
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
- This machine has one Proton Pass session and token, shared by pp and project tools.
  Don't set PROTON_PASS_SESSION_DIR, log in or out, or read the stored token.
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
# A session encrypted with a key from the old provider can't be opened; reset the
# local state once and let pp log back in with the machine's token.
install_pp_works() {
  local err
  err="$(pass-cli info 2>&1 >/dev/null)" || true
  if [[ "$err" == *"file is not a database"* ]]; then
    info "pass-cli's local session uses another key; resetting it"
    pass-cli logout --force >/dev/null 2>&1
  fi
  check_pp_works
}

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

# Rex on the Mac: rex-agent and rex-task go to ~/.local/bin, and agents.lua
# is linked beside the user's init.lua, which loads it with require("agents").
REX_SUPPORT="$HOME/Library/Application Support/com.superlogical.rex"
REX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
REX_LINKS="bin/rex-agent:$BIN_DIR/rex-agent bin/rex-task:$BIN_DIR/rex-task config/agents.lua:$REX_CONFIG_DIR/agents.lua"
check_rex_agents() {
  local pair
  for pair in $REX_LINKS; do
    [ "$(readlink "${pair#*:}" 2>/dev/null)" = "$REPO_DIR/rex/${pair%%:*}" ] || return 1
  done
  grep -q '^require("agents")' "$REX_CONFIG_DIR/init.lua" 2>/dev/null
}
install_rex_agents() {
  local pair
  for pair in $REX_LINKS; do
    mkdir -p "$(dirname "${pair#*:}")" && ln -sfn "$REPO_DIR/rex/${pair%%:*}" "${pair#*:}" || return 1
  done
  grep -q '^require("agents")' "$REX_CONFIG_DIR/init.lua" 2>/dev/null ||
    printf '%s\n' '-- Agent workflow from agent-box.' 'require("agents")' >> "$REX_CONFIG_DIR/init.lua"
  have rex && rex config reload >/dev/null 2>&1
  return 0
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
  [ "$ROLE" = host ] || [ -z "$AGENT_WIN_HOSTS" ] || printf 'AGENT_WIN_HOSTS=%s\n' "$AGENT_WIN_HOSTS"
  printf 'PASS_VAULT=%s\n' "$PASS_VAULT"
  [ -z "$PASS_TOKEN_VAULTS" ] || printf 'PASS_TOKEN_VAULTS=%s\n' "$PASS_TOKEN_VAULTS"
  printf 'AGENT_AUTONOMOUS=%s\n' "$AUTONOMOUS"
}
check_config_saved() { [ -f "$CONFIG_FILE" ] && config_body | cmp -s - "$CONFIG_FILE"; }
install_config_saved() { mkdir -p "$(dirname "$CONFIG_FILE")" && config_body > "$CONFIG_FILE"; }

# ---------------------------------------------------------------- shutdown

# `agent-box off` and `agent-box restart`. A WSL host can't power Windows off
# itself, so it leaves a flag (~/.agent-box/shutdown or ~/.agent-box/restart) that
# the Windows task "agent-box remote shutdown" polls every minute. Other Linux
# hosts power off or reboot directly, which needs passwordless sudo.
power_script() {  # off | restart
  local flag=shutdown unit=poweroff wsl_msg="Windows turns off" msg="Powering off."
  if [ "$1" = restart ]; then
    flag=restart unit=reboot wsl_msg="Windows restarts" msg="Restarting."
  fi
  cat <<EOF
if grep -qi microsoft /proc/version; then
  mkdir -p ~/.agent-box && touch ~/.agent-box/$flag && echo "$wsl_msg within about 2 minutes."
else
  sudo -n systemctl $unit && echo "$msg"
fi
EOF
}
request_power() {  # off | restart, [host]
  local action="$1" target="${2:-}" script
  if [ -z "$target" ]; then
    if [ "$ROLE" = host ]; then target="$AGENT_HOST"; else target="$(host_names | head -n 1)"; fi
  fi
  script="$(power_script "$action")"
  if [ "$action" = restart ]; then echo "Restarting $target."; else echo "Shutting down $target."; fi
  if [ "$ROLE" = host ] && [ "$target" = "$AGENT_HOST" ]; then
    sh -c "$script" || exit 1
  else
    ssh -o ConnectTimeout=10 "$target" "$script" || die "couldn't reach $target"
  fi
}

# Succeeds once for a request made in the last 5 minutes. Old requests are
# dropped, so a flag left over from before a reboot never acts again.
flag_pending() {
  [ -f "$1" ] || return 1
  local fresh
  fresh="$(find "$1" -mmin -5)"
  rm -f "$1"
  [ -n "$fresh" ]
}
shutdown_pending() { flag_pending "$SHUTDOWN_FLAG"; }
# Prints "restart" or "off". Windows tasks installed before restart existed
# call _shutdown-pending, so they never mistake a restart for a shutdown.
power_pending() {
  if flag_pending "$RESTART_FLAG"; then
    rm -f "$SHUTDOWN_FLAG"
    echo restart
  elif shutdown_pending; then
    echo off
  else
    return 1
  fi
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

# write_root_file <path> <content>, for files under /etc; file_is <path> <content>.
write_root_file() { sudo mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" | sudo tee "$1" >/dev/null; }
file_is() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }

# On WSL, tailscaled is the only way in from the tailnet, so it comes back after
# any exit, never gives up restarting, and is the last thing the kernel kills.
TAILSCALED_DROPIN=/etc/systemd/system/tailscaled.service.d/agent-box.conf
tailscaled_dropin() {
  cat <<'EOF'
# Managed by agent-box.
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=5
OOMScoreAdjust=-900
MemoryLow=256M
CPUWeight=500
IOWeight=500
EOF
}
check_tailscaled_restart() {
  file_is "$TAILSCALED_DROPIN" "$(tailscaled_dropin)" \
    && [ "$(systemctl show -p Restart --value tailscaled 2>/dev/null)" = always ]
}
install_tailscaled_restart() {
  write_root_file "$TAILSCALED_DROPIN" "$(tailscaled_dropin)" && sudo systemctl daemon-reload || return 1
  info "OOMScoreAdjust applies the next time tailscaled starts"
}

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

# The old herdr TUI: its integration hook in Claude, its server unit, its binary
# and its config. hc and its own folders (herdr-core) are left alone.
old_herdr_hook_in_settings() {
  [ -s "$CLAUDE_SETTINGS" ] && grep -q 'herdr-agent-state' "$CLAUDE_SETTINGS"
}
check_no_herdr_tui() {
  ! have herdr && [ ! -e "$OLD_HERDR_UNIT" ] && [ ! -e "$OLD_HERDR_DIR" ] \
    && [ ! -e "$OLD_HERDR_HOOK" ] && ! old_herdr_hook_in_settings
}
install_no_herdr_tui() {
  local bin tmp
  have herdr && herdr integration uninstall claude >/dev/null 2>&1
  if old_herdr_hook_in_settings; then
    tmp="$(mktemp)"
    jq '
      if .hooks then
        .hooks |= (map_values(
          map(.hooks |= map(select((.command // "") | contains("herdr-agent-state") | not)))
          | map(select((.hooks // []) | length > 0))
        ) | with_entries(select(.value | length > 0)))
      else . end
    ' "$CLAUDE_SETTINGS" > "$tmp" || { rm -f "$tmp"; return 1; }
    cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak" && mv "$tmp" "$CLAUDE_SETTINGS" || return 1
  fi
  rm -f "$OLD_HERDR_HOOK"
  if [ -e "$OLD_HERDR_UNIT" ] || systemctl --user cat herdr.service >/dev/null 2>&1; then
    systemctl --user disable --now herdr.service >/dev/null 2>&1
    rm -f "$OLD_HERDR_UNIT"
    systemctl --user daemon-reload
    systemctl --user reset-failed herdr.service >/dev/null 2>&1
  fi
  if have herdr; then
    bin="$(command -v herdr)"
    case "$bin" in
      "$HOME"/*) rm -f "$bin" ;;
      *) info "remove $bin yourself (it isn't in your home folder)"; return 1 ;;
    esac
  fi
  rm -rf "$OLD_HERDR_DIR"
}

check_linger() { loginctl show-user "$USER" -p Linger 2>/dev/null | grep 'Linger=yes' >/dev/null; }
install_linger() { sudo loginctl enable-linger "$USER"; }

# On Linux hc runs its core, and the holders that keep each terminal, as
# transient services of the user's systemd manager (systemd-run --user), so
# agents and their builds all run under user@<uid>.service. Capping that unit
# covers them whatever hc names its units. SSH logins (session scopes) and CI
# runners (system services) are outside it.
USER_UNIT="user@$(id -u).service"
USER_MEMORY_DROPIN="/etc/systemd/system/$USER_UNIT.d/agent-box-memory.conf"
user_memory_dropin() {
  cat <<'EOF'
# Managed by agent-box. Agents and their builds share the machine with other
# services (CI runners); throttle them before the whole host runs out of memory
# and stops answering.
[Service]
MemoryHigh=60%
MemoryMax=70%
EOF
}
check_user_memory_cap() {
  file_is "$USER_MEMORY_DROPIN" "$(user_memory_dropin)" \
    && [ "$(systemctl show -p MemoryMax --value "$USER_UNIT" 2>/dev/null)" != infinity ]
}
install_user_memory_cap() {
  write_root_file "$USER_MEMORY_DROPIN" "$(user_memory_dropin)" && sudo systemctl daemon-reload || return 1
  # The running user manager gets the limits now instead of at its next start.
  sudo systemctl set-property --runtime "$USER_UNIT" MemoryHigh=60% MemoryMax=70%
}

# Memory the kernel reclaims last: tailscaled (the only way in) and everything under
# user.slice (hc and the agents in its terminals). MemoryLow only counts if every
# ancestor claims it too, and hc's units are transient, so the cgroup2 mount gets
# memory_recursiveprot: a slice's protection is then shared out to its children by
# use. Docker containers and CI runners claim none and are reclaimed (and swapped)
# first.
RECURSIVEPROT_UNIT=/etc/systemd/system/agent-box-memory-protection.service
SYSTEM_SLICE_DROPIN=/etc/systemd/system/system.slice.d/agent-box.conf
USER_SLICE_DROPIN=/etc/systemd/system/user.slice.d/agent-box.conf
recursiveprot_unit() {
  cat <<'EOF'
# Managed by agent-box. Lets the memory protection of a slice reach the units in it.
[Unit]
Description=Memory protection reaches nested cgroups (agent-box)
DefaultDependencies=no
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount -o remount,nsdelegate,memory_recursiveprot /sys/fs/cgroup

[Install]
WantedBy=sysinit.target
EOF
}
system_slice_dropin() { printf '# Managed by agent-box. Room for tailscaled.\n[Slice]\nMemoryLow=256M\n'; }
user_slice_dropin() { printf '# Managed by agent-box. Room for hc and the agents in its terminals.\n[Slice]\nMemoryLow=20%%\n'; }
has_recursiveprot() { awk '$3 == "cgroup2" && $4 ~ /memory_recursiveprot/' /proc/mounts | grep -q .; }
check_memory_reserve() {
  file_is "$RECURSIVEPROT_UNIT" "$(recursiveprot_unit)" \
    && file_is "$SYSTEM_SLICE_DROPIN" "$(system_slice_dropin)" \
    && file_is "$USER_SLICE_DROPIN" "$(user_slice_dropin)" \
    && systemctl is-enabled agent-box-memory-protection.service >/dev/null 2>&1 \
    && has_recursiveprot \
    && [ "$(systemctl show -p MemoryLow --value user.slice 2>/dev/null)" != 0 ]
}
install_memory_reserve() {
  write_root_file "$RECURSIVEPROT_UNIT" "$(recursiveprot_unit)" \
    && write_root_file "$SYSTEM_SLICE_DROPIN" "$(system_slice_dropin)" \
    && write_root_file "$USER_SLICE_DROPIN" "$(user_slice_dropin)" \
    && sudo systemctl daemon-reload \
    && sudo systemctl enable agent-box-memory-protection.service || return 1
  sudo systemctl restart agent-box-memory-protection.service \
    || { info "this kernel can't remount cgroup2 with memory_recursiveprot"; return 1; }
}

# ---------------------------------------------------------------- memory

# earlyoom acts before the kernel's OOM killer would stall the machine: it kills
# one build or test process (node, vitest, workerd, a CI job) and leaves
# tailscaled, sshd, hc (herdr-core: its core and the holders that keep each
# terminal) and systemd alone. The names are matched against the
# process name; quotes would reach earlyoom literally, so the regexes have none.
EARLYOOM_DEFAULTS=/etc/default/earlyoom
earlyoom_defaults() {
  cat <<'EOF'
# Managed by agent-box. When memory runs low, kill one build or test process,
# not the whole machine.
EARLYOOM_ARGS="-r 3600 --prefer ^(node|vitest|jest|workerd|python|Runner.Worker) --avoid ^(tailscaled|sshd|herdr-core|hc|systemd|init|earlyoom)"
EOF
}
check_earlyoom() {
  have earlyoom && file_is "$EARLYOOM_DEFAULTS" "$(earlyoom_defaults)" \
    && systemctl is-enabled earlyoom >/dev/null 2>&1 && systemctl is-active earlyoom >/dev/null 2>&1
}
install_earlyoom() {
  have earlyoom || apt_install earlyoom || return 1
  write_root_file "$EARLYOOM_DEFAULTS" "$(earlyoom_defaults)" \
    && sudo systemctl enable earlyoom && sudo systemctl restart earlyoom
}

# Self-hosted GitHub runners (set up outside agent-box) run in their own slice
# with less memory and CPU than agents, so a burst of CI jobs can't take the
# host down. Runners are only capped, never created or removed.
RUNNER_SLICE=agent-box-runners.slice
runner_slice() {
  cat <<'EOF'
# Managed by agent-box. CI runners get less memory and CPU than agents, and
# little swap: a job that needs more fails instead of slowing the whole host.
[Unit]
Description=CI runners (agent-box)

[Slice]
MemoryHigh=45%
MemoryMax=50%
MemorySwapMax=1G
CPUWeight=20
IOWeight=20
EOF
}
runner_dropin() { printf '# Managed by agent-box.\n[Service]\nSlice=%s\n' "$RUNNER_SLICE"; }
runner_dropin_path() { echo "/etc/systemd/system/$1.d/agent-box-slice.conf"; }
# Unit files, templates included (a drop-in for gh-runner@.service covers every instance).
runner_units() {
  systemctl list-unit-files --type=service --no-legend 'gh-runner*' 'actions.runner*' 2>/dev/null | awk '{ print $1 }'
}
active_runners() {
  systemctl list-units --type=service --state=active --no-legend --plain 'gh-runner*' 'actions.runner*' 2>/dev/null \
    | awk '{ print $1 }'
}
runners_outside_slice() {
  local u
  for u in $(active_runners); do
    [ "$(systemctl show -p Slice --value "$u" 2>/dev/null)" = "$RUNNER_SLICE" ] || echo "$u"
  done
}
check_runner_caps() {
  local u
  file_is "/etc/systemd/system/$RUNNER_SLICE" "$(runner_slice)" || return 1
  for u in $(runner_units); do
    file_is "$(runner_dropin_path "$u")" "$(runner_dropin)" || return 1
  done
  [ -z "$(runners_outside_slice)" ]
}
install_runner_caps() {
  local u stale
  write_root_file "/etc/systemd/system/$RUNNER_SLICE" "$(runner_slice)" || return 1
  for u in $(runner_units); do
    write_root_file "$(runner_dropin_path "$u")" "$(runner_dropin)" || return 1
  done
  sudo systemctl daemon-reload || return 1
  stale="$(runners_outside_slice | tr '\n' ' ')"
  [ -n "$stale" ] || return 0
  # Moving a service to another slice needs a restart, which would kill a running job.
  if pgrep -f 'Runner[.]Worker' >/dev/null; then
    info "a CI job is running; rerun once it's done (or reboot) to restart: $stale"
    return 1
  fi
  # shellcheck disable=SC2086  # one argument per unit
  sudo systemctl restart $stale
}

# `agent-box _busy`, asked by the Windows idle-sleep task every 10 minutes: prints
# what keeps the host busy and succeeds, or fails when nothing does. Claude's CPU
# time (its own plus its finished children's) is compared with the previous call,
# so an agent waiting at its prompt doesn't count as working.
BUSY_STATE="$HOME/.agent-box/claude-cpu"
BUSY_LOAD=1.0          # 5-minute load average that counts as heavy work
BUSY_CLAUDE_SECONDS=5  # Claude CPU seconds since the last call that count as working
claude_cpu() {  # "pid ticks" per claude process
  local p
  for p in $(pgrep -x claude); do
    awk -v p="$p" '{ print p, $14 + $15 + $16 + $17 }' "/proc/$p/stat" 2>/dev/null
  done
}
host_busy() {
  local load now secs
  if pgrep -f 'Runner[.]Worker' >/dev/null; then echo "CI job running"; return 0; fi
  load="$(cut -d' ' -f2 /proc/loadavg)"
  if awk -v l="$load" -v m="$BUSY_LOAD" 'BEGIN { exit !(l >= m) }'; then
    echo "load average $load"
    return 0
  fi
  now="$(claude_cpu)"
  secs="$({ sed 's/^/old /' "$BUSY_STATE" 2>/dev/null; printf '%s\n' "$now" | sed 's/^/new /'; } \
    | awk -v hz="$(getconf CLK_TCK)" '
        $1 == "old" { was[$2] = $3 }
        $1 == "new" && NF == 3 { d += $3 - was[$2] }
        END { printf "%d", d / hz }')"
  mkdir -p "$(dirname "$BUSY_STATE")" && printf '%s\n' "$now" > "$BUSY_STATE"
  if [ "${secs:-0}" -ge "$BUSY_CLAUDE_SECONDS" ]; then
    echo "Claude working (${secs}s CPU since the last check)"
    return 0
  fi
  return 1
}

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
  { kill "$watcher"; wait "$watcher"; } 2>/dev/null
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
  } | awk 'NF && $0 != "root" && !seen[$0]++'
}
# probe_host <name>: prints user@name for the first candidate user that can log
# in and has agent-box installed.
probe_host() {
  local u
  for u in $(candidate_users); do
    if with_timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "$u@$1" 'test -e ~/.local/bin/agent-box' </dev/null >/dev/null 2>&1; then
      echo "$u@$1"
      return 0
    fi
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

# A WSL host's Windows side, '<host>-win' (windows/setup.ps1), is how you get in
# when WSL is down. Its user is the Windows one, which windows/setup.ps1 writes to
# ~/.config/agent-box/windows inside WSL. Saved as AGENT_WIN_HOSTS (user@name) so
# the SSH config keeps it while WSL is down.
win_entry_from_host() {
  with_timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" 'cat ~/.config/agent-box/windows 2>/dev/null' \
    </dev/null 2>/dev/null | tr -d '\r' \
    | awk -F= '$1 == "WINDOWS_USER" { u = $2 } $1 == "WINDOWS_HOST" { h = $2 } END { if (u != "" && h != "") print u "@" h }'
}
# Adds or updates the Windows side of every reachable host.
refresh_win_hosts() {
  local n e w list
  for n in $(host_names); do
    e="$(win_entry_from_host "$n")"
    [ -n "$e" ] || continue
    list=""
    for w in $AGENT_WIN_HOSTS; do
      [ "$(host_name "$w")" = "$(host_name "$e")" ] || list="${list:+$list }$w"
    done
    AGENT_WIN_HOSTS="${list:+$list }$e"
  done
}
win_host_names() { local h; for h in $AGENT_WIN_HOSTS; do host_name "$h"; done; }

ssh_block() {
  local h n sep=""
  for h in $AGENT_HOSTS $AGENT_WIN_HOSTS; do
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
      info "Tailscale SSH asks for a browser check on every login, which hc can't do."
      info "At https://login.tailscale.com/admin/acls change the \"ssh\" rule's \"action\" from"
      info "\"check\" to \"accept\" and save. This is once for all your machines." ;;
    *) info "is $CUR_HOST turned on and online in Tailscale?" ;;
  esac
  return 1
}

# The Herdr app shows the machines hc knows. --install copies this hc to the
# host when it has none or an older one.
check_hc_machine() {
  hc machine ls --json 2>/dev/null \
    | jq -e --arg n "$CUR_HOST" '[.machines[]?.name] | index($n) != null' >/dev/null
}
install_hc_machine() {
  local out
  out="$(hc machine add "$CUR_HOST" --name "$CUR_HOST" --install </dev/null 2>&1)" && return 0
  printf '%s\n' "$out" | sed 's/^/    /'
  return 1
}

# The Windows tasks that keep WSL up (windows/setup.ps1). A task whose saved
# password no longer works (password changed, PC renamed) never starts and says
# nothing, so each must have started in the last 15 minutes. Prints one line per
# problem, then "checked".
WIN_TASKS_PS='
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$settled = ((Get-Date) - $boot).TotalMinutes -gt 15
foreach ($n in "agent-box WSL keepalive", "agent-box WSL watchdog", "agent-box remote shutdown", "agent-box net watchdog") {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if (-not $t) { "missing: $n"; continue }
    if ($t.State -eq "Disabled") { "disabled: $n"; continue }
    $last = ($t | Get-ScheduledTaskInfo).LastRunTime
    if ($settled -and $t.State -ne "Running" -and $last -lt (Get-Date).AddMinutes(-15)) {
        "not starting: $n (last run $($last.ToString("yyyy-MM-dd HH:mm")))"
    }
}
"checked"
'
# win_ps <win host> <script>: Windows sshd opens PowerShell; -EncodedCommand keeps
# the script intact through both shells.
win_ps() {
  local enc
  enc="$(printf '%s' "\$ProgressPreference = 'SilentlyContinue'; $2" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  with_timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$1" \
    "powershell -NoProfile -NonInteractive -EncodedCommand $enc" </dev/null 2>/dev/null | tr -d '\r'
}
WIN_PROBLEMS=""
check_win_tasks() {
  local out
  out="$(win_ps "$CUR_WIN" "$WIN_TASKS_PS")"
  printf '%s\n' "$out" | grep -qx checked || { WIN_PROBLEMS="couldn't run PowerShell over SSH"; return 1; }
  WIN_PROBLEMS="$(printf '%s\n' "$out" | grep -vx checked | grep . || true)"
  [ -z "$WIN_PROBLEMS" ]
}
install_win_tasks() {
  info "on $CUR_WIN, in an administrator PowerShell, rerun the Windows install (it asks"
  info "for your Windows password and registers the tasks again):"
  info "  irm https://raw.githubusercontent.com/mikitahimpel/agent-box/main/install.ps1 | iex"
  return 1
}
show_win_problems() { printf '%s\n' "$WIN_PROBLEMS" | while IFS= read -r l; do [ -z "$l" ] || info "$l"; done; }

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

OFF_TARGET="" POWER_ACTION="" HOST_ARG="" ADD_TARGET="" ADD_NAME=""
ORIG_ARGS=()
for _a in "$@"; do [ "$_a" = sync ] || ORIG_ARGS+=("$_a"); done
while [ $# -gt 0 ]; do
  case "$1" in
    check|install|sync) MODE="$1" ;;
    add) MODE=add; case "${2:-}" in ""|-*) ;; *) ADD_TARGET="$2"; shift ;; esac ;;
    off|restart) MODE=power; POWER_ACTION="$1"; case "${2:-}" in ""|-*) ;; *) OFF_TARGET="$2"; shift ;; esac ;;
    _shutdown-pending) shutdown_pending; exit $? ;;
    _power-pending) power_pending; exit $? ;;
    _busy) host_busy; exit $? ;;
    --role) ROLE="${2:-}"; shift ;;
    --host) HOST_ARG="${2:-}"; shift ;;
    --user) AGENT_USER="${2:-}"; shift ;;
    --vault) PASS_VAULT="${2:-}"; shift ;;
    --token-vaults) PASS_TOKEN_VAULTS="${2:-}"; shift ;;
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
  host:armv6l|host:armv7l) die "hosts need a 64-bit OS (Claude Code and hc have no 32-bit ARM builds)" ;;
esac

if [ "$MODE" = add ]; then
  add_host "$ADD_TARGET" "$ADD_NAME"
fi
if [ "$MODE" = power ]; then
  request_power "$POWER_ACTION" "$OFF_TARGET"
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
step "login-shell PATH and pass-cli key"  check_path_in_login_shell install_path_in_login_shell
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
    step "tailscaled restarts after any crash" check_tailscaled_restart install_tailscaled_restart
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
step "shared Claude config (claude/ in this repo)" check_shared_claude install_shared_claude
if [ "$PLATFORM" = mac ] && [ -d "$REX_SUPPORT" ]; then
  step "Rex agent workflow (rex/ in this repo)" check_rex_agents install_rex_agents
fi
if [ "$PLATFORM" != mac ] && { [ "$ROLE" = host ] || [ "$AUTONOMOUS" = on ]; }; then
  step "Claude sandbox deps (bubblewrap, socat)" check_sandbox_deps install_sandbox_deps
  have bwrap && step "bubblewrap can create sandboxes" check_bwrap_works install_bwrap_works
fi
if [ "$AUTONOMOUS" = on ]; then
  step "Claude autonomous mode (sandboxed, no prompts)" check_autonomous install_autonomous
fi
if [ "$ROLE" = host ]; then
  have claude && step "claude on the login-shell PATH (hc starts programs with it)" check_claude_login_path install_claude_login_path
  if hc_installed; then
    ok "hc (herdr-core)"
  else
    info "hc isn't here yet: it arrives when a client adds this machine (agent-box install"
    info "there, or the Herdr app's machine list), which runs 'hc machine add --install'"
  fi
  if [ "$SYSTEMD" = 1 ]; then
    step "old herdr TUI removed (server, binary, config, Claude hook)" check_no_herdr_tui install_no_herdr_tui
    step "hc terminals run without a login (linger)" check_linger   install_linger
  fi
fi

if [ "$ROLE" = host ] && [ "$SYSTEMD" = 1 ]; then
  section "Memory"
  step "agents capped at 60% (throttled) / 70% of memory" check_user_memory_cap install_user_memory_cap
  step "earlyoom kills one job, not the machine" check_earlyoom    install_earlyoom
  step "memory kept for tailscaled (256M) and hc + agents (20%)" check_memory_reserve install_memory_reserve
  if [ -n "$(runner_units)" ]; then
    step "CI runners capped at 50% of memory, less CPU than agents" check_runner_caps install_runner_caps
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
step "Proton Pass token stored (pst_…::…)" check_token             install_token
if [ "$MODE" = check ] && ! check_token && has_old_token; then
  info "found the token of an older agent-box; install moves it"
fi
step "no old agent-box token or pp session" check_no_old_pass       install_no_old_pass
step "pp wrapper"                         check_pp                  install_pp
step "CLAUDE.md agent-box section"        check_claude_md           install_claude_md
if have pass-cli && check_token && check_pp; then
  step "pp can log in"                    check_pp_works            install_pp_works
fi

if [ "$ROLE" = client ]; then
  section "Hosts"
  if [ -z "$HOST_ARG" ]; then
    for _h in $(discover_hosts); do
      info "found $_h on Tailscale"
      AGENT_HOSTS="${AGENT_HOSTS:+$AGENT_HOSTS }$_h"
    done
  fi
  [ -z "$AGENT_HOSTS" ] || refresh_win_hosts
  if [ -z "$AGENT_HOSTS" ]; then
    info "no hosts yet: set one up (the one-line install on it), then rerun here"
  else
    step "SSH config for $({ host_names; win_host_names; } | paste -sd, - | sed 's/,/, /g')" check_ssh_config install_ssh_config
  fi
  if [ -n "$AGENT_HOSTS" ] && check_ssh_config; then
    for CUR_HOST in $(host_names); do
      step "$CUR_HOST reachable over SSH"    check_ssh_reachable       install_ssh_reachable
      if have hc && check_ssh_reachable; then
        step "hc machine '$CUR_HOST' (shows in the Herdr app)" check_hc_machine install_hc_machine
      fi
    done
    for CUR_WIN in $(win_host_names); do
      if win_ps "$CUR_WIN" '"checked"' | grep -qx checked; then
        step "Windows tasks on $CUR_WIN start (WSL keepalive, watchdogs)" check_win_tasks install_win_tasks \
          || show_win_problems
      else
        missing "$CUR_WIN reachable over SSH (Windows side of a WSL host)"
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
