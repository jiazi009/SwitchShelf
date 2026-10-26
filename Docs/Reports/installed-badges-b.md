# Installed-game indicator — selected concept B

The user selected B from the three concepts generated from the live app capture on 2026-10-26. Grid cards now show a small mint checkmark and “已安装” directly above the white cover title, without a capsule. List rows use the same checkmark and text beside their title.

## Implementation

- `Sources/SwitchShelfApp/GameViews.swift`: integrate the title into the cover's lower caption area, put installed state above it, reuse `InstalledGameLabel` in grid/list, preserve the existing selection, context menu, offline and identification controls, and expose assessment state to accessibility. The indicator's tooltip retains the assessment explanation, including any uncertain update/DLC details.
- `Sources/SwitchShelfApp/CoverPalette.swift`: reuse the bounded artwork-color sampler from the original checkout's current cover presentation. This is necessary because this worktree's committed base predates the live app's integrated title area. No other uncommitted work from that checkout was imported or changed.
- `output/design-demos/installed-badges/implementation/`: actual SwiftUI fixture captures in light and dark appearance.

Both presentations show the indicator only for `assessment.state == .installed`. Assessment continues through the existing `AppModel` and `InstallationAssessor`; no filename candidate, partial, missing, expired-session or unknown state is promoted. Shared domain models and `Package.swift` are unchanged.

## Validation

- `swift build --product SwitchShelf`: passed.
- `swift test --filter SwitchShelfDomainTests`: all 8 existing tests passed, including positive evidence, candidate identities, old sessions, partial content and incomplete inventory.
- `python3 scripts/build-app.py --icon /Users/jiazi/Desktop/SwitchShelf/Assets/AppIcon.png`: release app/probe packaging and strict ad-hoc signature verification passed. The existing chosen icon is used in the local bundle only.
- Rendered production `GameCard`, `CoverArtwork` and `GameListRow` using an isolated temporary harness, synthetic artwork and a fixture inventory. Checked light/dark appearance, 200pt cards, minimum 120pt cards, two-line long titles, missing covers and list rows. Only the installed fixture displays the indicator; unknown, partial and not-installed fixtures do not. The harness asserted the actual model assessment for all four states.
- Fixture rendering used a separate defaults suite, application state/cache directory and generated local artwork. Remote cover loading was disabled only in the temporary harness. App bootstrap, NAS scanning, USB discovery, inventory requests and installation were never called.

## Scope and limits

The screenshots are actual component renders with explicitly synthetic data, not physical-device evidence. The existing strict package verification requirement still applies: real filename-only candidates remain unknown. No real-device state was read or changed. The original checkout and running app remain independent of this branch.

The local runnable bundle is `build/SwitchShelf.app`. The bundle was packaged and verified without launching production bootstrap or replacing the running application.
