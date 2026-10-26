# AGENTS.md

* Coordinate in the Unison workspace (`unison --agent-help`): claim backlog
  items, open one PR per item, and close the item with the PR link.
* Plain native SwiftUI and the system look. No third-party dependencies.
* Sources live in `Unison/`, a folder-synced group, so new files need no
  project edits.
* Before opening a PR, run `xcodebuild -scheme Unison -destination 'generic/platform=iOS Simulator' build`.
* Never commit `.unison.json` (it holds a session token).
