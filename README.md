# OpenControls

Two iPhone apps that build on Apple's Screen Time APIs (FamilyControls, ManagedSettings, DeviceActivity) to give parents more control than the built-in Screen Time settings:

| App | Runs on | Job |
| --- | --- | --- |
| **OpenControls Parent** | the parent's phone | edit rules, approve requests, see insights |
| **OpenControls Kid** | the child's phone | enforce the rules with Apple's Screen Time engine and report back |

> **Status: first draft, not yet run on a device.** It was written without access to Xcode or an iPhone. See [What is and isn't verified](#what-is-and-isnt-verified) before relying on it.

## What it adds on top of iOS Screen Time

- **Shared limits per app group.** "Games" can be 60 min on school days and 2 h on weekends, across every game together, with a different allowance for each day of the week.
- **Ask for more time, answered in one tap.** The block screen explains *why* an app is blocked and has an "Ask for more time" button. The parent gets a push notification and can approve +15 / +30 min (or deny) from the Requests tab. The child is notified of the answer.
- **Focus schedules with an allow-list.** Bedtime, School, Homework: everything is blocked except the groups you allow. Overnight windows and per-weekday days work.
- **Wind-down.** Chosen groups switch off *before* a schedule starts (e.g. games and social go off 30 min before bedtime), so screens fade out instead of everything dying at once.
- **Earn time.** The parent defines chores ("Read for 20 minutes → +15 min Games"). The child taps *I did it*, the parent approves, and the minutes are added to that day's allowance.
- **Pause all / Bonus time.** One-tap pause (dinner, family time) with a timer or until resumed, and one-tap bonus minutes.
- **Low-time nudge.** The child gets a notification when 5 minutes remain in a group.
- **Insights.** Stacked daily usage by group, daily average, most-used group, how often the child asked for more, chores completed.
- **Tamper signals.** The parent sees when Screen Time access is off on the child's phone, when groups have no apps chosen yet, and when the newest rules haven't reached the phone. Optionally forces automatic date & time (so the clock can't be changed to dodge limits) and blocks deleting apps.
- **Parent PIN** on the child's setup screen.

## How it works

```
Parent phone                         CloudKit (public DB)                 Child phone
┌──────────────┐  encrypted+signed   ┌──────────────────┐   push + fetch  ┌─────────────────────────┐
│ Parent app   │ ──────────────────▶ │  "Envelope"      │ ───────────────▶│ Kid app                 │
│ rules, inbox │ ◀────────────────── │  records (opaque)│ ◀───────────────│  PolicyEngine           │
└──────────────┘  encrypted          └──────────────────┘   status/requests│  ShieldApplier ─────────┼─▶ ManagedSettingsStore
                                                                           │  MonitoringPlanner ─────┼─▶ DeviceActivityCenter
                                                                           └────────────┬────────────┘
                                                   App Group files (JSON)               │
                                                   ┌──────────────────────────┐         ▼
                                                   │ Monitor extension        │  threshold / interval callbacks
                                                   │ Shield Configuration ext │  explains the block
                                                   │ Shield Action ext        │  "Ask for more time" → outbox
                                                   └──────────────────────────┘
```

- **Enforcement is local.** Limits are enforced on the child's phone by iOS itself; nothing needs the network to keep working. The Kid app's `EnforcementCoordinator.refresh()` recomputes the desired shield state from scratch from `(policy, usage, grants, overrides, pause)` using the pure `PolicyEngine`, and every trigger (app launch, incoming rule, extension callback) just calls it. That makes the system self-healing and easy to test.
- **Usage tracking** comes from DeviceActivity threshold events registered every 5 minutes (every 15 after 2 hours) per group. Budgets on that grid are enforced exactly; the UI only offers grid values. Restarting monitoring mid-day resets iOS's counters, so the planner records a per-group *baseline* and adds it back.
- **Which apps are in a group is chosen on the child's phone** (behind the parent PIN) with Apple's `FamilyActivityPicker`. Screen Time tokens are opaque and device-local, so the parent app deliberately only manages the *rules*, not the app list.
- **Sync** is a mailbox of encrypted records in the CloudKit *public* database, because parent and child are normally different iCloud accounts. The pairing link/QR contains a random 32-byte secret; the mailbox name and an AES-GCM key are derived from it (HKDF), so the server only sees opaque blobs under a random name. Parent→child messages are also **Ed25519-signed** with a key that never leaves the parent's devices, so a child who learns the pairing secret still cannot forge a "+999 minutes" grant. Replays of old grants are ignored.

## Building

You need a Mac with Xcode 15+ and a paid Apple Developer account.

1. `brew install xcodegen`
2. Edit `project.yml`: set `OC_BUNDLE_PREFIX` (e.g. `com.yourname.opencontrols`) and `DEVELOPMENT_TEAM`. The App Group (`group.<prefix>.shared`) and CloudKit container (`iCloud.<prefix>`) are derived from the prefix.
3. `xcodegen generate && open OpenControls.xcodeproj`
4. In the Apple Developer portal, register for your team:
   - the App IDs `<prefix>.parent`, `<prefix>.kid`, `<prefix>.kid.monitor`, `<prefix>.kid.shieldconfig`, `<prefix>.kid.shieldaction`;
   - the App Group and the iCloud container;
   - the **Family Controls** capability on the four Kid App IDs. Development use is available immediately; **distributing** through TestFlight/App Store requires Apple's approval via the [Family Controls distribution request](https://developer.apple.com/contact/request/family-controls-distribution).
5. In the [CloudKit Dashboard](https://icloud.developer.apple.com) → your container → **Development**, create the record type `Envelope` with fields `channel` (String), `sender` (String), `kind` (String), `ts` (Int(64)), `body` (Bytes), `sig` (Bytes), and add indexes: `channel`, `sender`, `kind` **Queryable**, and `ts` **Queryable + Sortable**. (The first save from a dev build also auto-creates the type; the indexes you add by hand.) Deploy the schema to Production before shipping.
6. Run **OpenControls Parent** on the parent's iPhone and **OpenControls Kid** on the child's. Real devices are needed (the simulator has no Screen Time or push).

### Pairing and first run

1. Parent app → add a child → a QR code appears.
2. On the child's phone, scan it with the Camera app and tap the banner (or paste the link into the Kid app).
3. Kid app → **Setup → Turn on (parent signs in)**. A parent signs in through Family Sharing; this is the `.child` authorization that stops the child from switching Screen Time off. For development on an adult account use **test mode** (`.individual`), which anyone can revoke in Settings and which the parent app flags.
4. Still in Setup, pick the apps for each group (use individual apps for *Essentials* and any group that must stay open during School/Bedtime).
5. Parent app → **Rules**: adjust limits, schedules, chores; set a parent PIN under *More options*.

Run the unit tests (policy engine, threshold grid, crypto/sync, models) with `xcodebuild test -scheme OpenControls -destination 'platform=iOS Simulator,name=<an iPhone>'`. A GitHub Actions workflow does the same on every push.

## What is and isn't verified

- **Automated:** the platform-independent logic (`PolicyEngine`, `ThresholdPlan`, envelope crypto/signing, models, file storage) has unit tests, run by CI on a macOS runner.
- **Not verified on hardware:** everything that touches Screen Time, CloudKit and push. In particular these are best-effort or untested assumptions:
  - **Extension memory limits.** The Monitor extension is memory-constrained; it deliberately avoids networking and only touches small JSON files.
  - **Requests from the block screen are queued, not sent instantly.** Shield extensions can't reliably use the network, so tapping *Ask for more time* writes to an outbox and posts a local notification ("Request ready to send"); the Kid app delivers it as soon as it runs (tap the notification, or when a silent push / foreground wakes it). Expect some delay if the app isn't opened.
  - **Number of registered events.** Each group registers up to ~48 events. iOS has undocumented limits on monitored activities/events; if `startMonitoring` fails the Kid app surfaces the error in Setup and the parent's status card.
  - **Schedule start/end** relies on DeviceActivity intervals (minimum 15 minutes). The app also recomputes on every launch/callback.
  - **Entire categories can be blocked but not allowed.** iOS's "block everything except…" only accepts individual apps/sites as exceptions.
  - **Public-database trade-offs.** Anyone with the pairing link can read/write that mailbox, so treat the QR like a password. Apple's public DB has quotas; each device prunes its own messages after 14 days.
  - Time is tracked by Screen Time threshold events, not exact seconds, so usage can read up to ~5 minutes low.
- **Not built:** location, web content filtering rules beyond the picker, a co-parent on a different Apple ID (the parent signing key syncs through iCloud Keychain, so a second device on the *same* Apple ID works), iPad-specific layouts.

## Project layout

```
Shared/Core         Models, PolicyEngine, storage, keychain  (all targets)
Shared/Sync         Pairing, envelope crypto, CloudKit mailbox (apps + tests)
Shared/Enforcement  ManagedSettings / DeviceActivity glue     (Kid app + its extensions)
Shared/UI           SwiftUI building blocks                   (both apps)
ParentApp/          Parent app
ChildApp/           Kid app
ChildMonitor/       DeviceActivityMonitor extension
ChildShieldConfig/  ShieldConfiguration extension
ChildShieldAction/  ShieldAction extension
Tests/              Unit tests
project.yml         XcodeGen spec (the .xcodeproj is generated, not committed)
```

Shared folders are compiled directly into each target (no Swift package), so nothing needs `public` access control.
