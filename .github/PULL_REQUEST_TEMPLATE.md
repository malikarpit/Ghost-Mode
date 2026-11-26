## Summary
Provide a concise summary of the changes and why they are needed.

## Type of Change
- [ ] Bug fix
- [ ] New feature or enhancement
- [ ] Performance or battery optimization
- [ ] UI / UX polish (Liquid Glass / AppKit / SwiftUI)
- [ ] Security hardening (`PowerManager`, `SudoersPolicy`, `AppFreezer`, `ghostmode_setup.sh`)
- [ ] Documentation or build workflow

## Verification
- macOS Version:
- Chip Architecture (`arm64` / `x86_64`):
- Commands run:
  - [ ] `bash -n ghostmode_setup.sh make_icns.sh`
  - [ ] `make clean && make all`
  - [ ] `make test` (all unit tests pass)
  - [ ] `codesign --verify --deep --strict "Ghost Mode.app"`
  - [ ] `make dmg` (if packaging or installer changed)

## Safety & Security Checklist
- [ ] Preserves `@available` compatibility for macOS 12+ (`arm64`) / Intel builds and avoids macro-only SwiftUI syntax where Command Line Tools compatibility requires it.
- [ ] Privileged actions go strictly through `PowerManager.performPrivilegedAction(_:)` with `verifyBundleCodeSignature()`, validated `SudoersPolicy`, and TOCTOU-safe staging.
- [ ] Process freezing never targets core macOS commands/daemons or Ghost Mode ancestors and resumes parent processes before child helpers (`SIGCONT`).
- [ ] No sensitive data, local `.DS_Store`, or temporary build artifacts included.
