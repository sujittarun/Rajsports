# Raj Sports — coaching manager

Student, fee and renewal tracking for **Raj Sports**, Hyderabad — one coach,
five centres, five sports. A web console and a native Android app over one
shared backend, built around WhatsApp fee reminders.

**Web console:** https://sujittarun.github.io/Rajsports/
**Android app:** [download the APK](https://github.com/sujittarun/RajSportsApp/releases/latest) ([source](https://github.com/sujittarun/RajSportsApp))

> **No court booking.** This client coaches at other people's venues, so
> CourtSync is switched off for this tenant at three levels (config flag,
> empty court config, and a database trigger that rejects booking rows).
>
> **Payouts are built but hidden.** The centre and coach revenue-share model
> is in the database and tested; it is just not in the UI for now. Bringing it
> back is re-adding a tab, not rebuilding a feature.

---

## What it does

| | |
|---|---|
| **Students** | Roster across centres, batches and sports. A child doing two sports is one student with two enrollments — each billed separately. |
| **Fees** | A rate chain: a tenant default, overridden per sport, per centre, per centre+sport, per batch, per student. Plus a custom amount typed on any one student. |
| **Reminders** | A daily queue of who owes what, with the amount resolved from that student's own rate. One tap opens WhatsApp with the message written. Parents who can't be messaged are separated out with the reason. |
| **Admissions** | A public enrolment form feeding a review queue; approving creates the student and the enrollment. |
| **Observability** | Every config change is audited with before/after and who did it. The Academy Manager console reads a single `tenant_health()` call for roster, money, reminder delivery and misconfiguration. |

## Getting it running

```bash
npx http-server -p 8135 -c-1 .        # web app → http://localhost:8135
```

Sign in at `/login.html`. The staff account for this build is
`staff@rajsports.in`; the password is in `~/.supabase/am-dummy-logins.txt`.

The Android app lives in its own repo so the APK can be built and shared
without touching the web deploy:
**[sujittarun/RajSportsApp](https://github.com/sujittarun/RajSportsApp)**
· [download the latest APK](https://github.com/sujittarun/RajSportsApp/releases/latest)

## Layout

Live at **https://sujittarun.github.io/Rajsports/**

```
index.html          public site: centres, timings, enrolment form
login.html          staff sign-in
today.html          the day's one job: who to chase, what came in
students.html       roster + filters          student.html   one student
reminders.html      the reminder queue        fees.html      collections
setup.html          fees · centres · sports · WhatsApp · activity

assets/css/app.css        the design system (twinned with the Android theme)
assets/js/cloud.js        Supabase adapter        core.js   shell + formatting
supabase/                 schema, tests, cron, the reminder engine
scripts/                  dry-run · test · migrate
```

## Database

One shared Supabase project with the other academies; every row carries
`tenant_id = 'raj'`. **Anything that computes money lives in Postgres** —
the fee chain, the renewal roll-forward, the payout split — so the web app,
the Android app and the WhatsApp engine can never quote different numbers.

Migrations are applied through helper scripts that run against the real
schema inside a transaction and roll back, because this database has four
other live tenants in it:

```bash
./scripts/dry-run.sh supabase/migration-raj-3.sql   # validate, roll back
./scripts/test-migration-3.sh                       # behaviour tests, roll back
./scripts/migrate.sh supabase/migration-raj-3.sql   # apply
```

## WhatsApp

Currently in **manual mode**: the app prepares each reminder and the manager
sends it with one tap; nothing goes out on its own. The engine, the schedule
(heads-up 2 days before, due day, then day 5 and days 7–14) and the retry
policy are already deployed and the crons are running — they are no-ops until
switched on.

To go live, three things are needed from the client: a WhatsApp Business
number for Raj Sports, a Meta Cloud API app, and Meta's approval of the three
message templates. Then it is a config change, not a deploy:

```sql
update tenants
   set config = jsonb_set(config, '{whatsapp}', config->'whatsapp' ||
       '{"enabled":true,"mode":"auto","dryRun":false,
         "phoneNumberId":"…","wabaId":"…","managerPhone":"…"}'::jsonb)
 where id = 'raj';
```

## Before handover

- [ ] Set the real fees in **Setup → Fees** (what's loaded is placeholder)
- [ ] Confirm which sports run at Pushpak, Hill County and PRC — those
      batches are sport-neutral until the client says
- [ ] `./scripts/migrate.sh supabase/clear-sample-data.sql` to remove the
      demo students, keeping the real timetable
- [ ] Replace the dummy staff login with a real account

See `CLAUDE.md` for the architecture and the rules that must not regress.
