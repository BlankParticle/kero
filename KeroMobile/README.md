# Kero for iOS

Kero for iOS is a separate native Xcode project and app target. It is an SSH client for
iPhone and iPad; it does not build against or share runtime code with the macOS app.

## Version 0.0.1

- Saved SSH hosts
- Password and generated Ed25519 key authentication
- Device-only Keychain storage with optional Face ID or passcode protection
- Trust-on-first-use host-key verification and changed-key warnings
- SwiftTerm terminal with touch controls, Unicode input, links, and hardware keyboards
- Optional `tmux new-session -A -s kero` startup for resumable remote work

Kero is deliberately an interactive SSH terminal. File transfer, Mosh transport,
agent-specific UI, and background session persistence are outside the 1.0 scope.
When iOS backgrounds the app, reconnect and use the optional tmux integration to
resume remote work.

## Build

Open `KeroMobile.xcodeproj`, select the `KeroMobile` scheme, then run on an iOS 18 or newer
device or simulator. Package dependencies resolve through Swift Package Manager.

The `KeroMobileTests` target includes persistence, Keychain, host-key, key-generation,
and loopback SSH transport coverage. `KeroMobileUITests` exercises the primary
iPhone workflow.

## Release

Release metadata, the publishable privacy policy, and the external submission
checklist live in [`KeroMobileRelease`](../KeroMobileRelease/).
