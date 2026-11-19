# CountOnce staff app

How to build and run it is in the main README. This is how the code is laid out, in the three layers of
chapter 4.

| File | Layer | What it does |
|---|---|---|
| `lib/ui/sign_in.dart` | UI | Name and staff key, asked once; changed later by tapping the name chip |
| `lib/ui/home_page.dart`, `lib/ui/scan_page.dart` | UI | The screens: items, the Take out / Put in sheet, scan, the offline banner, waiting scans, recent answers |
| `lib/ui/theme.dart` | UI | The colours and type, shared with the dashboard (`public/index.html`) |
| `lib/logic.dart` | Logic | `StaffLogic`, the view model: puts each scan in the outbox, sends it, keeps the state the screens show |
| `lib/data/api.dart` | Data | `StockApi`: the only code that talks to the API |
| `lib/data/outbox.dart` | Data | `Outbox`: scans waiting to be sent, saved on the phone |
| `lib/data/migrate.dart` | Data | Moves anything a phone saved under the app's earlier storage names to the current ones, once at start |
| `lib/models.dart` | Data | `Item`, `Movement`, `Outcome` |

Data flows one way: a button calls `StaffLogic`, `StaffLogic` asks the data layer, and the new state
flows back to the screens through `notifyListeners()`. `test/outbox_test.dart` checks the logic layer
against a fake API, and `test/ui_test.dart` checks the Take out / Put in sheet.

The type is IBM Plex Sans and IBM Plex Mono (`fonts/`, SIL Open Font License, `fonts/OFL.txt`), also used by the dashboard.
