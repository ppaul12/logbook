# Logbook

Logbook is a personal record-keeping app for macOS 14 or later. It stores check-ins, monthly account balances, and cash flow locally in SwiftData. See the [user guide](docs/user-guide.md) for workflows, CSV schemas, and backup compatibility.

## Build and run

Use full Xcode 16 or later with Swift 6 and the macOS SDK. Open `Logbook.xcodeproj`, select the shared **Logbook** scheme, and choose **My Mac**.

If Command Line Tools is selected, point `DEVELOPER_DIR` to your Xcode installation before running the build and test commands.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

From the repository root, build the app for local use.

```sh
xcodebuild -project Logbook.xcodeproj -scheme Logbook \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData/macOS build
```

Open `DerivedData/macOS/Build/Products/Release/Logbook.app` in Finder. For everyday use, copy it to Applications and keep it in the Dock. The app runs offline and can launch independently of Xcode.

## Use Logbook

- **Check-ins.** Create a completion or quantity scene. A quantity scene can have multiple records per day, and the heatmap colors each day by its total up to the scene’s maximum. Select a cell to view or edit the day’s records. Use the scene page toolbar to edit its settings, reset check-ins, or delete it. Click **Heatmaps** in the sidebar to open **All Scenes**, then choose **Edit Scenes** to reorder, reset, or delete scenes. Turn on **Show archived scenes** in Settings to see archived history. Changing the recording time zone affects new check-ins and preserves saved calendar dates.
- **Account Balances.** Use the title menu to switch between All Accounts and an individual account, and the currency menu to filter balances. Drag right on the chart or scroll horizontally to see earlier months. Use the month controls below the chart or click a month on it to see recorded balances and the change from the previous month. A single account shows all its saved snapshots, newest first. Click a snapshot to edit it or pick a month without a snapshot to record one. Set the Theme Color when creating or editing an account. Its toolbar also lets you reset or delete it. The chart plots a month once every open account in the view has a snapshot. Enter `0` to record a zero balance explicitly.
- **Cash Flow.** Use the title menu to switch between Net Income, Income, and Expense. The bar chart shows up to 24 months. Drag it or scroll horizontally to browse history. Click a month in the chart or use the month controls beside Transactions to choose the totals and entries shown below. Expenses can include an optional category.
- **Settings.** Choose the default currency from the searchable menu in **Bookkeeping**. In **Data Management**, save a CSV template for each of the five data types. Import parent files first, then review new, duplicate, conflicting, and invalid rows before applying. Completion CSV entries use `1` with a blank `entry_id`. Use a distinct UUID per quantity record when importing multiple entries for the same day. Scene colors use six-digit hex, such as `#237F69`. Amounts use a decimal point and follow the precision of their ISO currency code. A JSON backup includes all five CSVs, preferences, scene order and archive state, and a format version. Restore merges records through the same review, with a choice to restore preferences.

## Existing data

The standard local build reopens the same SwiftData store at `~/Library/Application Support/com.example.logbook/Logbook.store`. If you previously set a custom `LOGBOOK_BUNDLE_ID`, use the same value when rebuilding.

If the previous app ran with App Sandbox enabled, it stored data in its app container. Export a JSON backup from that build before switching and restore it in the new build. The same export and restore workflow can bring over records available only on another device.

## Verification

Run `swift test` from the repository root. The Swift package runs the tests in `Tests/` against the same `LogbookCore/` sources compiled into the app. The suite covers date identity, disk persistence, week starts, scene links, credit-card posting across year-end, currency isolation, missing and zero balances, CSV duplicates and conflicts, and backup restoration.
