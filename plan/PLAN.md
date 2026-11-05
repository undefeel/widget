# AILimits project plan

## Approved baseline

AILimits is a native macOS menu-bar application with WidgetKit extensions for
Claude, Codex, and Antigravity usage limits and local token statistics.

- Swift 5 language mode, AppKit, SwiftUI, WidgetKit, Foundation, SQLite3,
  Carbon and UserNotifications; minimum deployment target macOS 14.
- Command Line Tools build using `swiftc`, universal arm64/x86_64 binaries,
  manually assembled application/extension bundles and ad-hoc signing.
- Existing source tree and `build.sh` remain the build architecture. There is
  no Swift package, Xcode project, frontend, Go toolchain, or test framework.
- English/Russian resources in `Resources/{en,ru}.lproj/Localizable.strings`.
- No additional services, credentials, dependencies, or paid infrastructure.

## Ownership map

| Area | Files | Responsibilities |
| --- | --- | --- |
| Shared model | `Sources/Shared/Models.swift` | snapshots, usage models, formatting, localization helpers |
| Application | `Sources/App/App.swift`, `Store.swift` | lifecycle, scheduling, state, persistence |
| Data | `Sources/App/Fetchers.swift`, `Usage.swift` | CLI/protocol parsing, local log and SQLite reads |
| Services | `Sources/App/Services.swift` | preferences, terminal launches, VPN/hotkeys/notifications |
| UI | `Sources/App/Popover.swift`, `SettingsView.swift` | menu panel, statistics and settings |
| Widget | `Sources/Widget/LimitsWidget.swift` | widget timelines and views |
| Packaging | `build.sh`, `Resources/*.plist`, `Resources/*.entitlements`, `tools/*.swift` | build, signatures, generated icons |
| Coordination | `AGENTS.md`, `plan/` | approved scope, specs, task state, orchestration tools |

Shared models, localization resources and build files frequently overlap.
Schedule owners serially or assign those files to one lead. Parallel pieces in
the same worktree must have disjoint ownership, including generated artifacts.

## Stages

1. `00-bootstrap`: establish the operating contract and validate its tooling.
2. Future product stages: ask clarifying questions, write a numbered subplan,
   commit it, and wait for user approval. No product backlog is assumed.

Task fields: ID, description, readiness criteria, dependencies, exact files,
level, executor, status (`todo|in_progress|review|done|failed`), Orca Task ID,
Dispatch ID, failure count, review evidence, acceptance evidence.

See `WORKFLOW.md` for coordination and `TESTING.md` for verification.
