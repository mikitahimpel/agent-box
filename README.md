# agent-box

Set up machines for running coding agents remotely with [herdr](https://herdr.dev), Tailscale and Proton Pass. Every machine is either a **host** (agents run there: Linux, or WSL on Windows) or a **client** (you work from it: macOS or Linux). `setup.sh` checks and installs both roles.

The reference setup is a Windows gaming PC as the host and a Mac as the client. You press the PC's power button. About a minute later, **pc** comes online in [herdr](https://herdr.dev) on your Mac. You open panes there and run Claude Code in WSL Ubuntu. Nothing else needs touching: no Windows login, no monitor, no SSH keys. The same PC stays a normal Windows gaming machine.

```
Mac: herdr (Local + "pc") ──ssh over Tailscale──▶ pc = WSL Ubuntu
                                                     tailscaled (Tailscale SSH)
                                                     herdr server (systemd user service)
                                                     Claude Code, projects in ~/
Windows host: games · WSL keepalive · Wi-Fi watchdog · remote shutdown · weekly WSL snapshot
```

## What's in this repo

| File | Runs on | Does |
|---|---|---|
| `setup.sh` | WSL, Linux, macOS | Checks the setup and fixes whatever is missing. Safe to rerun. Installs itself as the `agent-box` command. |
| `windows/setup.ps1` | Windows (admin PowerShell) | Power, Wi-Fi, WSL memory, and the keepalive, watchdog, shutdown and snapshot tasks. |
| `claude/` | every machine | Shared Claude config: CLAUDE.md, skills, commands, agents. See [claude/README.md](claude/README.md). |

Both scripts only check by default and report what's missing. Add `install` (or `-Install` on Windows) to apply changes.

```bash
agent-box                  # check (before the first install: ./setup.sh)
agent-box install          # fix
agent-box sync             # git pull this repo, then install
agent-box off [host]       # shut a Windows/WSL host down remotely
```

| Option | Default | Meaning |
|---|---|---|
| `--role host\|client` | macOS = client, WSL/Linux = host | Which role this machine plays |
| `--host NAME` | `pc` | Tailscale name of the host |
| `--user NAME` | asked | Linux user on the host (clients only) |
| `--vault NAME` | `Agents` | Proton Pass vault agents may read |
| `--autonomous on\|off` | `off` | Claude works without permission prompts inside its sandbox (see below) |

`install` saves the options to `~/.config/agent-box/config`, so later runs need no flags. The environment variables `AGENT_ROLE`, `AGENT_HOST`, `AGENT_USER` and `PASS_VAULT` work too.

## Setup order

### 1. BIOS (once, by hand)
Gigabyte AORUS AM4:
- **Boot → Boot Option #1:** the Windows drive
- **Boot → Fast Boot:** Enabled (not "Ultra Fast")
- **Tweaker → Advanced CPU Settings → SVM Mode:** Enabled
- CSM disabled (UEFI only), so nothing waits for a key press

### 2. Windows
The repo is private, so get it with the GitHub CLI. In an administrator PowerShell:
```powershell
winget install --id GitHub.cli
gh auth login
gh repo clone mikitahimpel/agent-box $env:USERPROFILE\agent-box
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\agent-box\windows\setup.ps1 -Install
```
This sets:
- sleep on AC power to never
- Wi-Fi adapter never powered off to save power
- WSL memory capped at half your RAM
- a **watchdog** task that resets Wi-Fi if the internet is down (at boot and every 3 min)
- a **keepalive** task that keeps WSL running from boot, before anyone logs in (at boot and every 5 min)
- a **remote shutdown** task that turns Windows off after `agent-box off` (checks every minute)
- a weekly **WSL snapshot** (`wsl --export`) to `%USERPROFILE%\wsl-backups`, keeping the newest 3. If the PC was off on Sunday, it runs at the next boot. Change it with `-BackupDir D:\wsl-backups -BackupKeep 5`.

The tasks that touch WSL run as your Windows user before anyone logs in, so the script asks for your Windows password once.

If WSL isn't installed yet, it installs Ubuntu. Reboot, open Ubuntu once to create your Linux user, then rerun the script.

Also check these by hand:
- **BitLocker / Device Encryption:** TPM-only, no PIN.
- **Fast Startup:** fine to leave on; the repeating tasks cover the cases where it skips startup triggers.
- **Windows Tailscale:** not needed. If it's installed with the name `pc`, rename or remove it so it doesn't clash with WSL.

### 3. WSL Ubuntu (the host)
```bash
sudo apt update && sudo apt install -y gh
gh auth login
gh repo clone mikitahimpel/agent-box ~/agent-box
cd ~/agent-box
./setup.sh install
```
This first `gh auth login` is only to clone the private repo. `setup.sh` takes GitHub access from there (see [GitHub](#github)).
The first run writes `/etc/wsl.conf` (systemd on, Windows drives hidden from agents) and asks you to run `wsl --shutdown` in PowerShell. Reopen Ubuntu and run `./setup.sh install` again to finish:
- Tailscale with **Tailscale SSH**, named `pc` (opens a login link the first time)
- herdr, plus its server as a systemd user service with linger, so it runs without a login
- Claude Code, the herdr ↔ Claude integration, and the sandbox dependencies (`bubblewrap`, `socat`)
- GitHub: `gh`, git over SSH with this machine's own key, and your git name and email
- Proton Pass CLI, the agent token (asked once) and the `pp` wrapper
- the agent-box section in `~/.claude/CLAUDE.md`: shared instructions, secrets usage, and on hosts the dev-server rule
- links for the shared skills, commands and agents from `claude/`

Then log in to Claude once inside WSL by running `claude`.

### 4. Tailscale admin console (once)
- **Machines → pc → Disable key expiry**
- **Access controls:** make Tailscale SSH accept logins without browser re-checks. herdr reconnects in the background, so `check` mode would break it:
  ```json
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot"] }
  ]
  ```
- **DNS → MagicDNS:** on (it is by default)

### 5. Mac (the client)
```bash
./setup.sh install
```
Use `./setup.sh install --user <linux user on pc>` the first time. This adds `Host pc` to `~/.ssh/config`, accepts the PC's host key, saves `pc` as a herdr machine, and sets up the same Proton Pass agent access as the host. The PC must be on for the last two steps.

## Daily use

| You want to | Do this |
|---|---|
| Start | Press the power button. **pc** comes online in herdr in about 1–2 min. |
| Work | Open panes under **pc** in herdr on the Mac. Agents keep running when the Mac closes. |
| Stop | `agent-box off` from the Mac (Windows shuts down within ~2 min), or a short press of the power button. |
| Open an app an agent started | `http://pc:<port>` in the Mac's browser. Agents on hosts are told to bind dev servers to `0.0.0.0` and give you this URL. |
| Change shared Claude config | Edit `claude/` in the repo, push, then `agent-box sync` on each machine. |
| Game | Just play. `wsl --shutdown` first if you want the RAM back. |
| Updates | Use **Restart** now and then for a full, clean boot. |

## Autonomous mode

`agent-box install --autonomous on` lets Claude work without stopping for approval, on any machine and OS. It's saved, so later runs keep it on. It merges this into `~/.claude/settings.json`, leaving your other settings alone and keeping a backup in `settings.json.bak`:

- **Sandbox on:** Bash commands run inside Claude's sandbox (bubblewrap on Linux/WSL, built in on macOS) and need no approval.
- **No escape:** commands can't fall back to running outside the sandbox, and Claude refuses to start if the sandbox is unavailable instead of silently running without it.
- **Edits auto-approved:** file edits don't ask (`acceptEdits`).
- **Network allowlist:** sandboxed commands may reach the hosts in [claude/allowed-domains.txt](claude/allowed-domains.txt) (GitHub, npm, PyPI, crates, Go, Proton) without asking. Any other host still prompts once, so add the ones you need to the file and run `agent-box sync`.

`--autonomous off` stops managing these settings but doesn't remove them. Undo with `/sandbox` inside Claude or by restoring `settings.json.bak`.

## GitHub

Every machine pushes over SSH with its **own** key, so if one machine is lost you delete only its key under **GitHub → Settings → SSH keys** (titled `agent-box <hostname>`). Each part is checked first and left alone if it already works:

1. `gh` installed and logged in (`gh auth login`, browser or device code).
2. `gh` set to use SSH for git, so `gh repo clone` gives SSH remotes.
3. `ssh -T git@github.com` authenticates. If it already does (any key, ssh-agent, Keychain), nothing changes. Otherwise it uses `~/.ssh/id_ed25519` (or `id_ecdsa` / `id_rsa`), creates an ed25519 key without a passphrase if there is none, and uploads it with `gh ssh-key add`. Uploading needs the `admin:public_key` scope; `gh` asks for it once if your login lacks it.
4. `git config --global user.name` and `user.email`, only if unset: your GitHub name and your `…@users.noreply.github.com` address.

The keys have no passphrase so agents can push with nobody at the keyboard. They are deliberately not kept in Proton Pass: the stored agent token would unlock them just as easily, and a per-machine key is quicker to revoke than a shared one.

## Secrets: Proton Pass agent tokens

Agents read secrets from one Proton Pass vault (`Agents` by default) through a **scoped agent token**. Each token can only see the vaults you pick, is read-only by default, and logs every read with a reason.

1. In **pass.proton.me → Settings → Access tokens → New token**, create one token per machine (`pc`, `mac`): expiry 1 year, vault `Agents`, **Use for AI agent** on.
2. `./setup.sh install` asks for the token once. On macOS it goes in the Keychain; on Linux/WSL in `~/.config/pass-agent/token` (mode 600).
3. `pp` wraps `pass-cli`. Agent sessions last 2 hours, and `pp` logs back in with the stored token whenever the session has expired.

Agents use it like this (the `~/.claude/CLAUDE.md` block tells them to):
```bash
# .env
API_KEY=pass://Agents/<item>/<field>

pp run --env-file .env -- npm test
```

Check what agents read with `pass-cli agent monitor <token-name>` (logged in as yourself) or under **Manage vault access** in the web app.

**Yearly:** create new tokens before they expire. Delete the stored token (`security delete-generic-password -s proton-pass-agent` on macOS, `rm ~/.config/pass-agent/token` on Linux) and rerun `./setup.sh install`.

**Note:** anything running as your user, agents included, can read the stored token. Only put in the vault what you're fine with an agent seeing.

## Restoring WSL from a snapshot

If an agent breaks the Ubuntu install, in PowerShell:
```powershell
wsl --unregister Ubuntu                      # deletes the broken install
wsl --import Ubuntu $env:USERPROFILE\wsl\Ubuntu $env:USERPROFILE\wsl-backups\Ubuntu-<date>.tar
```
Then set your default user again in WSL (`/etc/wsl.conf` → `[user]` `default=<you>`) and run `wsl --shutdown`. The snapshot includes everything in Ubuntu: projects, tokens and logins.

## Acceptance test

Repeat 5–10 times: shut the PC down, press the power button, don't touch it. It passes if **pc** comes online in herdr on your Mac every time and you can open a pane and run `claude`.

If it doesn't come online:
1. Is the `WSL keepalive` task running? (Task Scheduler on Windows)
2. Inside WSL: `./setup.sh` (check mode) and `systemctl --user status herdr`
3. On the Mac: `herdr machine status pc` and `ssh pc true`

## Known limits

- The Windows script is written for Windows PowerShell 5.1 but hasn't been run on a real machine yet. Read its check output before trusting it.
- `pp` assumes `pass-cli info` fails when the session has expired. Run `pp info` again 2 hours after setup to confirm the automatic re-login.
- If you change your Windows password, delete the `agent-box` tasks in Task Scheduler and rerun `windows\setup.ps1 -Install`.
- `wsl --export` of a running distro and the shutdown task's call into WSL are untested on a real PC. Check Task Scheduler's "Last Run Result" after the first week.
- Snapshots are full copies of Ubuntu and can be large. Point `-BackupDir` at a drive with room.
