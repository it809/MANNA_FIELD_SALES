# Server-side rules

The app talks to Frappe over the plain REST resource API, so anything it
enforces on the phone is enforceable only as long as the phone cooperates. The
scripts here are the copy that actually counts — they live on the server and run
on every write, whatever sent it.

Nothing in this folder is compiled into the Flutter app. Each file is pasted
into a **Server Script** record in Desk.

## Installing a script

1. Log in to Desk as an Administrator.
2. `Server Script` list → **Add Server Script**.
3. Fill in the header written at the top of the `.py` file (script type,
   reference doctype, doctype event), paste the file's contents into **Script**,
   and save.
4. Server Scripts must be enabled on the site. On Frappe Cloud they are on by
   default; self-hosted, check `server_script_enabled` in `site_config.json`.

Re-installing after a change is the same flow — open the existing record and
replace the script body.

## Scripts

### `attendance_log_time_rules.py`

- Script Type: **DocType Event**
- Reference Document Type: **Attendance Log**
- DocType Event: **Before Save**

Enforces the punch window and stamps the times from the server's clock:

| Rule | Behaviour |
| --- | --- |
| Punch-in before 05:00 | rejected |
| Punch-out after 21:30 | rejected, with a message pointing at regularization |
| Any accepted punch | time is overwritten with `frappe.utils.now_datetime()`, so the phone's clock is never used |
| Second punch-out | allowed inside the window; the later stamp replaces the earlier one |
| Clearing an existing punch-out | ignored — the stored stamp is put back |
| Yesterday left open | ignored — never blocks today's punch-in |
| `working_hours` | always recomputed from the two stamps |

The rules apply to **self-service** writes only: a rep saving their own
Attendance Log. A manager or HR user writing someone else's log is an approved
Attendance Regularization, which is allowed to set times other than "now". The
script detects this by comparing `frappe.session.user` against the Sales
Person's `custom_user`, and also stands down when the day already has an
Approved regularization (so an approver can fix their own day).

The same two thresholds live in
[lib/core/attendance_rules.dart](../lib/core/attendance_rules.dart). Change them
in both places.
