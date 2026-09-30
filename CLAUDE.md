# Trio — Sweet Miranda fork (masterpro45/Trio)

This fork builds Trio for Miranda, who runs it on her iPhone with an Omnipod. It adds **Sweet Miranda** on top of upstream Trio: settings changes proposed remotely, approved with Face ID, plus her own home screen. Trio doses insulin, so treat every change here as safety-critical.

## Branches and builds

- `main` tracks upstream `nightscout/Trio` releases (currently v1.0.1, `c0160aea`). Don't commit Sweet Miranda work here.
- `sweetmiranda-101` is Sweet Miranda rebased onto v1.0.1. The older `sweetmiranda` branch was built on a 9/17 dev snapshot (`cfba1ff`); don't build from it.
- `claude/approver-token-char-count-75brkh` (the signed-expiry fix, 1.0.5) is merged into `sweetmiranda-101` as of build 10.
- Builds run through **Actions → Build Trio** (`build_trio.yml`), started manually on the branch to build. A build takes about 25 minutes and uploads to TestFlight itself. Fastlane sets the build number to the latest TestFlight build + 1.
- Bump `APP_VERSION` in `Config.xcconfig` for every build that goes to her phone, so Nightscout devicestatus and TestFlight show which build she runs. Leave `APP_DEV_VERSION` alone.
- The cloud container has no Swift compiler. Wilson's Mac mini can compile and run the Simulator (`~/Developer/Trio`; strip the Watch app from a scratch pbxproj; ad-hoc sign with `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=`). The SwiftFormat build phase rewrites sources: commit what it changes.
- Screens opened from her skin need what stock HomeRootView provides: `SettingsSearchHighlight` in the environment (Settings, Glucose Alarms crash without it), and Treatments must open via `showModal(for: .treatmentView)` so `hideModal()` can close it.

