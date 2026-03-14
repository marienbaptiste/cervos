# Cervos — Claude Code Rules (Router)

This is the top-level rules file for Cervos, an ambient AI assistant.
It routes to domain-specific rules in `.claude/rules/`.

## Project overview

Cervos is a privacy-first ambient AI assistant spanning:
- Wearable layer (Even Realities G2 glasses, R1 ring, nRF52840 dongle, BLE earbuds)
- Mobile gateway (Flutter app on Samsung Galaxy S26 Ultra)
- AI server (Mac Studio with Apple Silicon, 96GB+ unified memory)
- Secure transport (nginx mTLS over Tailscale mesh)

## Architecture spec (Notion)

The canonical architecture spec lives in Notion. Always fetch the relevant page before implementing:
- **Main spec**: page ID `323c6ebc177f8110b5d6f0a1a0c92720`
- **Changelog / task queue**: page ID `323c6ebc177f81ca8680ed6e1e0faaa4`

When the user says "check the spec" or "check Notion", fetch the changelog page first.

## Domain rules

Route to the appropriate rules file based on what you're working on:

| Domain | Rules file | When to use |
|--------|-----------|-------------|
| Mobile app | `.claude/rules/mobile.md` | Flutter app, BLE, audio, MCP server, journal |
| Server | `.claude/rules/server.md` | OpenClaw, nginx, Docker, persistence, meeting STT |
| Firmware | `.claude/rules/firmware.md` | nRF52840 dongle, Zephyr RTOS |
| Design system | `.claude/rules/design-system.md` | Tokens, components, UI generation |
| Infrastructure | `.claude/rules/infrastructure.md` | Tailscale, mTLS, CI/CD, scripts |
| Models | `.claude/rules/models.md` | Model cascade, cloud routing, STT |

## Security rules

- **This repo is PUBLIC.** Never commit API keys, auth tokens, or secrets.
- Secrets go in `config.yaml` (gitignored) — only `config.example.yaml` is tracked.
- Certificates are generated locally via `scripts/generate-certs.sh` — never committed.
- The `.gitignore` blocks `config.yaml`, certs, and data directories.
- If you see a secret in any file, flag it immediately.

## Workflow

1. Check the Notion changelog (`323c6ebc177f81ca8680ed6e1e0faaa4`) for pending tasks
2. Read the relevant Notion spec page for full context
3. Read the relevant `.claude/rules/` file for tech stack and conventions
4. Implement changes
5. Run CI checks (`ci.yml`, `design-lint.yml`)

## Spec sync rules (IMPORTANT)

**Notion is the source of truth.** When the user changes the architecture, design, or behavior of any part of the system — even through conversation — the following MUST happen:

1. **Update the relevant Notion spec page** via the Notion MCP tools to reflect the change
2. **Append a new changelog entry** to the Spec Changelog page (`323c6ebc177f81ca8680ed6e1e0faaa4`) with:
   - Entry number (increment from last)
   - Date
   - Status: `TODO` (or `DONE` if implemented in the same session)
   - **What changed**: describe the spec change
   - **What to build**: checklist of code changes needed
   - **Priority**: which implementation phase it belongs to
   - **References**: link to the updated Notion spec page(s)
3. **Then implement** the code changes in the repo

This ensures the Notion spec, the changelog, and the codebase stay in sync. Never make architectural changes to code without updating Notion first.

### What counts as a spec change
- Adding, removing, or renaming a component, service, or tool
- Changing how data flows between machines (phone, Mac Studio, work PC)
- Changing model routing, permission tiers, or security boundaries
- Changing the design system (tokens, components, elevation)
- Adding new hardware or firmware functionality
- Changing the repo structure

### What does NOT need a spec update
- Bug fixes that don't change architecture
- Implementation details within an existing spec (e.g., variable names, internal refactors)
- Adding tests or documentation for existing behavior
