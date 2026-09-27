# Caddyman Agent Guide

## Product boundaries

- Caddyfile is the only source of truth for reverse proxy sites. Do not add a site database or persist a second copy of site configuration.
- Preserve every Caddyfile byte outside the specific site block or top-level import directive under review byte-for-byte. Editing or deleting any site block, including a legacy block outside Caddyman's marked region, requires a complete diff, selected-binary validation, backup, and explicit confirmation.
- Top-level Caddyfile `import` directives may be added, edited, or deleted with the same diff, validation, backup, and confirmation flow. Resolve paths relative to the importing Caddyfile, display direct imported site blocks read-only, and do not expand imports inside imported files.
- Never expose DNSPod credentials in command arguments, launchd plists, logs, diagnostics, or ordinary preferences.
- Manage only the Caddy process and LaunchAgent created by Caddyman. Do not install, replace, or take over another Caddy instance.
- Keep Admin API access on loopback.

## Workflow

- If a local `CADDYMAN_IMPLEMENTATION_PLAN.md` is available, read it before starting a phase. The plan is kept outside the public repository.
- Work on one small slice at a time and inspect `git status` before editing.
- Keep implementation logic separate from SwiftUI and make external operations injectable.
- Preserve copyright/license headers when adapting Caddock code; record each reuse in `docs/REUSE_AUDIT.md`.
- Do not copy Caddock branding, app identity, or unrelated local-vhost functionality.
- Show a complete Caddyfile diff and validate a candidate with the selected Caddy binary before applying it.
- Do not perform real DNS changes, production certificate issuance, or machine-level service changes without an explicit request.

## Project settings

- macOS deployment target: 15.0 or later.
- Bundle identifier: `com.blood.caddyman`.
- App style: menu-bar-first; keep `LSUIElement` as the initial status-bar identity, show a Dock icon while regular app windows are open, and return to accessory mode after the last regular window closes.
- No database or third-party UI framework.
