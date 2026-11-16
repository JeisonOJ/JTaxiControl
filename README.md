# JTaxiControl

JTaxiControl is a personal learning and development project exploring Flutter,
Dart, Supabase Auth, and PostgreSQL through taxi financial management. It provides
an Android and web interface for two independent taxi accounts.

The repository contains application source, schema migrations, and synthetic
local tests. It does not include deployment credentials, account enrollment,
financial records, signing keys, compiled releases, or local runtime artifacts.

## Features

- Taxi and driver records with historical assignments.
- Fixed daily quotas, configurable workdays, exemptions, and outstanding debt.
- Flexible contributions without automatically generated driver debt.
- Partial payments with idempotent retries and oldest-obligation allocation.
- Auditable payment cancellation with historical cash validation.
- Independent opening cash balances and amounts owed to an owner.
- Expenses, owner advances and repayments, recurring due dates, and monthly summaries.
- Spanish interface with Colombian peso formatting and Colombia-local dates.
- Two authorized application users with equal permissions; no driver accounts.

Internet connectivity is required. Offline synchronization, public registration,
payment editing, and cancellation of expenses are outside the current scope.

## Technology and structure

The current source targets Flutter 3.50 / Dart 3.14. Android uses a minimum SDK of
24 and targets SDK 36 through the Flutter toolchain. Web builds are static files.

- `lib/`: Flutter screens, small repositories, and domain calculations.
- `supabase/migrations/`: ordered PostgreSQL schema and RPC definitions.
- `test/`: Flutter domain, retry, and widget tests.
- `supabase/tests/`: isolated PostgreSQL tests using PGlite and synthetic identities.
- `launcher-web/`: optional Python standard-library localhost server for Windows.

Financial writes are performed by narrow transactional RPCs. PostgreSQL applies
Row Level Security and checks a private authorization table. Payments and other
financial requests use idempotency identifiers. Historical cash validation rejects
operations that would make a daily balance negative. The Flutter UI uses local
widget state without an additional state-management framework.

## Local setup

Install a compatible Flutter stable SDK, Git, and the Android command-line SDK
if building Android. Android Studio's interface is not required. For local SQL
tests, install Node.js; for the optional Windows launcher, install Python with
Tkinter and Microsoft Edge.

```powershell
flutter pub get
Copy-Item config/supabase.example.json config/supabase.json
```

Edit the ignored `config/supabase.json` with the HTTPS URL and **publishable key**
of your own Supabase project. These public values are embedded in the client;
Auth, authorization, and RLS must enforce access. Never place service-role keys,
database passwords, signing passwords, or administrative secrets in client code.
The application expects the `SUPABASE_PUBLISHABLE_KEY` value to use the
`sb_publishable_` format.

### Supabase setup for a new project

1. Create your own Supabase project. Disable public user signup and anonymous
   authentication; keep password authentication enabled.
2. Create two private Auth users through the dashboard. Do not share passwords.
3. Review the SQL and apply migration `001_initial.sql` first (the actual files
   have timestamp prefixes). Enrollment migration `002_private_members.sql`
   contains no identities and makes no changes unless configured.
4. To enroll your users, execute the following together with the **complete 002
   file**, in the same SQL Editor execution. Replace both UUID placeholders with
   the UUIDs from your own Auth users:

```sql
select set_config('jtaxi.member_one', 'YOUR_FIRST_AUTH_USER_UUID', false);
select set_config('jtaxi.member_two', 'YOUR_SECOND_AUTH_USER_UUID', false);
-- Paste the entire 002_private_members.sql here and execute together.
```

The 002 file ends with COMMIT. Unconfigured enrollment leaves financial access
closed. Review this procedure before executing it; the migration is for a new
installation, not a reset or data cleanup workflow.

5. Apply migrations 003, 004, and 005 in order, once. They implement finances,
   opening balances, and payment cancellation. Do not rerun or delete migrations
   to reset an existing database.
6. Sign in with an enrolled user. Register taxis and configure each taxi's opening
   cash and owner debt before recording any financial activity. Opening values
   are independent and cannot be overwritten after confirmation.

## Run and build

```powershell
flutter run -d chrome --dart-define-from-file=config/supabase.json
flutter run -d YOUR_ANDROID_DEVICE_ID --dart-define-from-file=config/supabase.json
flutter build web --release --dart-define-from-file=config/supabase.json
flutter build apk --release --dart-define-from-file=config/supabase.json
```

The Android build currently uses the local development signing configuration.
Configure and privately back up a dedicated signing key before distributing your
own release. Keep the application ID and signing identity consistent for updates,
and increase the version code. Never commit keystores or signing configuration
containing passwords. The launcher icon remains the Flutter default.

### Optional Windows web launcher

This serves an already compiled release, without `flutter run`:

```powershell
python tools/prepare_web_launcher.py
python launcher-web/launcher.py
```

It opens Edge at `http://127.0.0.1:8765/`. Keep the small server window open while
using the app, then close it with **Cerrar servidor** after resolving pending
requests. Alternatively run `python launcher-web/launcher.py --stop`. A second
launch reuses the server. The server binds only to loopback and does not install
a service or configure startup. Python/Edge installations and desktop shortcuts
are local concerns and are not bundled. For other platforms, use your preferred
static HTTP server. Financial records remain in your own Supabase project.

## Tests

```powershell
flutter analyze
flutter test
npm ci
npm run test:db
```

PGlite tests run against disposable local databases without network connections
to Supabase. Fixtures use synthetic UUIDs and records. They cover quota schedules,
exemptions, allocations, opening balances, financial integrity, isolation, access
controls, cancellation, and retries. Local tests do not establish remote deployment
correctness or constitute a security audit. Test with your own non-production
environment before relying on financial results.

## Development context and limitations

This is an evolving personal software project, not a generalized accounting
system. There is no automated deployment configuration. Existing opening balances
are immutable; recurring templates do not yet have an editing/cancellation UI.
Use backups, review migrations, and validate critical workflows independently.
No software license has been selected in this snapshot; public visibility alone
does not grant an open-source license.

