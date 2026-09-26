---
name: sweet-miranda-release
description: Build, install and test a Sweet Miranda build of Trio (and the matching LoopFollow approver) on Miranda's phone. Use when asked to get a new version ready, start a TestFlight build, install on her phone, or test Face ID approvals.
---

# Sweet Miranda: build, install, test

Read `CLAUDE.md` at the repo root first. It has the branches, build history and safety rules.

## 1. Before building

1. Check the fork's `main` against upstream `nightscout/Trio` (`git ls-remote https://github.com/nightscout/Trio.git refs/heads/main`). Rebase Sweet Miranda only onto a **release**, not onto `dev`.
2. Review the diff of anything that touches `SweetMirandaSyncManager`, `SweetMirandaModels` (signing and expiry) or `SweetMirandaSettingsCatalog` (bounds). No Swift compiler exists in the cloud container, so read it closely.
3. If the signing contract changes, change `LoopFollow/SweetMiranda/SweetMirandaApproverView.swift` in the same round and build both.
4. Bump `APP_VERSION` in `Config.xcconfig`.

## 2. Build

- Push, then start the builds with `mcp__github__actions_run_trigger`, `method: run_workflow`, `ref: <branch>`:
  - `masterpro45/trio`, `build_trio.yml`: about 25 min, including the TestFlight upload.
  - `masterpro45/loopfollow`, `build_LoopFollow.yml`: about 8 min.
- Schedule a check-in with `send_later` instead of polling. When it finishes, confirm the **Fastlane upload to TestFlight** step succeeded. If a build fails, read the logs with `get_job_logs` (`failed_only: true`), fix, push and run it again.
- TestFlight can take 5–15 min after upload before the build shows up.

## 3. Install on her phone

1. No bolus or temp basal running, and the pod shows as connected.
2. Install the new version from TestFlight. Settings, pod pairing and Nightscout are kept.
3. Open Trio and wait for one loop. Check the loop icon is green, glucose readings are updating and the pod is still connected. **Stop here if any of these is wrong.** If she's away (pod out of range), this check waits until she's back, and nothing that affects dosing gets sent in the meantime.
4. Install the matching LoopFollow build on the caregiver phone.

## 4. Test Face ID approval

Keep Trio **on screen** on her phone: it checks every 5 min in the foreground, and in the background only after a loop.

1. **Register the approver (one time per key):** LoopFollow › Settings › Sweet Miranda › create the Face ID key. Send an `approver.add` proposal from the dashboard. On her phone, check that the key ID matches the one LoopFollow shows, then approve with her phone's Face ID or passcode.
2. **Remote approval test:** use a display-only key. `settings.showCobIobChart` is a good one because it only shows or hides the COB/IOB chart. Send it from the dashboard and approve in LoopFollow with Face ID. Within 5 min her phone should show "Your settings were updated" with the approver's name, and the chart should change. Send it again to put the chart back.

What a failure means:

| What you see | Cause |
|---|---|
| LoopFollow: "This proposal has no valid expiry…" | The dashboard didn't set `smExpires`, or set it more than 24 h out. |
| Her phone shows the approval sheet instead of applying | The signature didn't verify: wrong key, payload mismatch or expired. Don't approve it there until you know why. |
| "The new approver's key ID does not match its key" | The `approver.add` proposal has the wrong public key. Make a new key and resend. |
| Nothing after 5–10 min | Trio isn't on screen, or Nightscout can't be reached. |

Last run through end to end: 2026-09-26, Trio 1.0.5 (build 9), LoopFollow Actions run 4. The approver was enrolled and the remote approval applied.
