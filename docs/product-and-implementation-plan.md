# Logbook Product and Implementation Plan

Logbook is a personal record-keeping app for iOS and macOS. The first release covers
configurable check-ins, monthly balance snapshots, and individual income and expense entries.
Both apps share data and reporting rules. Users can record offline, migrate data by CSV, and
display a check-in heatmap in a widget.

## Navigation

The sidebar stays visible on macOS. On iPhone, the top-left button opens it from the left, and
selecting a page closes it. The sidebar always displays each group and its pages. Groups and
destinations have independent identifiers so the same structure can accommodate new sections.

| Sidebar group | Destinations |
| --- | --- |
| Check-ins | Check-in Heatmaps |
| Bookkeeping | Account Balances, Monthly Cash Flow |
| Sidebar footer | Settings |

## Check-ins and Widgets

### Scenes and Daily Entries

Users can create, reorder, and archive check-in scenes. A scene has a name, a color, and a
record type. Completion scenes use a single color and support one-tap check-ins. Quantity scenes
have a unit and fixed intensity thresholds that determine the shade of each day. Archived scenes
retain their history.

The heatmap groups days by week. Select a day to inspect, backfill, or correct its entry. Each
scene has at most one entry per calendar day. The shared recording time zone determines the day
for new entries.

### Widget Display

Each widget on the iOS Home Screen or macOS desktop shows one selected scene. The medium size
covers a longer period than the small size. Selecting the widget opens its scene in the app.

After saving an entry or receiving a sync update, the app writes the heatmap data to an
on-device App Group container and requests a WidgetKit refresh. The system determines when the
widget refreshes.

## Bookkeeping

Both finance pages place a chart above an editable list. The chart and list share the selected
month and currency. Selecting a month on the line chart updates the list. Saving a list edit
updates the chart and totals on the same page.

### Account Balances

**Monthly snapshots.** Each account has a name, currency, opening month, and optional closing
month. Save one balance per account per month, typically at month-end. Select an account row to
add a missing snapshot or edit an existing one. Archived accounts retain their history.

**All accounts and single accounts.** The default chart sums the active accounts in the selected
currency for each month. Selecting an individual account updates both the chart and the list.

**Missing snapshots and zero balances.** The total line has a gap when a required account
snapshot is missing for that month. The list shows the recorded subtotal and identifies missing
accounts. The individual chart also has gaps for missing snapshots. An explicitly recorded zero
counts as a valid balance.

### Monthly Cash Flow

**Individual entries.** Each entry includes the transaction date, income or expense, amount,
currency, payment method, and an optional note. The list is grouped by posting month and
displays the original date and payment method. Select a row to edit it.

**Posting month.** Most entries post in the month they occur. Credit card expenses post in the
next calendar month. A purchase on November 18 posts in December, and December credit card
expenses post the following January. The form shows the posting month before saving. Date or
payment-method changes recalculate the posting month and update the affected totals.

**Recorded net income.** The chart shows recorded income minus recorded expenses by posting
month. Future months with deferred credit card expenses are marked as upcoming. When only large
expenses are entered, the chart reflects the recorded transactions.

### Currency Selection

Both finance pages share the active currency and start with the default from Settings. With JPY
active, the lists, totals, and entry forms use Japanese yen. Switch to CNY before entering
Chinese yuan. Store amounts in the minor units of the recorded currency and aggregate each
currency separately.

## Settings and Data Migration

**Preferences.** Settings offers a default currency, a recording time zone, and a first day of
the week. The initial default is JPY, and users can select CNY. Existing entry dates stay the
same when the time zone changes. The app and widget use the same week-start preference.

**Import, export, and sync.** Settings provides CSV templates, import and export, and iCloud
sync status. Export one data type as CSV or back up all CSV files, preferences, and the format
version.

### CSV Format

Prepare the source data as UTF-8 CSV. Import scenes and accounts first, then import the records
that reference them. Use YYYY-MM-DD for dates, YYYY-MM for months, and amounts in the original
currency.

| File | Columns |
| --- | --- |
| `scenes.csv` | `scene_id, name, kind, unit, color, thresholds` |
| `checkins.csv` | `scene_id, date, value, note` |
| `accounts.csv` | `account_id, name, currency, opened_month, closed_month` |
| `balance_snapshots.csv` | `account_id, month, balance` |
| `transactions.csv` | `transaction_id, date, kind, amount, currency, payment_method, note` |

Scene kinds are completion and quantity. Separate thresholds with a vertical bar. Transaction
kinds are income and expense. Payment methods are cash, debit_card, credit_card, and
bank_transfer. The app derives the posting month from the original transaction date and payment
method. Notes are optional.

Before writing, show new rows, duplicates, conflicts, and invalid rows. Skip exact duplicates
and let the user resolve conflicts. Match check-ins by scene and date, balances by account and
month, and transactions by transaction_id.

## Implementation and Acceptance

Use SwiftUI on iOS 17 and macOS 14 or later. Use NavigationSplitView on Mac, Swift Charts for
finance, SwiftData for offline storage, and CloudKit for optional sync. Resolve concurrent edits
to the same logical record in the app.

Validate a check-in from local entry through cross-device sync and widget refresh first. Then
verify finance list edits, missing and zero balances, credit card posting across year-end,
currency isolation, duplicate imports, and backup restoration.
