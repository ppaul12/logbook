# Logbook User Guide

Logbook is a local macOS app for configurable check-ins, monthly balance snapshots, and individual
income and expense entries. Users can record offline, migrate data by CSV, and back up or restore
their records and preferences as JSON.

## Navigation

| Sidebar group | Destinations |
| --- | --- |
| Check-ins | Heatmaps |
| Bookkeeping | Account Balances, Cash Flow |
| Sidebar footer | Settings |

## Check-ins

### Scenes and Daily Entries

Users can create, reorder, archive, reset, and delete check-in scenes. A scene has a name, a color,
and a record type. Completion scenes use a single color and support one-tap check-ins. Quantity
scenes have a unit and a heatmap maximum. The color darkens as the daily total approaches that
maximum. Users can show archived scenes and their history in Settings.

In All Scenes, Last 4 Weeks shows 28 consecutive days ending today in the recording time zone.
The individual scene heatmap groups days by calendar week. Select a day to inspect, backfill, or
correct its entries. Archiving a scene hides its quick check-in button.
Completion scenes have one entry per day. Quantity scenes can have several entries, which
the heatmap sums by day. The shared recording time zone determines the day for new entries.

## Bookkeeping

Both finance pages place a chart above an editable list. Click the chart or use the month
controls beside the list heading to select a month within that view's available history.
Saving a list edit updates the chart and totals on the same page.

### Account Balances

**Monthly snapshots.** Each account has a name, currency, opening month, and optional closing
month. Save one balance per account per month, typically at month-end. Select an account row to
add a missing snapshot or edit an existing one. Closed accounts retain their history.

**All accounts and single accounts.** The default view shows stacked monthly bars with a series
for each account in the selected currency. The chart opens on up to 24 recent months.
Drag the chart to the right or scroll horizontally to browse earlier months. Clicking the chart
also selects a month. Choose an individual account from the title menu to update both the chart
and the list. In its toolbar, reset clears the account’s snapshots, and delete removes both the
account and its snapshots.

**Missing snapshots and zero balances.** The chart has a gap when a required account
snapshot is missing for that month. The list shows the recorded subtotal and identifies missing
accounts. Account colors appear beside their names. The overview shows the total or recorded
subtotal above the list. Monthly change bars and signed values use the Nord palette. Each
comparable account shows its change on a shared, zero-centered scale, with the current balance
in the last column. The individual chart also has gaps for missing snapshots. Its history lists
every saved snapshot in reverse chronological order.
An explicitly recorded zero counts as a valid balance.

### Cash Flow

**Individual entries.** Choose Income or Expense first, then enter the transaction date, currency,
amount, and required note. Expenses also offer a free-text payment method and a Settle next month
checkbox. Each row puts the note and amount first, followed by the transaction date and any
category or payment method. Select a row to edit it and read the full note.

**Expense categories.** Each expense has an optional free-text category. Editing it updates
that expense. Existing categorized expenses retain their category names.

**Posting month.** Income and expenses normally post in the month they occur. Check Settle next
month to move an expense into the following calendar month. Existing credit card expenses
keep their next-month posting.

**Monthly views.** Clicking Cash Flow in the sidebar opens Net Income. The title menu switches
between Net Income, Income, and Expense. Net Income
shows all three monthly totals and both kinds of transactions. The other views show their own
totals and transactions. The chart bars, comparison bars, and signed amounts use the Nord palette.
A neutral mark represents zero in a month with recorded activity. The chart shows up to 24 months.
Drag it or scroll horizontally to browse history. The month controls beside Transactions set the
month for the totals and entries. [Nord colors and palettes](https://www.nordtheme.com/docs/colors-and-palettes/)

**Monthly averages.** Progress bars below the totals compare the selected month with historical
monthly averages. Income and expense compare their magnitudes. Net income divides the signed
amount by the magnitude of its average and fills left for a loss or right for a profit from
a centered zero. Its average marker uses the side matching the historical average's sign.
Percentages show the actual ratio beyond the 150% fill limit. Net Income shows three bars.
The other views show their own bar. Hover over a bar for the signed difference from its average.
Choose 3, 6, 12, or 24 months, or All History. The default is
12 months. The displayed range includes completed months before the selected month and starts
no earlier than the first recorded posting month for the current currency. Months without
transactions within that range count as zero.

### Currency Selection

Both pages start with the default currency from Settings and offer independent currency
filters. Account and transaction forms let you choose the record’s currency. An account’s
currency is fixed once it has a saved snapshot. Amounts use the minor units of the recorded
ISO currency, and each currency is aggregated separately.

## Settings and Data Migration

**General** contains the optional greeting name and the recording time zone. Date, month, and
weekday labels use macOS regional formats. Existing entry dates stay the same when the time zone
changes.

**Check-ins** controls which day the week starts on and whether archived scenes appear.
**Bookkeeping** contains the searchable default currency menu. The initial currency is JPY.

**Data Management** contains **CSV Import & Export** and **Backup & Restore**. CSV tools provide
templates, import, and export for one data type at a time. A backup saves all data types,
preferences, and the format version in a single JSON file and allows users to preview a restore
before applying it.

### CSV Format

Prepare the source data as UTF-8 CSV. Import scenes and accounts before the records that
reference them. Use YYYY-MM-DD for dates, YYYY-MM for months, and amounts in the original
currency.

| File | Columns |
| --- | --- |
| `scenes.csv` | `scene_id, name, kind, unit, color, maximum` |
| `checkins.csv` | `scene_id, date, value, note, entry_id` |
| `accounts.csv` | `account_id, name, currency, opened_month, closed_month, color` |
| `balance_snapshots.csv` | `account_id, month, balance` |
| `transactions.csv` | `transaction_id, date, kind, amount, currency, payment_method, note, settles_next_month, category` |

Account colors use six-digit hex values such as `#8459CB`. Leave the color field blank for an
automatic theme. Older account CSVs without the color column retain the saved color when imported.

Scene kinds are `completion` and `quantity`. Quantity scenes require a positive maximum. Give each
quantity entry its own UUID in `entry_id` when importing multiple records for one day.
Use `1` for the value of a completion entry and leave `entry_id` blank. In older scene CSVs and
backups, the highest threshold becomes the maximum. Transaction kinds are `income` and `expense`.
For expenses, `payment_method` accepts free text, and `settles_next_month` accepts true, false, or blank
(same month). Leave both fields blank for income. Older transaction CSVs without
`settles_next_month` preserve next-month posting for `credit_card` expenses. New or changed
transactions in CSV imports need a note. Backups can restore historical transactions with
blank notes.
`category` accepts free text. Leave it blank for income and uncategorized expenses. Older
transaction CSVs without a category column preserve the category of a matching expense.
Version 5 backups resolve saved category IDs to their original names.

The import preview shows new rows, duplicates, conflicts, and invalid rows. Logbook skips exact
duplicates and lets you resolve conflicts. It matches check-ins by scene, date, and entry ID if
present, balances by account and month, and transactions by `transaction_id`.
