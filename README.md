# agent-box

Set up machines for running coding agents remotely with [herdr](https://herdr.dev), Tailscale and Proton Pass. Every machine is either a **host** (agents run there: Linux including a Raspberry Pi, or WSL on Windows) or a **client** (you work from it: macOS or Linux). `setup.sh` checks and installs both roles.

The reference setup is a Windows gaming PC as the host and a Mac as the client. You press the PC's power button. About a minute later, **pc** comes online in [herdr](https://herdr.dev) on your Mac. You open panes there and run Claude Code in WSL Ubuntu. Nothing else needs touching: no Windows login, no monitor, no SSH keys. The same PC stays a normal Windows gaming machine.

```
Mac: herdr (Local + "pc") ──ssh over Tailscale──▶ pc = WSL Ubuntu
                                                     tailscaled (Tailscale SSH)
                                                     herdr server (systemd user service)
                                                     Claude Code, projects in ~/
Windows host: games · Agents off/on · WSL keepalive · Wi-Fi watchdog · remote shutdown/restart · weekly WSL snapshot
```

## What's in this repo

| File | Runs on | Does |
|---|---|---|
| `setup.sh` | WSL, Linux, macOS | Checks the setup and fixes whatever is missing. Safe to rerun. Installs itself as the `agent-box` command. |
| `windows/setup.ps1` | Windows (admin PowerShell) | Power, Wi-Fi, WSL memory, and the keepalive, watchdog, shutdown and snapshot tasks. |
| `claude/` | every machine | Shared Claude config: CLAUDE.md, skills, commands, agents. See [claude/README.md](claude/README.md). |

## Install

One command per machine, the same command every time: to set up, to fix, to update. It downloads agent-box, works out what the machine is, and asks only for what it can't find out (logins, tokens, a name).

**macOS, Linux, WSL, Raspberry Pi:**
```bash
curl -fsSL https://raw.githubusercontent.com/mikitahimpel/agent-box/main/install.sh | bash
```

**Windows** (administrator PowerShell). Sets up Windows, then runs the line above inside WSL:
```powershell
irm https://raw.githubusercontent.com/mikitahimpel/agent-box/main/install.ps1 | iex
```

Then:
- Run `claude` once on each machine to log in.
- **Tailscale admin console:** disable key expiry for each host, and set the SSH rule once (see [Tailscale](#tailscale-admin-console-once)).
- On the Mac: run the same command again after setting up a new host. It finds the host on Tailscale and adds it to herdr.

What it decides for you:

| Question | Answer |
|---|---|
| Host or client? | macOS is a client. Linux and WSL are hosts. |
| The host's name | Its current Tailscale name. On a fresh machine, it asks once and suggests the hostname. |
| Which hosts a client connects to | Online Linux machines on your Tailscale with Tailscale SSH and agent-box installed. Logins are tried with the users your other hosts and `~/.ssh/config` use, then yours. |

Afterwards the machine has the `agent-box` command:
```bash
agent-box                  # check what's missing (changes nothing)
agent-box install          # fix
agent-box sync             # update agent-box, then install (what the one-liner does)
agent-box off [host]       # shut a host down remotely
agent-box restart [host]   # restart a host remotely
agent-box add user@address # set up a Linux machine on your network from the Mac, over plain SSH
```

Options override what it decides. `install` saves them to `~/.config/agent-box/config`, so you only pass them once:

| Option | Default | Meaning |
|---|---|---|
| `--role host\|client` | macOS = client, WSL/Linux = host | Which role this machine plays |
| `--host NAME` | current Tailscale name, else asked | On a host: its Tailscale name |
| `--host USER@NAME,...` | found on Tailscale | On a client: exactly these hosts, e.g. `gimpel@pc,pi@pi` |
| `--user NAME` | tried automatically | On a client: Linux user for hosts listed without `USER@` |
| `--vault NAME` | `Agents` | Proton Pass vault agents may read |
| `--autonomous on\|off` | `off` | Claude works without permission prompts inside its sandbox (see below) |

Pass options through the one-liner with `bash -s --`, e.g. `curl … | bash -s -- --autonomous on`. The environment variables `AGENT_ROLE`, `AGENT_HOST`, `AGENT_HOSTS`, `AGENT_USER` and `PASS_VAULT` work too.

## What's in this repo

| File | Runs on | Does |
|---|---|---|
| `install.sh`, `install.ps1` | everywhere / Windows | The one-line installers above |
| `setup.sh` | WSL, Linux, macOS | Checks the setup and fixes whatever is missing. Installs itself as the `agent-box` command. |
| `windows/setup.ps1` | Windows (admin PowerShell) | Power, Wi-Fi, WSL memory, and the keepalive, watchdog, shutdown and snapshot tasks |
| `claude/` | every machine | Shared Claude config: CLAUDE.md, skills, commands, agents. See [claude/README.md](claude/README.md). |

## The Windows PC in detail

### BIOS (once, by hand)
Gigabyte AORUS AM4:
- **Boot → Boot Option #1:** the Windows drive
- **Boot → Fast Boot:** Enabled (not "Ultra Fast")
- **Tweaker → Advanced CPU Settings → SVM Mode:** Enabled
- CSM disabled (UEFI only), so nothing waits for a key press

### What the Windows installer does
`install.ps1` downloads agent-box to `%USERPROFILE%\agent-box` and runs `windows\setup.ps1 -Install`, which sets:
- sleep on AC power to never
- Wi-Fi adapter never powered off to save power
- WSL memory capped at your RAM minus 4GB (WSL only takes what it uses; switch agents off before games)
- Fast Startup off, so startup tasks run and **Agents off** ends when the PC is turned off
- a **watchdog** task that resets Wi-Fi if the internet is down (at boot and every 3 min)
- a **keepalive** task that keeps WSL running from boot, before anyone logs in (at boot and every 5 min)
- a **remote shutdown** task that turns Windows off after `agent-box off`, or restarts it after `agent-box restart` (checks every minute)
- **Agents off** and **Agents on** shortcuts on the desktop (see [Games](#games-on-the-windows-pc))
- a weekly **WSL snapshot** (`wsl --export`) to `%USERPROFILE%\wsl-backups`, keeping the newest 3. If the PC was off on Sunday, it runs at the next boot. To change it, run `windows\setup.ps1 -Install -BackupDir D:\wsl-backups -BackupKeep 5`.

The tasks that touch WSL run as your Windows user before anyone logs in, so it asks for your Windows password once.

If WSL isn't installed yet, it installs Ubuntu and stops. Reboot, open Ubuntu once to create your Linux user, then run the same command again. It then runs the Linux install inside WSL, restarting WSL once on the way to turn on systemd.

Also check these by hand:
- **BitLocker / Device Encryption:** TPM-only, no PIN.
- **Windows Tailscale:** not needed. If it's installed under the same name as WSL, rename or remove it so they don't clash.

### Games on the Windows PC
Before a game, double-click **Agents off** on the desktop. It stops WSL and everything in it (agents, herdr, CI runners) and gives its memory back to Windows. The PC then drops out of herdr, and CI jobs for it wait in the queue.

Agents come back with **Agents on**, or by themselves the next time the PC is turned on. Claude conversations that were running can be continued with `claude --resume`.

### What the Linux install does on a host
- `/etc/wsl.conf` on WSL: systemd on, Windows drives hidden from agents
- Tailscale with **Tailscale SSH** (opens a login link the first time)
- herdr, plus its server as a systemd user service with linger, so it runs without a login
- Claude Code, the herdr ↔ Claude integration, and the sandbox dependencies (`bubblewrap`, `socat`)
- GitHub: `gh`, git over SSH with this machine's own key, and your git name and email
- Proton Pass CLI, the agent token (asked once) and the `pp` wrapper
- the agent-box section in `~/.claude/CLAUDE.md`: shared instructions, secrets usage, and on hosts the dev-server rule
- links for the shared skills, commands and agents from `claude/`

On a client (the Mac) it sets up the same Claude, GitHub and Proton Pass parts, plus one `Host` entry per host in `~/.ssh/config` and a herdr machine per host. A host must be on for the Mac to add it.

## Tailscale admin console (once)
- **Machines → each host → Disable key expiry**
- **Access controls:** make Tailscale SSH accept logins without browser re-checks. herdr reconnects in the background, so `check` mode would break it:
  ```json
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot"] }
  ]
  ```
- **DNS → MagicDNS:** on (it is by default)

## Raspberry Pi (or another Linux host)

Any Linux machine can be a host that works exactly like the PC. It needs a **64-bit OS** (Raspberry Pi OS 64-bit on a Pi 3, 4 or 5); Claude Code and herdr have no 32-bit ARM builds. 4 GB RAM or more is comfortable for a few agents.

Run the one-line install on it. Or, if you'd rather not touch the Pi, turn SSH on (Raspberry Pi Imager → *Enable SSH*, or `sudo raspi-config` → Interface Options → SSH) and run from the Mac:
```bash
agent-box add pi@raspberrypi.local --host pi
```
That asks for the Pi's password once, copies agent-box there, runs the host install in your terminal, then adds the Pi on the Mac. Without `--host`, the name comes from the Pi's hostname.

`agent-box off pi` and `agent-box restart pi` act on it directly; that uses `sudo` without a password, which Raspberry Pi OS allows by default.

## Daily use

| You want to | Do this |
|---|---|
| Start | Press the power button. **pc** comes online in herdr in about 1–2 min. |
| Work | Open panes under **pc** in herdr on the Mac. Agents keep running when the Mac closes. |
| Stop | `agent-box off` from the Mac (Windows shuts down within ~2 min), or a short press of the power button. `agent-box off pi` for the Pi. |
| Restart | `agent-box restart` from the Mac (Windows restarts within ~2 min and comes back on its own). |
| Open an app an agent started | `http://pc:<port>` in the Mac's browser. Agents on hosts are told to bind dev servers to `0.0.0.0` and give you this URL. |
| Change shared Claude config | Edit `claude/` in the repo, push, then `agent-box sync` on each machine. |
| Game | **Agents off** on the PC's desktop first; **Agents on** (or the next power-on) brings them back. |
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
2. The install asks for the token once. On macOS it goes in the Keychain; on Linux/WSL in `~/.config/pass-agent/token` (mode 600).
3. `pp` wraps `pass-cli`. Agent sessions last 2 hours, and `pp` logs back in with the stored token whenever the session has expired.

Agents use it like this (the `~/.claude/CLAUDE.md` block tells them to):
```bash
# .env
API_KEY=pass://Agents/<item>/<field>

pp run --env-file .env -- npm test
```

Check what agents read with `pass-cli agent monitor <token-name>` (logged in as yourself) or under **Manage vault access** in the web app.

**Yearly:** create new tokens before they expire. Delete the stored token (`security delete-generic-password -s proton-pass-agent` on macOS, `rm ~/.config/pass-agent/token` on Linux) and rerun `agent-box install`.

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
2. Inside WSL: `agent-box` (check mode) and `systemctl --user status herdr`
3. On the Mac: `herdr machine status pc` and `ssh pc true`

## Known limits

- `install.ps1` and `windows/setup.ps1` are written for Windows PowerShell 5.1 but haven't been run on a real machine yet. Read their output before trusting them.
- Host discovery logs in to each new Linux peer with Tailscale SSH to look for agent-box. A peer whose user isn't among the tried ones is skipped; add it with `--host user@name`.
- `pp` assumes `pass-cli info` fails when the session has expired. Run `pp info` again 2 hours after setup to confirm the automatic re-login.
- If you change your Windows password, delete the `agent-box` tasks in Task Scheduler and run the Windows one-liner again.
- `wsl --export` of a running distro and the shutdown task's call into WSL are untested on a real PC. Check Task Scheduler's "Last Run Result" after the first week.
- Snapshots are full copies of Ubuntu and can be large. Point `-BackupDir` at a drive with room.