| Build | Version | Branch | Notes |
|---|---|---|---|
| 3 | 1.0.1 | `main` | Upstream release. Looped reliably and paired her pod. |
| 4–6 | — | `sweetmiranda` | Dev snapshot (`cfba1ff`). Sensor countdown and home screen. Build 5 failed, fixed in 6. |
| 7 | 1.0.3 | `sweetmiranda-101` | Rebased onto v1.0.1. |
| 8 | 1.0.4 | `sweetmiranda-101` | Face ID approvals from a caregiver phone. |
| 9 | 1.0.5 | `claude/approver-token-char-count-75brkh` | Remote approval requires a signed `smExpires`. Installed 2026-09-26. |
| 10 | 1.0.6 | `sweetmiranda-101` | Her screen: "How many carbs?" first (typed or 10 USDA favorites), correction-only behind a 2 s hold, units left shows 50+ for the Omnipod sentinel, EAT + DOSE text fixed, Alerts/Settings no longer crash (skin provides `SettingsSearchHighlight`), treatment screen opened through the router. |
| 11 | 1.0.7 | `sweetmiranda-101` | App icon is Luna, the family schnoodle (`design/luna_icon.svg`): `APP_ICON = luna`, `Icon_.primary = "luna"`, stock `trioBlack` kept as an alternate. Icons must be 1024 px with no alpha channel. |
| 12 | 1.0.8 | `sweetmiranda-101` | Eat hand-off re-runs Trio's calculation once data is loaded and fills Trio's recommendation into Bolus (stops if she edits it) · pod circles open Trio's pump screen, sensor circle the sensor date · food list from WilHQ `sm_foods` via Nightscout's food collection (cached, built-in 10 as fallback) · Pod Keep Alive in the snapshot + a warning when Trio can't loop with the phone locked. **Root cause of 'loops only while open' (builds 4-11): Pod Keep Alive = When Open with Nightscout as the CGM — not our code (Simulator A/B vs stock v1.0.1: identical).** |
| 13 | 1.0.9 | `sweetmiranda-101` | Her skin: bubbly pink 3-D name · Sports Mode / Dream Mode buttons that switch Trio's own override presets (found by name, asked before starting, values set by her parents/care team in Trio ▸ Adjustments) · treatment screen in her colours while the skin is on (plum background, orange carbs, green bolus, pink "BOLUS n U" / "SAVE CARBS" button) · sensor circle uses the CGM's own sensor age now that Trio reads her G6 directly (2026-09-27; Nightscout-as-CGM retired, Omnipod 5 app removed). |
| 14 | 1.0.10 | `sweetmiranda-101` | One mode button, **Activity Mode** (Wilson: like Omnipod 5's Activity feature); matches an override preset whose name contains activity / sport / exercise. Dream Mode removed. Built and sent to TestFlight 2026-09-27 01:30, never installed (she stayed on 1.0.9). |
| 15 | 1.0.11 | `sweetmiranda-101` | Wilson 2026-09-27. **Two mode buttons, each started by a 2-second hold, then she picks how long; tap to stop.** **Activity Mode** = Trio override preset (activity / sport / exercise in the name keeps its numbers; if none exists it is created once as "Activity Mode", target 150, insulin 100 %), for 1 h / 2 h / 4 h / until stopped. **Dream Mode** = no insulin: the pod's own suspend (`PumpManager.suspendDelivery`; overrides stop at 40 %) for 30 min / 1 h / 2 h, never longer. The end time is kept in UserDefaults; every new glucose reading (`GlucoseStorage.updatePublisher`, which keeps coming with the phone locked) and the open home screen resume the pod on time, retrying on the next reading if the pod can't be reached. Nothing is sent to her; the Odysseus watchdog WhatsApps Wilson if the pod stays paused more than 135 min. **Sensor circle** opens the Dexcom's own screen (same `shouldDisplayCGMSetupSheet` sheet as stock Home) for changing the sensor. TARGET tile shows a running override's target. Simulator (mock pump): pickers, Activity on → target 150, Dream pause → auto-resume all verified. |
| 16 | 1.0.12 | `sweetmiranda-101` | Her name is "Miranda" (capital M) with Luna's pink paw print after it. Every alert has an ✕: a closed alert stays hidden until its problem goes away and comes back (next pod, next sensor); `sweetMiranda.dismissedNudges` in AppStorage. The "Ask Dad… Pod Keep Alive" alert shows only when Trio has no CGM heartbeat (the G6 wakes Trio since 2026-09-27; Wilson set Silent Tune anyway). Build 15 installed 2026-09-27 13:18 and looping. |
| 17 | 1.0.13 | `sweetmiranda-101` | **Crash fix, 2026-09-28.** Any approved proposal that changed therapy settings (basal, ISF, CR, targets, pump limits) crashed Trio: `apply()` ran off the main thread and `Broadcaster.notify(on: .main)` asserts the queue (`dispatchPrecondition`). A remote approval re-applied on every relaunch, so Trio crash-looped (9/27 23:13 to 9/28 00:04+, loop down). Reproduced in the Simulator with the real proposal, fixed, re-tested. Now: `apply`/pump syncs are `@MainActor`; a persisted `applyingProposalId` marker makes a crash mid-apply report `failed` at the next start and never retry; remote approvals wait for a quiet moment (loop idle, a loop in the last 6 min, one proposal per loop cycle, no bolus, no Dream Mode); pump callbacks resume once (`SMOnceContinuation`). |
| 18 | 1.0.14 | `sweetmiranda-101` | **Loop-down fix, 2026-09-28.** A proposal set DIA (`pump.insulin_action_curve`) to 3. Our catalog allowed 3–14, but Trio's loop requires at least 5 (`ProfileGenerator`), so every loop failed with "DIA of 3 is not supported". Now: catalog bounds are the narrower of ours and Trio's own settings screen (`DecimalPickerSettings`; DIA 5–10); `pref.curve = bilinear` is refused (the IOB calculation has no peak for it); cross-field rules (basal ≤ max basal, autosens min ≤ max, low < high); **preflight**: before any write, Trio's own `ProfileGenerator.generate` (at every schedule boundary of the day) and `IobCalculation.lookupPeak` run on the would-be settings, with missing schedule files falling back to the bundled defaults as the loop does; **automatic rollback**: the previous values are kept in a persisted record, and if a loop cycle started after the apply fails in determine-basal, or no loop succeeds within 12 min (clock paused while Dream Mode or a suspend holds the pod), they are put back once through the same apply path and reported `failed` with "Rolled back: …"; never back to values the loop would refuse too; remote approvals may apply while the loop is down if the would-be settings pass the preflight; at start, a stored DIA under 5 is set to 5 with a Nightscout note. Simulator (mock pump, simulator CGM): DIA 3 refused, DIA 5 applied and looped, bilinear refused, forced bilinear rolled back and the loop resumed, seeded DIA 3 repaired to 5 at launch. |
| 19 | 1.0.15 | `sweetmiranda-101` | **Miranda's two asks, 2026-09-29.** (1) **No Face ID to bolus.** On her skin the BOLUS button is a 2-second press-and-hold with a fill bar (same gesture as Activity/Dream/correction); the hold is the confirmation, so `addPumpInsulin(skipAuth:)` skips `UnlockManager` on that path only. Carbs-only stays a tap; a very-low glucose still raises the confirm sheet; external insulin and the whole app with the skin off still authenticate. Reversible by turning her skin off. (2) **Her phone stays quiet in public** (a signal-loss alarm embarrassed her at soccer). `TrioAlertManager.issueAlert` suppresses, with her skin on, the everyday nags — `glucose.low/forecastedLow/high/carbsRequired`, `loop.notActive`, and CGM signal-loss/sensor nuisances — and routes them to her parents via the Odysseus watchdog instead (SMS in business hours, WhatsApp after). Urgent Low and any `.critical` alert always sound; unknown alerts still sound (deny-list, err toward alerting). Simulator-compiled clean on the mini; live proof is her first bolus + one loop after install. ⚠ The standalone **Dexcom G6 app** has its own alarms (Signal Loss / Low / High) that this build can't touch — turn those off in the Dexcom app, keep Urgent Low. |
| 20 | 1.0.16 | `sweetmiranda-101` | **Miranda's build-19 feedback, 2026-09-29.** Her bolus screen (skin only) is now **just two buttons**: **SAVE CARBS n g** (tap → `saveCarbsOnly()`, logs carbs, no insulin) and **HOLD 2 SEC · BOLUS n U** (hold). Root cause of build 19's "SAVE CARBS, no bolus": Trio's recommendation only auto-filled the amount via the EAT hand-off, so typing carbs straight into the bolus screen left amount 0 and the one morphing button stuck on SAVE CARBS. Fix: on her skin `sweetMirandaPrefill` is on by default (recommendation always fills the hidden amount), and the two buttons are separate. The raw **Bolus amount field + Recommendation apply-button + fatty/super/external toggles are hidden on her skin** (that stray "0" is gone); a read-only "💧 Bolus n U · Trio's suggestion" row shows the number. **No bolus under 60** (`smBelow60 = currentBG in 1…59`): the bolus button is replaced by a red "✋ Too low to bolus — glucose n" block, Save Carbs stays; also re-checked inside the hold completion. **Cancel**: during delivery her skin shows a big red **STOP** pill (`cancelBolus()`). Simulator-verified on the mini with temporary `SMUITEST` hooks (removed before commit): screenshots of the two-button screen (carbs 30 → Bolus 2.5 U) and the under-60 block (glucose 55). |
| 21 | 1.0.17 | `sweetmiranda-101` | **Build 20 was too much — reverted to build 18's bolus screen + ONLY the 2-second hold (Wilson 2026-09-29: "do the Bolus Button only like version 18, all we are changing is the 2 second button").** Both treatment files were `git checkout`'d to fd52e65 (1.0.14) and re-patched minimally: `addPumpInsulin(skipAuth:)` skips Face ID on the hold path; the single stock button, when it's a bolus on her skin (`smHoldBolus`), becomes the 2-second `smBolusHoldButton` instead of a tap — everything else (Recommendation row, Bolus amount field, External Insulin, carbs-only SAVE CARBS tap) stays exactly stock. No two-button redesign, no field-hiding, no auto-prefill, no separate Save-Carbs button. Kept the one safety guard he asked for: **no bolus under 60** (`smBelow60`, currentBG 1…59) shows a red "✋ Too low to bolus" block in place of the hold. Cancel is stock Trio's ✕ during delivery. Simulator-verified on the mini (temporary SMUITEST hooks, removed before commit): v18 screen + single HOLD button, and the under-60 block. |

## Trio settings are not Omnipod 5 settings (learned 2026-09-27/28)

Her loop was down about 5 hours that night: an approved proposal crashed Trio mid-apply (fixed in 1.0.13), and the
part it did apply, a 3 h DIA, made every loop fail until DIA was set to 5 on her phone. The full write-up is in the
Mac mini's `wilhq-sweet-miranda` skill, section "Trio ≠ Omnipod 5". The short version:

- **Same name, different setting.** Omnipod 5's "active insulin time" (2–6 h; hers was 2) is a bolus-calculator
  countdown. Trio's Duration of Insulin Action is the end of an exponential activity curve shaped by the peak time
  (75 min rapid-acting, 55 ultra-rapid). The curve needs DIA > 2 × peak, so 2 h is impossible with rapid-acting insulin.
  oref0 quietly raised any DIA under 5 to 5; Trio 1.0.1's Swift port throws instead (`ProfileGenerator`), with a
  message that wrongly says "must be > 1". To make insulin act faster, change the peak time or the curve, not the DIA.
  Translating her Omnipod 5 settings into Trio is her endocrinologist's call.
- **Loop-killers:** DIA under 5, the bilinear curve, ISF under 5, max basal under 0.1, a 0 U/h basal segment, an empty
  carb-ratio or target schedule, and a half-basal exercise target of 100 or less. Trio's tested range for every setting is
  in `Trio/Sources/Models/DecimalPickerSettings.swift`. The catalog and the WilHQ dashboard stay inside those ranges.
- **Never loosen a check in `Trio/Sources/APS/OpenAPSSwift/**`.** They guard the dosing math. Make our layer unable to
  send what the loop refuses: dashboard limits, catalog limits, the preflight through `ProfileGenerator.generate`, and
  the automatic rollback.
- **Triage:** Trio loops and uploads devicestatus even with the pod suspended. If the app is alive (profile or notes
  still reach Nightscout) but no devicestatus arrives, it is an algorithm error. Ask for a screenshot of her phone; the
  "Algorithm Error" banner names the setting. On her phone, DIA is under Settings › Algorithm › Additionals.
- **Partial applies happen.** A crash can leave some of a proposal written. After any failed apply, read the newest
  settings snapshot to see what actually changed.

## Where the code is

Most of it is in `Trio/Sources/Services/SweetMiranda/`. Upstream files are touched only by small hooks (`Screen.swift`, `HomeStateModel.swift`, `CGMRootView.swift`, `UserInterfaceSettingsRootView.swift`, `NightscoutAPI.swift`, `NightscoutManager.swift`, `ServiceAssembly.swift`, `TrioApp.swift`), which keeps upstream merges small.

- `SweetMirandaModels.swift`: Nightscout document kinds (`proposal`, `result`, `snapshot`, `approval`, `enroll`, all with eventType `Sweet Miranda Settings`), `SMProposal`, and the signing contract (`SMApprovers`).
- `SweetMirandaSettingsCatalog.swift`: the allow-list and numeric bounds for every key a proposal may change. Anything not listed is refused.
- `SweetMirandaSyncManager.swift`: polls Nightscout for proposals, checks remote approvals, shows the approval sheet, applies changes (pump first) and reports results.
- `SweetMirandaSkin.swift` / `SweetMirandaHomeView.swift`: her home screen, switched on in Settings › Appearance. Off by default. It only reads `Home.StateModel` and never computes a dose.
- `SweetMirandaDreamMode` / `SweetMirandaActivity` (bottom of `SweetMirandaHomeView.swift`): her two modes. Dream Mode pauses and resumes the pod; `BaseSweetMirandaSyncManager` ticks it on every new glucose reading. It never picks a dose, and the pause is capped at 2 h.
- `SweetMirandaSensorSession*.swift`: sensor start date entered by hand (Nightscout as the CGM gives no lifecycle), reached from CGM settings.
- The approvers list, with removal, is in Settings › Appearance › Sweet Miranda.

## Safety rules (don't weaken these)

- **Apply on the main actor, and never retry a proposal that was being applied when Trio stopped** (`applyingProposalId`). Test any apply-path change in the Simulator with a real therapy proposal (mock pump) before building.
- Nothing in Sweet Miranda doses. Settings change only after a person authenticates: her phone's owner (Face ID or passcode), or a registered approver's Face ID on their own phone.
- Proposals are checked against the catalog when they arrive and **again right before applying**, against the settings the phone has at that moment.
- **Preflight with Trio's own algorithm, and roll back if the loop fails.** A proposal that touches anything the loop reads goes through `ProfileGenerator.generate` and `IobCalculation.lookupPeak` on the would-be settings before a single write; if they throw, nothing is written. After the apply, the replaced values stay in `SweetMiranda.rollbackRecord` until a loop cycle succeeds; a determine-basal failure or 12 min without a successful loop puts them back, once, and never to values the loop refuses. Keep catalog bounds inside `DecimalPickerSettings`, and never loosen a check in `Trio/Sources/APS/OpenAPSSwift/**` to make a proposal pass.
- Pump limits and basal are applied before anything else. If the pump refuses, nothing else is written.
- Approvers are added or removed **only by approving on her phone** (`approver.add` / `approver.remove`). A remote signature never counts for those. Trio ignores `enroll` documents; the dashboard turns an enrollment into an `approver.add` proposal.
- A remote approval counts only if the proposal carries a **signed `smExpires`** that is in the future and at most 24 h + 5 min away (`SMApprovers.hasSignedExpiry`). `created_at` isn't signed. Without this, an old approval could be replayed once its id dropped out of the 60 remembered `handledIds`.
- Feed and plumbing settings (units, CGM, uploads, glucose source, Apple Health) are deliberately left out of the catalog.

## Signing contract (shared with LoopFollow, so change both together)

```
payload   = "SMAPPROVE1|<smId>|<sha256 hex of sorted-keys JSON of smChanges>|<smExpires as sent>"
signature = ECDSA P-256 over SHA-256(payload), DER, from a Secure Enclave key
            (.biometryCurrentSet: Face ID only, no passcode fallback)
keyId     = first 16 hex chars of SHA-256(x9.63 public key)
```

LoopFollow side: `LoopFollow/SweetMiranda/SweetMirandaApproverView.swift` on its `sweetmiranda` branch. It uses its own narrow Nightscout token.

## Proposals

- Proposals come from the caregiver dashboard, which is not in these repos. As of 2026-09-26 it sets `smExpires`: the first remote approval verified and applied.
- Her phone looks for proposals every 5 min while Trio is on screen, and after loop cycles in the background (at most every 4 min). If her pod or CGM is out of range, the loop may not run, so keep Trio open to test.

Use the `sweet-miranda-release` skill (`.claude/skills/sweet-miranda-release/SKILL.md`) to build, install and test.
