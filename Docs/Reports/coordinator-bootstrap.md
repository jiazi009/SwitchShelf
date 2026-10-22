# Coordinator bootstrap evidence

- Orca run: run_6bf908529b8b, home workspace /Users/jiazi/Desktop/SwitchShelf.
- Repository initialized locally; main baseline 543b9b7, task contracts 5c27abe, Swift manifest fix 0b28fbf. No remote publication.
- Orca created three child checkouts: jiazi009/switchshelf-ui, jiazi009/switchshelf-library, jiazi009/switchshelf-device. No shared .build write contention.
- opencode UI task task_5360e8d69f31 / ctx_0d02d0cc5236; pi device task task_33e21dc3069b / ctx_322046d41b86.
- Antigravity structured launch positively failed before agent creation. Existing local agy CLI was started in an Orca managed terminal, folder trust accepted for this generated checkout, then same task retried: task_b7b795d147df / ctx_d5a8c4d63902, terminal term_788e0f48-a706-4807-bcd7-04dfd2e90aa4. No replacement provider substituted.
- Actual source /Volumes/switch 游戏包 is smbfs mounted; root enumeration succeeds, 21 entries. No NAS write or game file copy performed.
- Swift 6.4 / Xcode 27.1 available; baseline swift build passed. Deployment target remains macOS 26.
- libmtp 1.1.23 + libusb 1.0.30 installed as local development/test dependencies; distribute bundled native libraries later. Application package must include license/source-offer obligations before a public release.
- IOKit discovery sees USB product DBI, vendor 0x057e, product 0x201d. This only proves enumeration, not MTP readiness or installed inventory success.
- Stock mtp-detect exited 0 while reporting libusb_claim_interface = -3 and failure to initialize. IOKit interface owner is macOS ptpcamerad; command exit status alone is insufficient evidence of success.
- A coordinator ImageCaptureCore prototype successfully discovered the Switch, opened its brokered session, sent read-only GetStorageIDs (0x1004), received 9 IDs with PTP OK (0x2001), and closed the session without error. No system daemon was terminated. This proves brokered MTP communication, not complete inventory support; pi was directed to implement this native route.
- Follow-up GetStorageInfo (0x1005) succeeded for all 9 IDs. Actual exposed storages: SD Card install, NAND install, Saves, Album, SD内存卡, 金手指＆Mod, 相册工具, 主题, JKSV存档备份. Installed games is absent. The user was instructed to enable that MTP storage in DBI settings and re-enter MTP; the app must show an actionable missing-storage state rather than an empty installed list. No DBI configuration was modified by an agent.
- InstallationAssessor fixture tests: 8 domain tests passed, including incomplete identity coverage, old session, candidate local identities, orphan update, version comparison and missing raw version.

This is a bootstrap checkpoint, not evidence that the device adapter, install execution or full app scope has been completed.
