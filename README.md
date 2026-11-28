# agent-box

Set up machines for running coding agents remotely with the [Herdr](https://herdr.dev) app and herdr-core (`hc`), Tailscale and Proton Pass. Every machine is either a **host** (agents run there: Linux including a Raspberry Pi, or WSL on Windows) or a **client** (you work from it: macOS or Linux). `setup.sh` checks and installs both roles.

The reference setup is a Windows gaming PC as the host and a Mac as the client. You press the PC's power button. About a minute later, **pc** comes online in the Herdr app on your Mac. You open spaces on it there and run Claude Code in WSL Ubuntu. Nothing else needs touching: no Windows login, no monitor, no SSH keys. The same PC stays a normal Windows gaming machine.

```
Mac: Herdr app (Local + "pc") ──ssh over Tailscale──▶ pc = WSL Ubuntu
                                                         tailscaled (Tailscale SSH)
                                                         hc core (started over SSH, systemd user service)
                                                     Claude Code, projects in ~/
Windows host: games · Agents off/on · WSL keepalive + hang watchdog · Wi-Fi watchdog · remote shutdown/restart · weekly WSL snapshot
              Tailscale "pc-win" + OpenSSH, so you can get in when WSL is down
```

## What's in this repo

| File | Runs on | Does |
|---|---|---|
| `setup.sh` | WSL, Linux, macOS | Checks the setup and fixes whatever is missing. Safe to rerun. Installs itself as the `agent-box` command. |
| `windows/setup.ps1` | Windows (admin PowerShell) | Power, Wi-Fi, WSL memory, Windows Tailscale and SSH, and the keepalive, watchdog, shutdown and snapshot tasks. |
| `rules/` | every machine | Package: rules for agents (`~/.claude/rules/`), `artifact-dir`, the manual `agent-orchestrator` skill; its post-install adds other people's skills and `agent-device` |
| `pp/` | every machine | Package: the `pp` wrapper, the Proton `pass-cli` dependency, and the SSH config that picks the Agents-vault key |
| `rex/` | macOS with [Rex](https://www.superlogical.com/rex) | Package: Rex agent workflow: `rex-agent`, `rex-task`, `conf.d/agents.lua`, the `rex-placement` skill. See [Rex on the Mac](#rex-on-the-mac). |
| `host/` | hosts | Package: the dev-server rule |
| `setup/` | every machine | Package without files: its post-install runs `setup.sh install` |

## Packages

Files live in [stow](https://www.gnu.org/software/stow/) packages: a package is a folder whose
`home/` mirrors `~`, with an optional `Brewfile` for its dependencies and an optional
`post-install`. The [dotfiles](https://github.com/mikitahimpel/dotfiles) install links them
on every machine from its package list (Mac: `rules pp rex setup`, pc: `rules pp host
setup`), and updates them with `dotfiles update`. The `setup` package's post-install runs
`setup.sh install`, which keeps only machine state: the Proton Pass token, Tailscale, hosts,
the SSH agent, GitHub, and on hosts systemd and memory limits.

## Install

Two steps on a new machine. First the command below: it downloads agent-box, works out what the machine is, and sets up the machine state, asking only for what it can't find out (logins, tokens, a name). Then the dotfiles, which link the packages and keep agent-box updated:

```bash
gh repo clone mikitahimpel/dotfiles ~/.dotfiles && ~/.dotfiles/install.sh pc   # or mac
```

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
- On the Mac: run the same command again after setting up a new host. It finds the host on Tailscale and adds it to hc (`hc machine add --install`, which also copies hc there), so it shows in the Herdr app.

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
| `--token-vaults A,B,...` | described by role | Vaults to pick when creating this machine's Proton Pass token, e.g. `"Agents,Memoxia"` (see [Secrets](#secrets-one-proton-pass-token-per-machine)) |
| `--autonomous on\|off` | `off` | Claude works without permission prompts inside its sandbox (see below) |

Pass options through the one-liner with `bash -s --`, e.g. `curl … | bash -s -- --autonomous on`. The environment variables `AGENT_ROLE`, `AGENT_HOST`, `AGENT_HOSTS`, `AGENT_USER`, `PASS_VAULT` and `PASS_TOKEN_VAULTS` work too.

## What's in this repo

| File | Runs on | Does |
|---|---|---|
| `install.sh`, `install.ps1` | everywhere / Windows | The one-line installers above |
| `setup.sh` | WSL, Linux, macOS | Checks the setup and fixes whatever is missing. Installs itself as the `agent-box` command. |
| `windows/setup.ps1` | Windows (admin PowerShell) | Power, Wi-Fi, WSL memory, Windows Tailscale and SSH, and the keepalive, watchdog, shutdown and snapshot tasks |
| `rules/` | every machine | Package: rules for agents (`~/.claude/rules/`), `artifact-dir`, the manual `agent-orchestrator` skill; its post-install adds other people's skills and `agent-device` |
| `pp/` | every machine | Package: the `pp` wrapper, the Proton `pass-cli` dependency, and the SSH config that picks the Agents-vault key |
| `rex/` | macOS with [Rex](https://www.superlogical.com/rex) | Package: Rex agent workflow: `rex-agent`, `rex-task`, `conf.d/agents.lua`, the `rex-placement` skill. See [Rex on the Mac](#rex-on-the-mac). |
| `host/` | hosts | Package: the dev-server rule |
| `setup/` | every machine | Package without files: its post-install runs `setup.sh install` |

## The Windows PC in detail

### BIOS (once, by hand)
Gigabyte AORUS AM4:
- **Boot → Boot Option #1:** the Windows drive
- **Boot → Fast Boot:** Enabled (not "Ultra Fast")
- **Tweaker → Advanced CPU Settings → SVM Mode:** Enabled
- CSM disabled (UEFI only), so nothing waits for a key press

### What the Windows installer does
`install.ps1` downloads agent-box to `%USERPROFILE%\agent-box` and runs `windows\setup.ps1 -Install`, which sets:
- sleep on AC power to never (see [Sleep when idle](#sleep-when-idle-opt-in) for the opt-in alternative)
- Wi-Fi adapter never powered off to save power; its Wake on Magic Packet / WoWLAN settings and "allow this device to wake the computer" on, where the driver has them (it prints what it found and the MAC address)
- WSL memory capped at your RAM minus 4GB, plus 8–16GB swap (WSL only takes what it uses; switch agents off before games). `-WslMemoryGB` and `-WslSwapGB` override them.
- Microsoft Defender skips WSL's disk (the distro's folder with `ext4.vhdx`) and its processes (`vmmemWSL`, `wsl.exe`, `wslservice.exe` …). Real-time scanning of them slows every write inside WSL. Files inside WSL are then no longer scanned by Defender.
- **Tailscale for Windows** (winget) as `pc-win` (the WSL host's name plus `-win`), in unattended mode so it runs before anyone logs in
- **OpenSSH Server**: keys only, PowerShell as the shell, port 22 open only to Tailscale and the local network (detected; `-LanSubnet` overrides). The keys are those of every agent-box machine, taken from `github.com/<you>.keys` (each machine uploads its own; see [GitHub](#github)) and written to `C:\ProgramData\ssh\administrators_authorized_keys`, the file Windows reads for administrators.
- Fast Startup off, so startup tasks run and **Agents off** ends when the PC is turned off
- a **watchdog** task that resets Wi-Fi if the internet is down (at boot and every 3 min)
- a **keepalive** task that keeps WSL running from boot, before anyone logs in (at boot and every 5 min)
- a **WSL watchdog** task (every 3 min): if `wsl -d Ubuntu -- true` doesn't answer within 30 s twice in a row, it runs `wsl --shutdown` and starts the keepalive again; if tailscaled inside WSL is down, or up but offline (lost its connection to Tailscale's control server, as after a Wi-Fi reset), twice in a row, it restarts it. It does nothing while **Agents off** is on or a snapshot runs.
- a **power events** task (at boot and hourly) that copies sleep, wake (with its source), shutdown, unexpected-reboot and crash events (Kernel-Power 41/42/107, 1074, 6005/6006/6008, bugchecks) to `C:\ProgramData\agent-box\power-events.log`
- a **remote shutdown** task that turns Windows off after `agent-box off`, or restarts it after `agent-box restart` (checks every minute)
- **Agents off** and **Agents on** shortcuts on the desktop (see [Games](#games-on-the-windows-pc))
- a weekly **WSL snapshot** (`wsl --export`) to `%USERPROFILE%\wsl-backups`, keeping the newest 3. If the PC was off on Sunday, it runs at the next boot. To change it, run `windows\setup.ps1 -Install -BackupDir D:\wsl-backups -BackupKeep 5`.

The tasks that touch WSL run as your Windows user before anyone logs in, so it asks for your Windows password once. A task whose saved password stopped working (you changed the password, or renamed the PC) never starts and leaves no trace but failed logons in the Security log. On a rerun, any of these tasks that hasn't started in the last 15 minutes is registered again, which asks for the password.

It also writes your Windows user and `pc-win` to `~/.config/agent-box/windows` inside WSL, so the Mac can add `pc-win` to its SSH config.

If WSL isn't installed yet, it installs Ubuntu and stops. Reboot, open Ubuntu once to create your Linux user, then run the same command again. It then runs the Linux install inside WSL, restarting WSL once on the way to turn on systemd.

Also check these by hand:
- **BitLocker / Device Encryption:** TPM-only, no PIN.
- **Tailscale admin console:** disable key expiry for `pc-win` too.

The watchdogs and the idle-sleep task log what they do, with timestamps, to `C:\ProgramData\agent-box\agent-box.log`.

### Getting in when WSL is down
`agent-box install` on the Mac adds `Host pc-win` with your Windows user to `~/.ssh/config` (read from the PC while WSL is up, then kept). It also checks over that connection that the keepalive, WSL watchdog, remote shutdown and Wi-Fi watchdog tasks exist and have started in the last 15 minutes. If not, it says which one and asks you to rerun the Windows one-liner.

`ssh pc-win` opens PowerShell on Windows:
```powershell
wsl --shutdown                                          # stop a hung WSL
Start-ScheduledTask 'agent-box WSL keepalive'           # start it again
Get-Content C:\ProgramData\agent-box\agent-box.log -Tail 30       # what the watchdogs did
Get-Content C:\ProgramData\agent-box\power-events.log -Tail 30    # sleep, wake, shutdown, crashes
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 42, 107, 1074, 6008 } -MaxEvents 20 |
    Format-Table TimeCreated, Id, Message -Wrap
Restart-Computer                                        # last resort
```

### Sleep when idle (opt-in)
Off by default: the PC never sleeps. `windows\setup.ps1 -Install -SleepWhenIdle on [-IdleMinutes 30]` (saved for later runs; `-SleepWhenIdle off` undoes it) adds a task that every 10 minutes asks WSL (`agent-box _busy`) whether a CI job (`Runner.Worker`) runs, a Claude agent is working (uses CPU), or the load is high. When nothing is, nobody is logged in to Windows and no SSH session to Windows is open, for `IdleMinutes`, it sleeps (S3; hibernation is turned off in this mode, and the Wi-Fi adapter may power down so it can wake the PC).

It then wakes only from the network: `ether-wake -i br0 <Wi-Fi MAC>` on the router. Wake-on-LAN over Wi-Fi depends on the driver and the router and isn't verified yet, so test it before relying on it: with the mode on, run `rundll32.exe powrprof.dll,SetSuspendState 0,1,0` on the PC, then `ether-wake` from the router. `powercfg /a` must list "Standby (S3)".

### Games on the Windows PC
Before a game, double-click **Agents off** on the desktop. It stops WSL and everything in it (agents, hc, CI runners) and gives its memory back to Windows. The PC then shows as offline in the Herdr app, and CI jobs for it wait in the queue.

Agents come back with **Agents on**, or by themselves the next time the PC is turned on. Claude conversations that were running can be continued with `claude --resume`.

### What the Linux install does on a host
- `/etc/wsl.conf` on WSL: systemd on, Windows drives hidden from agents
- Tailscale with **Tailscale SSH** (opens a login link the first time)
- a Rex server for your account (`~/.local/bin/rex`, started by the `rex.socket` user unit); see [Rex on hosts](#rex-on-hosts)
- what hc needs: linger, so hc's core and its terminals keep running after the last SSH login closes, and `claude` on the login shell's PATH (hc starts programs with the login environment). hc itself arrives from the Mac (`hc machine add --install`); its core runs as a systemd user service the app starts over SSH
- the user's systemd manager (`user@<uid>.service`, where hc's core, its terminals, agents and their builds run) capped at 60% (throttled) / 70% (hard limit) of memory, so they can't take the host down
- the old herdr TUI removed if an earlier agent-box installed it: its server unit, binary, `~/.config/herdr` and its Claude hook. hc and its folders are left alone
- tailscaled restarted after any crash (`Restart=always`, no start limit), protected from the OOM killer, and with more CPU and disk weight than everything else
- memory the kernel reclaims last: 256MB for tailscaled and 20% for `user.slice` (hc and the agents in its terminals). Docker containers and CI runners have none, so they are reclaimed and swapped first. For the 20% to reach hc's units, cgroup2 is remounted with `memory_recursiveprot` at boot (`agent-box-memory-protection.service`).
- **earlyoom**: when memory runs low, it kills one build or test process (`node`, `vitest`, `jest`, `workerd`, `python`, `Runner.Worker`), never tailscaled, sshd, hc (`herdr-core`) or systemd
- self-hosted GitHub runners (`gh-runner*`, `actions.runner*` services), if there are any: moved into their own slice with at most 50% of memory, 1GB of swap, and a lower CPU and disk weight than agents. These are weights, not quotas: CI uses the whole machine when it's idle, and yields when agents or hc need it. A job that needs more memory fails instead of swapping the host to a crawl (there is no MemoryHigh: throttling at it stalled jobs for an hour instead of failing them). Their units stop with `KillMode=mixed`, so a restart can't leave an orphaned listener holding the runner's GitHub session; runners already orphaned that way are restarted. It never creates or removes runners, and restarts them only when no job runs.
- a watchdog for those runners: every minute, the steps of a pull-request job older than 30 minutes are stopped, so the job fails instead of holding a runner for hours. Deploys and manual runs are never stopped (`journalctl -t agent-box-runner-watchdog`).
- Claude Code and the sandbox dependencies (`bubblewrap`, `socat`)
- GitHub: `gh`, git over SSH with this machine's own key, and your git name and email
- Proton Pass CLI and this machine's Proton Pass token (asked once)
- the rules, skills, `pp` and `artifact-dir` come from the `rules`, `pp` and `host` packages,
  which the dotfiles install links

On a client (the Mac) it sets up the same Claude, GitHub and Proton Pass parts (`pass-cli` from Proton's Homebrew tap, whose signed build keeps its Keychain access across upgrades), an always-on SSH agent with the SSH keys in the agents' vault (launchd `dev.agent-box.proton-ssh-agent`, socket `~/.ssh/proton-agents.sock`; point ssh at it with `IdentityAgent`), plus one `Host` entry per host in `~/.ssh/config` (and `<host>-win` for the Windows side of a WSL host) an hc machine per host, which the Herdr app shows, and a Rex host per host that runs a Rex server. A host must be on for the Mac to add it.

## Tailscale admin console (once)
- **Machines → each host → Disable key expiry**
- **Access controls:** make Tailscale SSH accept logins without browser re-checks. The Herdr app reconnects in the background, so `check` mode would break it:
  ```json
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot"] }
  ]
  ```
- **DNS → MagicDNS:** on (it is by default)

## Raspberry Pi (or another Linux host)

Any Linux machine can be a host that works exactly like the PC. It needs a **64-bit OS** (Raspberry Pi OS 64-bit on a Pi 3, 4 or 5); Claude Code and hc have no 32-bit ARM builds. 4 GB RAM or more is comfortable for a few agents.

Run the one-line install on it. Or, if you'd rather not touch the Pi, turn SSH on (Raspberry Pi Imager → *Enable SSH*, or `sudo raspi-config` → Interface Options → SSH) and run from the Mac:
```bash
agent-box add pi@raspberrypi.local --host pi
```
That asks for the Pi's password once, copies agent-box there, runs the host install in your terminal, then adds the Pi on the Mac. Without `--host`, the name comes from the Pi's hostname.

`agent-box off pi` and `agent-box restart pi` act on it directly; that uses `sudo` without a password, which Raspberry Pi OS allows by default.

## Daily use

| You want to | Do this |
|---|---|
| Start | Press the power button. **pc** comes online in the Herdr app in about 1–2 min. |
| Work | Open spaces on **pc** in the Herdr app on the Mac. Agents keep running when the Mac closes. |
| Stop | `agent-box off` from the Mac (Windows shuts down within ~2 min), or a short press of the power button. `agent-box off pi` for the Pi. |
| Restart | `agent-box restart` from the Mac (Windows restarts within ~2 min and comes back on its own). |
| Open an app an agent started | `http://pc:<port>` in the Mac's browser. Agents on hosts are told to bind dev servers to `0.0.0.0` and give you this URL. |
| Change rules or skills | Edit the package, merge, then `dotfiles update` on each machine (`ssh -t pc dotfiles update` from the Mac). |
| Game | **Agents off** on the PC's desktop first; **Agents on** (or the next power-on) brings them back. |
| Updates | Use **Restart** now and then for a full, clean boot. |

## Rex on the Mac

[Rex](https://www.superlogical.com/rex) is a native Mac terminal multiplexer. The `rex` package puts `agents.lua` in `~/.config/rex/conf.d/`, which the dotfiles `init.lua` loads, and `rex-agent` and `rex-task` in `~/.local/bin`. Each host also runs a Rex server, and the Mac adds it as a Rex host reached over SSH, so `rex -S pc new myproject` or the Rex app opens sessions on **pc** (see [Rex on hosts](#rex-on-hosts)). The agent workflow below (`rex-agent`, `rex-task`) still runs agents on the Mac only.

Claude Code reports its state to Rex itself (Program Status Protocol), so tabs show a spinner while an agent works and the session picker marks agents that are blocked or done. The pieces on top:

| Key | Does |
|---|---|
| `shift+cmd+n` | New task: worktree in `~/.worktrees/<repo>/<branch>`, Claude in its own session |
| `shift+cmd+a` | Go to the agent that needs you: blocked first, then finished |
| `shift+cmd+h` | Search agent history (`agent-history-rex`, else `agent-history browse`) |
| `shift+cmd+u` | Token usage dashboard for the focused agent (`agent-tokens`) |

All four are also in the command palette under **Agents**. A shortcut recorded in the app with **Change Shortcut…** overrides these.

From a shell or an agent: `rex-agent list|get|read|prompt|send-keys|wait|focus|open` and `rex-task new|rm` (`--help` on each). The `rex-placement` skill uses them; inside the Herdr app, `herdr-placement` (in the herdr-setup repo, with the Herdr layout) applies instead.

Turn on **Remote Control** in Rex's settings (Rex Server) so commands run from a terminal, like `rex-task` or a history resume, can switch the app to the new session. Keys work without it.

### Rex on hosts

On a host, `agent-box install` installs Rex's Linux server for your account only (`curl … install.sh | sh -s -- --user --channel preview`, no sudo) into `~/.local/bin/rex`, and `rex server install` enables the `rex.socket` user unit, so the server starts on the first connection and keeps running after logout (linger). It needs no port: the Mac connects over the same SSH as hc.

On the Mac, `agent-box install` adds each host that has a Rex server with `rex hosts add <host> ssh://<user>@<host>`. Then:

```sh
rex -S pc ls
rex -S pc new myproject
```

hc and the Herdr app keep working beside it, so you can move over gradually. Rex on Linux is still in testing.

## Autonomous mode

`agent-box install --autonomous on` lets Claude work without stopping for approval, on any machine and OS. It's saved, so later runs keep it on. It merges this into `~/.claude/settings.json`, leaving your other settings alone and keeping a backup in `settings.json.bak`:

- **Sandbox on:** Bash commands run inside Claude's sandbox (bubblewrap on Linux/WSL, built in on macOS) and need no approval.
- **No escape:** commands can't fall back to running outside the sandbox, and Claude refuses to start if the sandbox is unavailable instead of silently running without it.
- **Edits auto-approved:** file edits don't ask (`acceptEdits`).
- **Network allowlist:** sandboxed commands may reach the hosts in [setup/allowed-domains.txt](setup/allowed-domains.txt) (GitHub, npm, PyPI, crates, Go, Proton) without asking. Any other host still prompts once, so add the ones you need to the file, merge, and run `dotfiles update`.

`--autonomous off` stops managing these settings but doesn't remove them. Undo with `/sandbox` inside Claude or by restoring `settings.json.bak`.

## GitHub

Every machine pushes over SSH with its **own** key, so if one machine is lost you delete only its key under **GitHub → Settings → SSH keys** (titled `agent-box <hostname>`). Each part is checked first and left alone if it already works:

1. `gh` installed and logged in (`gh auth login`, browser or device code).
2. `gh` set to use SSH for git, so `gh repo clone` gives SSH remotes.
3. `ssh -T git@github.com` authenticates. If it already does (any key, ssh-agent, Keychain), nothing changes. Otherwise it uses `~/.ssh/id_ed25519` (or `id_ecdsa` / `id_rsa`), creates an ed25519 key without a passphrase if there is none, and uploads it with `gh ssh-key add`. Uploading needs the `admin:public_key` scope; `gh` asks for it once if your login lacks it.
4. `git config --global user.name` and `user.email`, only if unset: your GitHub name and your `…@users.noreply.github.com` address.

The keys have no passphrase so agents can push with nobody at the keyboard. They are deliberately not kept in Proton Pass: the stored agent token would unlock them just as easily, and a per-machine key is quicker to revoke than a shared one.

## Secrets: one Proton Pass token per machine

Each machine has exactly one Proton Pass login, shared by `pp` (agent-box) and every project tool that reads secrets (for example memoxia's `memoxia-secrets`):

- **One token per machine:** a scoped personal access token that sees only the vaults that machine needs, is read-only by default, and logs every read with a reason.
- **One session:** pass-cli's default session directory. Nothing sets `PROTON_PASS_SESSION_DIR`; if you export it yourself, it is respected.
- **One local key (Linux, WSL):** pass-cli encrypts its session with a local key. By default it keeps that key in the kernel keyring, which is separate for every login session, so hc terminals and SSH logins would fight over the one session (`file is not a database`). agent-box sets `PROTON_PASS_KEY_PROVIDER=fs` in the login profile and in `pp`, so pass-cli keeps the key in a file instead. macOS keeps the Keychain.

| | Session (pass-cli default) | Token |
|---|---|---|
| macOS | `~/Library/Application Support/proton-pass-cli` | Keychain, service `proton-pass-token`, account `default` |
| Linux, WSL | `${XDG_DATA_HOME:-~/.local/share}/proton-pass-cli` | libsecret (`secret-tool`, `service=proton-pass-token account=default`) when it works, else `${XDG_CONFIG_HOME:-~/.config}/proton-pass/token` (mode 600, folder 700) |

Which vaults the token covers depends on the machine:

| Machine | Vaults |
|---|---|
| Your Mac (client) | `Agents` and your project vaults, release vaults included (e.g. `Memoxia`, `Memoxia Release`) |
| A host (the PC, a Pi) | `Agents` and your project dev vaults (e.g. `Memoxia`), **never** release vaults |
| An external contributor | only the project's vault (e.g. `Memoxia`) |

1. In **pass.proton.me → Settings → Access tokens → New token**, create the machine's token: named after the machine, expiry 1 year, the vaults above, **Use for AI agent** on. The install prints the vaults to pick; `--token-vaults "Agents,Memoxia"` makes it name exact vaults.
2. The install asks for the token once and stores it as above.
3. `pp` wraps `pass-cli` from your PATH. Agent sessions last 2 hours; when `pass-cli info` fails, `pp` logs back in with `PROTON_PASS_PERSONAL_ACCESS_TOKEN=<token> pass-cli login`. Every read is labelled with `PROTON_PASS_AGENT_REASON` (default `agent on <hostname>`).

Agents use it like this (the secrets rule in `~/.claude/rules/` tells them to):
```bash
# .env
API_KEY=pass://Agents/<item>/<field>

pp run --env-file .env -- npm test
```

Check what agents read with `pass-cli agent monitor <token-name>` (logged in as yourself) or under **Manage vault access** in the web app.

**Moving from older agent-box versions:** they kept the token in the Keychain item `proton-pass-agent` (macOS) or `~/.config/pass-agent/token` (Linux) and their own session in `~/.local/state/pass-agent`. `agent-box install` moves that token into the new storage, deletes the old item, and removes the old session. The moved token still sees only the vaults it was created for (usually just `Agents`), so replace it as below if the machine needs more.

**Replacing the token** (yearly, or to change its vaults): create the new token, delete the stored one and the session, then rerun the install:
```bash
security delete-generic-password -s proton-pass-token -a default        # macOS
secret-tool clear service proton-pass-token account default             # Linux with libsecret
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/proton-pass/token"             # Linux without
pass-cli logout
agent-box install
```

**Note:** anything running as your user, agents included, can read the stored token and use the session. Only give a machine's token the vaults you're fine with an agent on that machine seeing. If you log in to pass-cli as yourself on a machine, that login is the machine's session too, so `pp` and project tools use it until you log out.

## Restoring WSL from a snapshot

If an agent breaks the Ubuntu install, in PowerShell:
```powershell
wsl --unregister Ubuntu                      # deletes the broken install
wsl --import Ubuntu $env:USERPROFILE\wsl\Ubuntu $env:USERPROFILE\wsl-backups\Ubuntu-<date>.tar
```
Then set your default user again in WSL (`/etc/wsl.conf` → `[user]` `default=<you>`) and run `wsl --shutdown`. The snapshot includes everything in Ubuntu: projects, tokens and logins.

## Acceptance test

Repeat 5–10 times: shut the PC down, press the power button, don't touch it. It passes if **pc** comes online in the Herdr app on your Mac every time and you can open a space on it and run `claude`.

If it doesn't come online:
1. `ssh pc-win`: is Windows up? Read `agent-box.log` and `power-events.log` (see [Getting in when WSL is down](#getting-in-when-wsl-is-down)), and check that the `WSL keepalive` task is running.
2. Inside WSL: `agent-box` (check mode) and `hc server status`
3. On the Mac: `hc machine ls` and `ssh pc true`

## Known limits

- `install.ps1` and `windows/setup.ps1` are written for Windows PowerShell 5.1 but haven't been run on a real machine yet. Read their output before trusting them.
- Host discovery logs in to each new Linux peer with Tailscale SSH to look for agent-box. A peer whose user isn't among the tried ones is skipped; add it with `--host user@name`.
- `pp` and project tools assume `pass-cli info` fails when the session has expired. Run `pp info` again 2 hours after setup to confirm the automatic re-login.
- If you change your Windows password, run the Windows one-liner again; it registers the tasks that stopped starting.
- `wsl --export` of a running distro and the shutdown task's call into WSL are untested on a real PC. Check Task Scheduler's "Last Run Result" after the first week.
- Snapshots are full copies of Ubuntu and can be large. Point `-BackupDir` at a drive with room.
- Windows Tailscale and SSH, the WSL watchdog, the power events log, the Wi-Fi wake settings and sleep when idle are written from the documentation and haven't run on the PC yet.
- On the very first install the Windows SSH keys are skipped, because they come from `gh` inside WSL, which isn't set up yet. Run the Windows one-liner again afterwards, or pass `-GitHubUser <login>`.
