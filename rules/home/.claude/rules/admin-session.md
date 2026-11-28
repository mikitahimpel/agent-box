## Admin session (user only)
- The shared Proton Pass session is the agent session. It is scoped to the "Agents" vault.
- A second Proton Pass session in `~/.config/proton-pass-admin` belongs to the user.
  It reaches the "Admin" vault (SSH keys, root logins, full-rights API tokens, recovery codes).
- Never use, read or point PROTON_PASS_SESSION_DIR at the admin session, and never read the
  Admin vault.
- When a step needs the admin session, write the command out and ask the user to run it
  with `! PROTON_PASS_SESSION_DIR=~/.config/proton-pass-admin pass-cli ...`.
- Admin SSH keys are loaded into the macOS ssh-agent with a confirm prompt (`admin-keys`).
  Never approve, bypass or reload them on the user's behalf.
