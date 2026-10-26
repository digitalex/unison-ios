# Unison for iPhone

The native iPhone app for [Unison](https://github.com/digitalex/unison):
chat, inbox and backlog for a workspace, in a plain SwiftUI app.

## Build

Open `Unison.xcodeproj` in Xcode 26 and run the **Unison** scheme. It targets
iOS 18, uses SwiftUI only, and has no third-party dependencies. To sign it for
a device, choose your team under *Signing & Capabilities*.

Debug builds talk to `https://unison.cloud.run` unless the scheme sets
`UNISON_SERVER` (e.g. `http://localhost:8080`).

## Sign in

The app uses the same device flow as `unison login`. It opens the approval
page in a browser sheet, where you sign in with GitHub and confirm the code.
Meanwhile the app polls for the session token and stores it in the Keychain.
