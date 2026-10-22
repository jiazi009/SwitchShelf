# UI worker report — opencode

Commit: `792db23` (`feat(ui): implement native SwiftUI library, device and queue surfaces`) on `jiazi009/switchshelf-ui`.
Owned scope: `Sources/SwitchShelfApp/**`, this report. `Package.swift` (pre-existing local tools-version edit) and shared modules are not committed.

## Files

- `SwitchShelfApp.swift` — `@main`, 1280×820 default window, hidden title bar, content-min-size resizability, commands (open folder ⌘O, rescan ⌘R, search ⌘F, select all, grid/list ⌘1/⌘2, inspector ⌥⌘I, queue ⇧⌘U, device ⌘3, maintenance ⌘4). Replaces `main.swift`.
- `AppModel.swift` — MainActor `@Observable` model: bootstrap loads cache first, persists/again merges the initial read-only NAS source `/Volumes/switch 游戏包`, scans off the main actor via `LibraryScanner`, persists through `LibraryRepository(databaseURL:)`, tracks first-seen, source bookmarks/availability, selections, plan, notices and device/inventory state. Inventory reads use `BoundedInventoryReader` (separate process); `DeviceService.discover()` only supplies USB candidate descriptors.
- `Stores.swift` — JSON persistence for the editable installation plan and first-seen dates in `Application Support/SwitchShelf`.
- `AppTypes.swift`, `Components.swift`, `Theme.swift` — filters/sorting/plan presentation, badges/notices/empty states/device pill/inspector toggle, adaptive light/dark palette, window wash and `contentMinSize` enforcement.
- `RootView.swift`, `SidebarView.swift`, `LibraryView.swift`, `GameViews.swift`, `InspectorView.swift` — split view, frosted sidebar and header, all/recent/unidentified/source selections, search, grid/list, content-type and installation filters, adjustable cover size, ⌘/⇧ multi-select, cover cache with native generated placeholders that display the title, single/multi inspector with local content rows, per-source status, reveal in Finder, copy Title ID/path, add-to-queue.
- `DeviceView.swift` — real read-only discovery, DBI/MTP instructions, inventory display and filtering; read enabled only for a single `057e:201d` MTP candidate, the read performs the handshake.
- `QueueView.swift` — persistent editable local plan (target SD/机身, per-content inclusion, note), sizes, explicit disabled execution with reason.
- `MaintenanceView.swift` — diagnostics, balanced 3-column stats, source/cache state, issue list, Finder/clipboard actions.
- `SettingsView.swift` — refresh-on-launch preference.

## Checks

- `swift build` in the UI worktree with temporary, uncommitted service stubs: **passed**. Stubs (`Sources/SwitchShelfLibrary/TEMPUIStubs.swift`, `Sources/SwitchShelfDevice/TEMPUIStubs.swift`) and the temporary `SnapshotProbe`/fixture hooks were deleted before commit.
- Integration build in a throwaway clone of `main` (real `LibraryScanner`, `LibraryRepository`, `DeviceService`, `BoundedInventoryReader`, `InstallationAssessor`) with only `Sources/SwitchShelfApp/**` copied in: **`Build complete!`** — the UI compiles against the integrated services and domain.
- Offscreen `cacheDisplay` snapshots (temporary probe, since removed) at 1280×820 and 960×640: library grid, empty state, queue, device, maintenance, list and narrow layouts; also dark appearance. No crash reports for those runs after the layout fixes (root min-frame removed, filter-pill `fixedSize` removed).
- Device/NAS behavior was not exercised with real hardware in this worker: no install, no writes, no device object mutation; inventory is only displayed from a real read result.

## Behavior decisions

- Installation state delegates to `SwitchShelfDomain.InstallationAssessor`: base content is required, update/DLC-only matches never prove installed, unverified filename identity stays unknown, and only an inventory read from the current candidate session is used. Absence is treated as evidence only when the inventory is complete and identities are known.
- `discover()` never reports `.ready`; the UI therefore gates reads on exactly one `057e:201d` MTP candidate and lets the read perform the handshake. Disconnect, candidate change or read failure clears the inventory; discovery and reads cannot run concurrently.
- Partial scans (`result.issues` non-empty) merge what was read and keep previous cache entries for unread files instead of treating the result as authoritative; the UI states that the scan was incomplete.
- Execution in the queue remains disabled with a visible reason; no progress or success state is simulated. Missing covers use generated gradient/typography placeholders with the title, never generated artwork.

## Remaining limitations

- The macOS session was locked during the final pass, so live window interaction (hover, menus, glass/material rendering, actual button fills) could not be visually confirmed; offscreen captures do not render system materials or some control chrome. Glass surfaces and the solid primary buttons follow the design intent but need one live visual check.
- The inspector is derived from `inspectorPresented && isLibraryPage`, so it closes on non-library pages and restores on return; during the page transition the closing panel can briefly animate over the new page.
- List selection uses a custom in-row highlight in addition to `List(selection:)`; verify against any native highlight once the app can be inspected live.
- Hardware verification (actual DBI MTP handshake, partial inventory, NAS partial-enumeration) is left to the coordinator's device test schedule; the UI is read-only here.
