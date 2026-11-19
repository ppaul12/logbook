# Logbook

Logbook is a personal record-keeping app for iOS and macOS. The first release covers configurable check-in heatmaps, monthly account balance snapshots, and individual income and expense entries.

The SwiftUI starter includes the English sidebar, a chart-above-list structure for both finance screens, and a persistent default currency preference. The [product and implementation plan](docs/product-and-implementation-plan.md) specifies the data model, CSV formats, sync, widgets, and release checks.

## Development setup

- Xcode 16 or later with the macOS and iOS SDKs.
- An iOS Simulator runtime for testing on iPhone.
- Deployment targets of iOS 17 and macOS 14. The project uses Swift 6 and Apple frameworks.

Open `Logbook.xcodeproj`, choose the shared `Logbook` scheme, and run it on **My Mac** or an **iPhone simulator**.

To build both platforms from Terminal with the full Xcode toolchain selected:

```sh
xcodebuild -project Logbook.xcodeproj -scheme Logbook \
  -destination 'platform=macOS' -derivedDataPath DerivedData/macOS \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Logbook.xcodeproj -scheme Logbook \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData/iOS \
  CODE_SIGNING_ALLOWED=NO build
```

Set your development team and replace the placeholder bundle identifier `com.example.logbook` for device signing. Enable the corresponding Apple capabilities when adding iCloud sync and the widget extension.

## First development milestone

Create one check-in scene and exercise the full path from local entry to the heatmap. Then verify offline edits, sync on two devices, and the widget snapshot before building the finance features.

[Apple documentation on multiplatform app targets](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target)
