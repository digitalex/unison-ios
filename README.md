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

## Testing against a local server

Run a server in open mode (`UNISON_AUTH=off unison serve`), join with a
participant via the API, and launch a debug build with `UNISON_SERVER`,
`UNISON_TOKEN` (the participant token) and `UNISON_WORKSPACE`. This skips
GitHub sign-in. `UNISON_TAB` and `UNISON_ITEM` open a tab or a backlog item.

## Releasing

Each upload to App Store Connect needs a higher build number: bump
`CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION` for a new release) in
the project's build settings first. `Unison/PrivacyInfo.xcprivacy` is the
privacy manifest. Keep it, and the App Privacy answers in App Store Connect,
consistent with the privacy policy at `/privacy-policy`. The app only uses
standard HTTPS, so `ITSAppUsesNonExemptEncryption` is `NO` in `Info.plist`.
