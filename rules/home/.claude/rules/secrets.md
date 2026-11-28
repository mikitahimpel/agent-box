## Secrets
- Secrets live in Proton Pass vault "Agents". Never hardcode, log or print them.
- Put references in .env files: `API_KEY=pass://Agents/<item>/<field>`
- Run commands that need secrets via: `pp run --env-file .env -- <command>`
- Set PROTON_PASS_AGENT_REASON to a short reason before reading secrets.
- This machine has one Proton Pass session and token, shared by pp and project tools.
  Don't set PROTON_PASS_SESSION_DIR, log in or out, or read the stored token.
