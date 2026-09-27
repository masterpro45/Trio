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

## Where the code is

Most of it is in `Trio/Sources/Services/SweetMiranda/`. Upstream files are touched only by small hooks (`Screen.swift`, `HomeStateModel.swift`, `CGMRootView.swift`, `UserInterfaceSettingsRootView.swift`, `NightscoutAPI.swift`, `NightscoutManager.swift`, `ServiceAssembly.swift`, `TrioApp.swift`), which keeps upstream merges small.

- `SweetMirandaModels.swift`: Nightscout document kinds (`proposal`, `result`, `snapshot`, `approval`, `enroll`, all with eventType `Sweet Miranda Settings`), `SMProposal`, and the signing contract (`SMApprovers`).
- `SweetMirandaSettingsCatalog.swift`: the allow-list and numeric bounds for every key a proposal may change. Anything not listed is refused.
- `SweetMirandaSyncManager.swift`: polls Nightscout for proposals, checks remote approvals, shows the approval sheet, applies changes (pump first) and reports results.
- `SweetMirandaSkin.swift` / `SweetMirandaHomeView.swift`: her home screen, switched on in Settings › Appearance. Off by default. It only reads `Home.StateModel` and never computes a dose.
- `SweetMirandaSensorSession*.swift`: sensor start date entered by hand (Nightscout as the CGM gives no lifecycle), reached from CGM settings.
- The approvers list, with removal, is in Settings › Appearance › Sweet Miranda.

## Safety rules (don't weaken these)

- Nothing in Sweet Miranda doses. Settings change only after a person authenticates: her phone's owner (Face ID or passcode), or a registered approver's Face ID on their own phone.
- Proposals are checked against the catalog when they arrive and **again right before applying**, against the settings the phone has at that moment.
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
