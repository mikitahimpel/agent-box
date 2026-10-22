# agent-pc-setup

Turn a Windows gaming PC into a remote Linux box for coding agents.

You press the PC's power button. About a minute later, **pc** comes online in [herdr](https://herdr.dev) on your Mac. You open panes there and run Claude Code in WSL Ubuntu. Nothing else needs touching: no Windows login, no monitor, no SSH keys. The same PC stays a normal Windows gaming machine.

```
Mac: herdr (Local + "pc") ──ssh over Tailscale──▶ pc = WSL Ubuntu
                                                     tailscaled (Tailscale SSH)
                                                     herdr server (systemd user service)
                                                     Claude Code, projects in ~/
Windows host: games · WSL keepalive task · Wi-Fi watchdog task
```

## What's in this repo

| File | Runs on | Does |
|---|---|---|
| `setup.sh` | WSL, Linux, macOS | Checks the setup and fixes whatever is missing. Safe to rerun. |
| `windows/setup.ps1` | Windows (admin PowerShell) | Configures power, Wi-Fi, WSL memory, the keepalive task and the watchdog task. |

Both scripts only check by default and report what's missing. Add `install` (or `-Install` on Windows) to apply changes.

```bash
./setup.sh                       # check
./setup.sh install               # fix
./setup.sh install --role client # force a role (default: macOS = client, WSL/Linux = host)
```

Settings come from environment variables: `PC_HOST` (default `pc`), `PC_USER` (Linux user on the host, asked if missing), `PASS_VAULT` (default `Agents`).

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
gh repo clone mikitahimpel/agent-pc-setup $env:USERPROFILE\agent-pc-setup
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\agent-pc-setup\windows\setup.ps1 -Install
```
This sets:
- sleep on AC power to never
- Wi-Fi adapter never powered off to save power
- WSL memory capped at half your RAM
- a **watchdog** task that resets Wi-Fi if the internet is down (at boot and every 3 min)
- a **keepalive** task that keeps WSL running from boot, before anyone logs in (at boot and every 5 min)

If WSL isn't installed yet, it installs Ubuntu. Reboot, open Ubuntu once to create your Linux user, then rerun the script.

Also check these by hand:
- **BitLocker / Device Encryption:** TPM-only, no PIN.
- **Fast Startup:** fine to leave on; the repeating tasks cover the cases where it skips startup triggers.
- **Windows Tailscale:** not needed. If it's installed with the name `pc`, rename or remove it so it doesn't clash with WSL.

### 3. WSL Ubuntu (the host)
```bash
sudo apt update && sudo apt install -y gh
gh auth login
gh repo clone mikitahimpel/agent-pc-setup ~/agent-pc-setup
cd ~/agent-pc-setup
./setup.sh install
```
`gh auth login` also covers the GitHub login agents need later.
The first run writes `/etc/wsl.conf` (systemd on, Windows drives hidden from agents) and asks you to run `wsl --shutdown` in PowerShell. Reopen Ubuntu and run `./setup.sh install` again to finish:
- Tailscale with **Tailscale SSH**, named `pc` (opens a login link the first time)
- herdr, plus its server as a systemd user service with linger, so it runs without a login
- Claude Code, the herdr ↔ Claude integration, and the sandbox dependencies (`bubblewrap`, `socat`)
- Proton Pass CLI, the agent token (asked once), the `pp` wrapper and the secrets section in `~/.claude/CLAUDE.md`

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
This adds `Host pc` to `~/.ssh/config`, accepts the PC's host key, saves `pc` as a herdr machine, and sets up the same Proton Pass agent access as the host. The PC must be on for the last two steps.

## Daily use

| You want to | Do this |
|---|---|
| Start | Press the power button. **pc** comes online in herdr in about 1–2 min. |
| Work | Open panes under **pc** in herdr on the Mac. Agents keep running when the Mac closes. |
| Stop | Short press of the power button (Windows shuts down cleanly). |
| Game | Just play. `wsl --shutdown` first if you want the RAM back. |
| Updates | Use **Restart** now and then for a full, clean boot. |

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

## Acceptance test

Repeat 5–10 times: shut the PC down, press the power button, don't touch it. It passes if **pc** comes online in herdr on your Mac every time and you can open a pane and run `claude`.

If it doesn't come online:
1. Is the `WSL keepalive` task running? (Task Scheduler on Windows)
2. Inside WSL: `./setup.sh` (check mode) and `systemctl --user status herdr`
3. On the Mac: `herdr machine status pc` and `ssh pc true`

## Known limits

- The Windows script is written for Windows PowerShell 5.1 but hasn't been run on a real machine yet. Read its check output before trusting it.
- `pp` assumes `pass-cli info` fails when the session has expired. Run `pp info` again 2 hours after setup to confirm the automatic re-login.
- If you change your Windows password, delete the `agent-pc WSL keepalive` task and rerun `windows\setup.ps1 -Install`.
