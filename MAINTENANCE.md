# Maintenance Policy

ReProvision Reborn is maintained on a conservative, best-effort basis. The goal is to keep the original on-device iOS signing workflow usable for supported jailbroken iOS environments without expanding the project into unrelated platforms or piracy support.

## Current Scope

Maintained areas:

- iOS support on jailbroken devices
- Apple account authentication flow
- Keychain-stored credential handling
- Provisioning API interactions
- Application signing and re-signing
- URL scheme IPA installation
- Background signing daemon behavior
- Build, documentation, and triage improvements

Not currently prioritized:

- tvOS support
- macOS support
- Support for modified unofficial builds
- General jailbreak support questions
- Piracy or entitlement bypass support

## Issue Triage

Issues are most useful when they include the exact iOS version, device model, jailbreak environment, ReProvision Reborn version or commit, Apple account type, exact error text, and minimal reproduction steps.

Issues may be closed or marked as needing more information when they are not reproducible, omit required environment details, describe unsupported platforms, request piracy support, or depend on old Apple service behavior that cannot be verified.

Security-sensitive issues should not be filed publicly. Follow [SECURITY.md](SECURITY.md) for private reporting guidance.

## Pull Requests

Pull requests should be focused and tested on a physical device when they affect signing, installation, account authentication, Keychain access, provisioning, or daemon behavior. Changes to security-sensitive areas should explain the affected workflow and the verification performed.

## Releases

Maintenance releases may include documentation updates, issue triage improvements, build fixes, compatibility notes, security policy updates, and conservative bug fixes. A maintenance release does not imply support for every iOS version, device, or jailbreak environment.
