# DBI 647-zhcn connection checkpoint

User-reported version: DBI 647-zhcn; firmware display 19.0.1e. This is a user report, not an automatically verified firmware/environment field.

## Verified behavior

- USB discovery distinguishes ordinary Nintendo Switch HID mode (057e:2000) from the observed DBI MTP descriptor (057e:201d).
- After the user selects “运行 MTP 传输程序”, macOS detects DBI MTP. Native ImageCaptureCore successfully opens a session, reads storage identifiers/descriptions and closes the session.
- The device worker's native CLI ran against this device with a 30-second deadline and correctly returned exit 2, status partial and isComplete=false because Installed games is unavailable.
- A separate bounded read of /switch/DBI/dbi.config (5,795 bytes) confirmed [MTP Storages] contains `4: Installed games=false`. The standard SD Card entry is also false; access is exposed through the custom “1: SD内存卡” storage.
- Only the MTP/MainMenu sections were printed. Full original/proposed configuration files are saved privately under ignored output/diagnostics/dbi-config-review with directory mode 0700 and files 0600; they are excluded from Git.
- Local proposal changes exactly `4: Installed games=false` to `4: Installed games=true`. No remote file was changed. The user was asked to choose agent-assisted modification, manual modification, or keeping current configuration.

## User steps

For connection testing, keep the cable attached and select “运行 MTP 传输程序”. FTP and HTTP are separate channels. Connection testing has passed; no additional step is needed for that result.

Installed-list testing additionally requires enabling the Installed games entry. After a configuration change, restart DBI and re-enter MTP so it reloads the file; verify the new storage is actually exposed before treating a scan as complete.

## Worker configuration steering

- User requested OpenCode's DeepSeek. Orca launch-time model override was explicitly unsupported by this installed TUI, so the coordinator used an Orca managed terminal with `opencode mini --model opencode/deepseek-v4.1-flash-free`; its screen confirmed “DeepSeek V4.1 Flash Free · OpenCode”. UI task retried on the same worktree as ctx_ea9b5b1a277e.
- User explicitly requested agy's `--dangerously-skip-permissions` startup flag. The old exact agent terminal was stopped and the CLI restarted in its existing worktree as `agy --dangerously-skip-permissions --mode auto`; library task retried as ctx_452929f83cfe. Task scope and original-file restrictions remain in force.

This checkpoint proves connection, not full inventory matching, installation execution, or overall app completion.
