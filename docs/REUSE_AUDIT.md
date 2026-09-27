# Caddock Reuse Audit

## Project decisions

- The implementation plan records that the user confirmed the Caddock author's permission to copy and modify code for this non-commercial project.
- Caddock may be used as an implementation reference; existing copyright and license notices must remain with any adapted source.
- Caddyman must use its own name, bundle identifier, icon, and visual identity.
- User-confirmed Caddyman bundle identifier: `com.blood.caddyman`.
- No Caddock source code or brand assets were copied into Caddyman in Phase 0. Phase 1 UI/lifecycle adaptations are listed below.

## Source version

- Local reference: a Caddock source checkout used during development.
- Source identity and build details: macOS 15+, Swift 5, menu-bar-first app; see the reference repository's `README.md` and `Caddock.xcodeproj`.
- The local copy has no root `LICENSE` file. Per the project plan, this does not block reuse under the permission already confirmed by the user.

## Candidate references

| Caddock source | Potential Caddyman use | Status |
|---|---|---|
| `Caddock/App/CaddockApp.swift` | Menu bar scene and settings scene patterns | Reference only |
| `Caddock/App/AppDelegate.swift` | App lifecycle and accessory behavior | Reference only; do not copy unrelated services |
| `Caddock/Features/MenuBar/MenuBarView.swift` | Menu layout and action patterns | Reference only; replace vhost model and labels |
| `Caddock/Features/MenuBar/MenuActionRow.swift` | Accessible menu action row | Reference only |
| `Caddock/Features/Settings/SettingsView.swift` | Settings navigation/layout | Reference only |
| `Caddock/Caddy/CaddyProcessController.swift` | Process lifecycle patterns | Reference only; redesign around the Caddyman LaunchAgent boundary |
| `Caddock/Caddy/CaddyAdminClient.swift` | Loopback Admin API client patterns | Reference only; keep loopback-only |
| `Caddock/Features/Logs/LogsView.swift` and `SiteLogStreamer.swift` | Log presentation/streaming patterns | Reference only; add secret redaction |
| `Caddock/Certificates/CertificateStatusChecker.swift` | Certificate display/checking patterns | Reference only; query the served TLS certificate |
| `CaddockTests/CaddyConfigBuilderTests.swift` and `VhostValidatorTests.swift` | Test style and validation ideas | Reference only; replace local-vhost assumptions |

## Reuse ledger

Append an entry whenever Caddock implementation is copied or materially adapted:

| Caddock source | Caddyman destination | Change summary | Original notices retained |
|---|---|---|---|
| `Caddock/Support/AppWindowPresenter.swift` | `Caddyman/Support/AppWindowPresenter.swift` | Adapted accessory/regular activation policy, menu-panel dismissal, and focus retry for Overview and Settings only. | Source had no copyright/license header. |
| `Caddock/App/AppDelegate.swift` | `Caddyman/App/CaddymanAppDelegate.swift` | Adapted window-close observation and Dock visibility lifecycle; omitted Caddock setup, service, login-item, and helper behavior. | Source had no copyright/license header. |
| `Caddock/Features/MenuBar/MenuActionRow.swift` | `Caddyman/Features/MenuBar/MenuActionRow.swift` | Adapted compact icon row, hover feedback, and hit area; labels use Caddyman localization keys. | Source had no copyright/license header. |
| `Caddock/Features/Settings/SettingsComponents.swift` | `Caddyman/Features/Settings/SettingsFormStyle.swift` | Adapted grouped form, hidden scroll background, and compact sizing. | Source had no copyright/license header. |
| `Caddock/Features/Settings/SettingsView.swift` | `Caddyman/Features/Settings/SettingsView.swift` | Adapted grouped-pane layout, then replaced tab navigation with a Caddyman-specific sidebar and task pages; removed unrelated Caddock panes. | Source had no copyright/license header. |
