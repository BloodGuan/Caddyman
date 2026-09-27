# Caddyman

Caddyman is a native macOS menu bar app for managing one local Caddy instance. It focuses on reverse-proxy sites and uses the selected Caddyfile as the single source of truth.

## Project status

Phases 0–6 are implemented, including the Phase 5.5 navigation and service-control changes. Caddyman can inspect a selected Caddy binary and DNSPod module, preview and apply Caddyfile migrations, manage marked reverse-proxy sites, validate and safely reload its own Caddy process, and store DNSPod credentials in Keychain or explicitly selected plain text. The main window contains Overview, Sites, Caddy, Startup, DNSPod, and About. English and Simplified Chinese are included, selected from the system language.

Phase 6 lets Caddyman open at login and optionally start Caddy with the app. On normal quit, Caddyman stops the Caddy process it owns. An independent LaunchAgent from an earlier build can be detected and explicitly removed, but new independent Caddy services are no longer installed through the app. The application refuses to take over a Caddy process with unknown ownership. A real login acceptance test has not been run. Phase 5's real staging certificate acceptance has not been run; it requires a public test hostname, DNSPod credentials, and an explicit test that can create DNS challenge records.

## Requirements

- macOS 15 or later
- Xcode with Swift support
- An existing Caddy binary; DNSPod sites require a build that includes `dns.providers.dnspod`

## App identity

- Bundle identifier: `com.blood.caddyman`
- Minimum macOS version: 15.0
- Menu-bar-first app with `LSUIElement` startup identity and a Dock icon while regular windows are open
- App icon and English/Simplified Chinese String Catalog are included
- Dock icon is shown only while regular Caddyman windows are open

## Build

Open `Caddyman.xcodeproj` in Xcode and use the shared `Caddyman` scheme. The app and unit-test target are configured for local development signing. The latest locally packaged Release app is in `dist/Caddyman.app`. Xcode's own build output uses its configured DerivedData location; `build/` and `dist/` are ignored by Git.

To try it, launch `dist/Caddyman.app`, open Settings, select a Caddy executable and a Caddyfile, then review the proposed site diff before validating and applying it. Startup settings separately control opening Caddyman at login and starting Caddy with Caddyman. Starting Caddy may request certificates or create temporary DNS challenge records. Caddyman manages only its own session process; it can detect and remove its earlier independent LaunchAgent.

## Repository layout

- `Caddyman/`: app source, resources, Caddy integration, and SwiftUI features
- `CaddymanTests/`: unit tests
- `Caddyman.xcodeproj/`: Xcode project and shared scheme
- `docs/`: source reuse audit
- `dist/`: local app package, excluded from Git

## Product rules

- Site configuration lives in the Caddyfile; Caddyman does not keep a parallel site database.
- Caddy handles certificate issuance and renewal.
- Keychain secrets must not be written to the LaunchAgent plist or diagnostics.
- Caddyman only controls a service instance and LaunchAgent it created.
- The current session controller requires Caddy's Admin API on the default local port 2019. Candidate validation rejects remote, disabled, or custom Admin API listeners, and the Caddy child does not inherit `CADDY_ADMIN`.
- Normal app quit stops Caddyman-owned Caddy. A previously installed independent LaunchAgent must be removed before enabling app-managed startup; its removal preserves the Caddyfile and certificates.
- Certificate inventory and full log browsing are planned for Phase 7; the current Overview shows a redacted certificate status and latest runtime log line.

See [`docs/REUSE_AUDIT.md`](docs/REUSE_AUDIT.md) for reuse provenance. The implementation plan is kept locally and is not part of the public repository.
