# SwitchShelf development
- Native SwiftUI macOS app (macOS 26+), Swift 6 concurrency. Design reference: output/design-demos/03-liquid-glass.png.
- Read Docs/ARCHITECTURE.md and Docs/DEVELOPMENT_PLAN.md before editing.
- Source game files under /Volumes/switch 游戏包 are read-only. Never move, rename, delete, install or upload them. Avoid full hashing/copying of large SMB files.
- Device testing is read-only USB discovery / MTP enumeration until the coordinator explicitly schedules a reviewed installation test. Never delete device objects, modify saves or format storage.
- Do not fabricate device results, installation states, package identity or metadata. Unknown remains unknown. Filename identity is a candidate.
- Each worker owns only the paths in its task. Do not edit Package.swift or shared domain models without coordinating. Commit your finished changes on your branch. Never merge other branches, change global settings, or spawn additional agents.
- Report tests, files, commit and limitations via the injected Orca orchestration lifecycle. Read coordinator messages at checkpoints.
- If a .codegraph/ directory exists, use CodeGraph before grep/find or reading code; otherwise skip it. Do not index automatically.

每次完成一个功能开发，都提交一次 commit