# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

SwitchShelf is for the author and for other people in the same situation: a local library of Nintendo Switch packages, a Switch running custom firmware and reached through sphaira or DBI, and a Mac used to manage both.

## Product Purpose

SwitchShelf is the Mac app for five equal jobs: browse the local game library, install chosen base, update, and DLC content, manage files on the console, view and download album screenshots, and maintain the library on this Mac.

Success means those jobs can be done in one local app, in Chinese, against that person's own files and console.

## Positioning

The local package library and the connected console stay in one Mac app, so installation and device jobs refer to the same files and the same session. It serves people who already hold the packages and the hardware.

## Operating Context

Native macOS 26 app on Apple Silicon, built with SwiftUI and Swift 6. The interface is Chinese. The window is designed around 1280×820 points, with a minimum of 960×640. The installation staging sidebar is 320 points at that design size and narrows, down to 220, when the library would otherwise be squeezed. Album preview does the same from a 300-point design width.

The known library source in this project is the NAS mount `/Volumes/switch 游戏包`. App data lives under Application Support/SwitchShelf.

USB inventory and installation use libusb. Recognized inventory storages are sphaira `Games` and DBI `Installed games`. OpenMTP has to be quit before SwitchShelf reads the console. ImageCaptureCore and libmtp are retired connection routes.

无线连接 is a separate DBI FTP client for SD file access on port 5000. Port 6000 is refused. A directory listing is directory text, not an installed-game inventory. That client has fixture and loopback coverage only.

## Capabilities and Constraints

Equal jobs, confirmed 2026-10-29:

- **游戏库.** Scan local folders, show a grid or list, search and filter, and keep filename-derived identities as candidates.
- **安装.** Stage base, update, and DLC, then send them serially over sphaira MTP after explicit confirmation. A user-authorized Goose Game base and update reinstall was recognized after the device refreshed its Games list.
- **文件.** Browse reported USB storages and upload or download individual files. Ordinary uploads use the writable microSD projection.
- **截图.** Read album screenshots from recognized album roots and download them locally. Downloads do not overwrite existing local files or delete device files.
- **维护.** The current page covers library stats, source availability, cache, and rescanning.

Current behavior, left unlocked as permanent product rules on 2026-10-29:

- Game source files stay untouched by scanning. User-authorized installation streams package bytes without modifying the source.
- Transfer completion and installation stay separate observations. Unknown stays unknown. A filename identity is a candidate.
- There is no account and no game-download service. Index, queue, and cache stay on the Mac.
- The app handles one console session at a time. Multi-device use is undecided.
- Installation execution uses sphaira MTP. The DBI Backend path is deferred.
- The shipping build is a locally signed 0.3.4 release candidate. Developer ID signing and notarization are not done. Public distribution is undecided.
- The interface follows light and dark appearance, and current screens account for keyboard access and reduced motion.

无线连接 is a present page. It was not named as one of the five equal jobs.

The original development document describes an SD-card component upgrade workflow. The current 维护 page does not do that work, and that workflow is not a current capability.

Open:

- Whether read-only sources, separate transfer and install evidence, local-only data, single-device use, or local-only distribution become permanent rules.
- Whether the SD-card upgrade workflow returns.
- Hardware coverage beyond the documented Goose Game reinstall, and a real Switch FTP session.

## Brand Commitments

The product name is SwitchShelf. The sidebar subtitle is 本地游戏库. Chinese is the default interface language, and that default is binding.

## Evidence on Hand

- Product and implementation baseline: `SwitchShelf_开发文档.md`, `Docs/ARCHITECTURE.md`, `Docs/DEVELOPMENT_PLAN.md`, `README.md`.
- Physical install evidence: `Docs/Reports/release-review-2026-10-29.md` and `Docs/Reports/release-review-2026-10-29-evidence.json`. Local logs under `output/diagnostics/` are gitignored.
- Repo-selected visual reference, with no DESIGN.md yet: `output/design-demos/03-liquid-glass.png`. The bundle icon is concept 08 at `Assets/AppIcon.png`. Other concepts are in `Assets/AppIconConcepts`.
- Native layout snapshots: `output/ui-review/native-staging/`.

Device results, installation states, package identity, and metadata stay limited to what a session actually observed. Wi-Fi FTP has no physical Switch session on record. The 2026-10-29 storage diagnostic is not fully shown in the device UI. Virtual Games, Mounts, and DevNull capacities are not physical disks.

## Product Principles

1. Build for people who already have a local Switch library and a console, including people other than the author.
2. Treat the game library, installation, device files, album screenshots, and Mac-side library maintenance as equal jobs.
3. Keep the interface in Chinese by default.
