## Dev servers
- This machine is reached over Tailscale by the name in AGENT_HOST in
  `~/.config/agent-box/config`. Bind dev servers to 0.0.0.0 (for example `--host 0.0.0.0`)
  so they open from the user's other machines.
- When a server is up, give the user its URL as http://<that name>:<port>.
