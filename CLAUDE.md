# Raj Sports — coaching manager (web + Android)

Fee, renewal and admission tracking for **Raj Sports**, a coach-operator who
runs coaching batches at five centres he does not own, across five sports, in
Hyderabad. Two clients, one backend, one set of rules.

The client's stated priority, in his words: **WhatsApp reminders that never
give a parent a bad experience.** Everything below is arranged around that.

---

## The shape of the business (do not regress)

- Raj coaches **at other people's venues** — schools, clubs, communities. That
  is why a *centre* can take a revenue share, and why "rent" and "% of
  collections" are both first-class payout shapes.
- **There is NO court booking.** CourtSync is off for this tenant. It is off in
  three places, deliberately: `tenants.config.modules.booking = false`, no
  `courts`/`rates` config, and a DB trigger that *rejects* any insert into
  `bookings` or `integrations` for a booking-disabled tenant. Do not "helpfully"
  add a booking screen.
- People are **students** here (not "members" as in the Leo/Machaxi apps) and
  they have **parents**. Parent contact is the WhatsApp contact.

### The five centres (from the client, verbatim)

| Centre | Days | Batches | Sports |
|---|---|---|---|
| DPS Miyapur | Mon–Fri | 3:00–4:30pm, 4:30–6:00pm | archery, basketball, football, cricket, tennis |
| BTV | Mon/Wed/Fri + Tue/Thu/Sat | 5 batches, 5–8pm | basketball |
| Pushpak | Mon/Wed/Fri | 5–6pm, 6–7pm | *not stated — sport chosen per student* |
| Hill County | Tue/Thu/Sat | 5–6pm, 6–7pm | *not stated* |
| PRC | Mon–Fri | 5–6pm, 6–7pm | *not stated* |

`batches.sport` is **nullable** precisely because three centres run mixed
batches. Do not make it required.

---

## Architecture

One Supabase project — `ugsklcipzyiogxynshnh`, org "Academy Manager" — shared
with Leo, Machaxi, MatchPoint and Gen Alpha. Every row carries
`tenant_id = 'raj'`. New tables are **generic**, not `raj_*`, so the next
coaching client reuses them.

```
Raj Sports repo
├── index.html · login.html · today.html · students.html · student.html
│   reminders.html · fees.html · setup.html · attendance.html
│   coach.html                                       ← the web app (root = GitHub Pages)
│   (coach.html is the attendance-only screen; everything else needs staff)
├── assets/css/app.css                               ← the design system
├── assets/js/{cloud.js, core.js}                    ← data layer + shell
│   (the Android app is a SEPARATE repo: sujittarun/RajSportsApp)
└── supabase/
    ├── migration-raj.sql      schema + fee chain + payouts + WhatsApp tables
    ├── migration-raj-2.sql    public read for the timetable
    ├── migration-raj-3.sql    integrity guards + audit log + tenant_health
    ├── cron-raj.sql           the two scheduled jobs
    ├── sample-data.sql        demo data  (clear-sample-data.sql removes it)
    ├── test-migration*.sql    behaviour tests, run against live, rolled back
    └── functions/whatsapp-reminder/  the reminder engine (Deno edge function)
```

### The rule that keeps two clients honest

**Anything that computes money lives in Postgres.** The fee chain, the renewal
roll-forward and the payout split are SQL functions called by the web app, the
Android app *and* the reminder engine. No client does that arithmetic itself.
That is the only reason a parent's WhatsApp message and the manager's screen
can never quote different amounts.

If you add a money rule, add it to the database — never to a client.

---

## The fee chain

Most specific wins. `resolve_fee()` is the single resolver.

```
60  enrollment.custom_amount      "this student pays ₹X"        ← staff override
50  fee_rule on a member          "this family pays ₹X"
45  fee_rule on a batch           "the 7 AM batch is ₹X"
40  fee_rule on centre + sport    "basketball at BTV is ₹X"
30  fee_rule on sport             "basketball is ₹X anywhere"
20  fee_rule on centre            "everything at PRC is ₹X"
10  fee_rule with no scope        the tenant default
```

- `plan_amounts` jsonb gives a discounted 3/6-month price; missing keys fall
  back to `monthly_amount × months`.
- A partial unique index enforces **one active rule per scope** — otherwise the
  winning fee would depend on row order and the manager could not see which
  rule applied.
- `reminder_queue()` resolves through the same chain, and returns
  `fee_source` so every screen can say *where* the number came from.

**The client has not set real prices yet.** What is loaded is placeholder
sample data. Replace it in Setup → Fees.

---

## The billing unit is the ENROLLMENT, not the student

A child doing cricket *and* basketball is one `members` row and two
`enrollments` rows — each with its own fee, its own renewal date, and
potentially its own coach cut. Never collapse this back to one fee per student.

---

## Payouts — BUILT BUT HIDDEN

The client asked for payouts to come out of the UI for now. The tab is gone
from Setup and from Fees on both clients, but **the schema, `compute_payouts()`
and the payout RPCs are all intact and tested** — nothing was dropped. Turning
it back on is re-adding the tab, not rebuilding the feature. What follows
documents the model so it can return without being redesigned.

### How a PT master (or a centre) takes a cut

`payout_rules` is a (party × basis) pair, because real contracts take many
shapes:

| basis | meaning |
|---|---|
| `percent` | % of what was collected |
| `flat_per_student` | ₹X per active student per month |
| `monthly_retainer` | fixed ₹X/month (a venue rent, say) |
| `per_session` | ₹X per session actually held (needs `sessions` rows) |
| `flat_per_payment` | ₹X per payment collected |
| `slab` | banded by headcount, e.g. 40% up to 20 students then 50% |

`applies_on = 'net_after_centre'` is the common real arrangement: the school
takes its share of the gross, and the PT master splits **what is left**.
`compute_payouts()` therefore runs centre rules first. `min_guarantee` and
`max_cap` wrap the result, so "₹8,000 minimum or 40%, whichever is higher"
is expressible.

A payout line already marked **paid is never rewritten** by a recompute.

---

## WhatsApp reminders

The ladder (ported from the proven Gen Alpha engine):

```
-2 days   heads_up   soft nudge before the renewal date
 0 days   due        due today
+5 days   overdue    first chase
+7..+14   overdue    daily
+15 and beyond       STOP — manual follow-up only
```

- Only Meta error **131049** is auto-retried (5/30/60 min). `131026` and
  everything else means the message will never land — a human has to look.
  Retrying those just burns the number's reputation.
- A student is skipped before a reminder is even created if their
  `whatsapp_status` is `wrong_number` / `opted_out`, if there is no valid
  10-digit number, or if no fee is set. Each of those surfaces on the
  **Needs a call** tab with the reason in plain English.
- `reminder_events` has a partial unique index on `(tenant, enrollment,
  ist_date)`: one reminder per student per IST day, always.

### Where the parent pays

Raj coaches at venues he does not own, and several of them want the parents'
money in **their** account. So "where does this fee get paid" is a per-centre
and sometimes per-batch fact, and like every other money rule it resolves in
Postgres — `resolve_upi()`, migration `0038`:

```
45  batches.upi_id    "the 7am batch collects to its own account"
30  centres.upi_id    "everything at BTV collects to BTV"
10  tenants.config.billing.upiIds[0]   the academy's own default
```

`reminder_queue()` returns `upi_id`, `upi_name` and `upi_source` alongside the
fee, so the message, the manager's screen and the reminder engine cannot
disagree about which account a parent was asked to pay. Set it in
Setup → Centres, on the centre or on the batch; blank means "use the level
above", and the sheet says so out loud.

It goes out as a plain UPI id, not a `upi://` link. WhatsApp does not reliably
make one tappable, and a "tap to pay" that does nothing is worse than an id a
parent can paste into any UPI app.

**On the automatic path it needs an approved template.** The four template
variables are `{{1}}` student, `{{2}}` academy, `{{3}}` amount, `{{4}}` due
date. The account would be `{{5}}`, and sending a fifth parameter to a template
approved with four makes Meta reject every message — so it is gated behind
`config.whatsapp.upiParam`, off until the template really carries it.

### Manual mode is first-class, not a stub

`tenants.config.whatsapp.mode` is `manual` until Raj's own WhatsApp Business
number is approved. In manual mode:

- the daily cron **reports and writes nothing** — a `reminder_events` row must
  mean "we actually tried to reach this parent", or `tenant_health`'s
  sent/delivered counters quietly become fiction;
- the manager taps **WhatsApp** on the Reminders screen, which opens `wa.me`
  with the message pre-written and logs it via `log_manual_reminder()`.

**The message wording is identical in all three places** —
`App.reminderText()` (web), `Fmt.reminderText()` (Android) and
`messageBody()` (edge function). If you change one, change all three. A parent
must hear one voice from Raj Sports regardless of which path sent it.

That is now checked rather than remembered:

```bash
python3 scripts/check-message-parity.py
```

It executes the web and edge builders against the same rows and compares them
character for character, then asserts all three files, Android included, carry
every sentence fragment. Reword one and the other two fail.

Going live is a **config flip, not a deploy**: set `enabled: true`,
`mode: 'auto'`, `dryRun: false` on `tenants.config.whatsapp` once the WABA,
the phone number ID and the three approved templates exist.

---

## Adding a sport, a venue, or a batch time

These are routine edits, so the **server** owns the rules — not the UI, which
is one of two clients and will not always be the newest:

- `add_sport()`, `add_centre()`, `add_batch()`, `update_batch_timing()` are
  guarded RPCs. They mint a collision-safe code via `next_code()`, reject a
  duplicate name with a readable message, and validate the timing.
- Deleting a centre / batch / sport / coach that is **in use is refused** with
  a message the UI shows verbatim. Deactivate instead.
- Deactivating a batch **detaches its students** and leaves a note on the
  enrollment saying why — no student is left pointing at a class that stopped.
- `update_batch_timing()` writes a dedicated `timing_changed` audit row,
  because parents plan their week around it.

---

## Observability (what the Academy Manager console sees)

- `audit_log` — append-only, written only by SECURITY DEFINER triggers on every
  config table, with before/after and the actor's email. No-op writes are
  ignored so the log stays readable.
- `events` — page views, `student_added`, `payment_recorded`,
  `reminder_sent_manual`, `batch_timing_changed`, and **`client_error`**.
  Both apps install a global error handler; a broken screen is never a silent
  dead end.
- `tenant_health('raj')` — one round trip returning roster, money, reminders
  (sent / delivered / failed / retrying / blocked-by-reason), usage and
  **config completeness** (students with no fee, students with no phone).
  Misconfiguration is the quiet failure mode: reminders that never fire because
  nobody set a price. It is reported as a first-class signal.

---

## Conventions

- **Primary target is the phone.** Verify ≤699px first (375×812), then desktop.
- **Local dates only.** `toISOString()` is UTC and silently shifts an IST
  evening back a day, mis-stating a renewal. Web uses `App.isoDate()`, Android
  uses `Fmt.isoDate()`, Postgres uses `ist_today()`.
- **Design tokens live in two twinned files**: `assets/css/app.css` and
  `android-app/.../ui/Theme.kt`. Change one, change both.

### The visual language: "GROUNDS"

Warm paper, deep evergreen, quiet ink. **Light is the default and is not
system-following**: this app is read outdoors in daylight far more than at
night, so dark is opt-in. Three rules hold the language together:

1. **The accent is for action only.** Evergreen (`--volt`, kept as the token
   name so both twins line up) never appears in a list row and never states a
   fact. If something is green, you can press it or it is where you are.
2. **Paid is quiet.** A student who has paid needs no attention, so `--paid` is
   neutral grey. Colour is spent only on what needs doing, which leaves ochre
   and brick owning the eye by themselves. (Exception: the *Collected* metric
   uses plain ink. Paid needs no alarm colour; the month's takings still
   deserve to be readable.)
3. **One radius system.** Pills for anything pressable, 14px for surfaces, 10px
   for inputs and chips. Nothing sharp, nothing rounder than its parent.

An earlier build used an optic-lime accent on near-black. It was rejected as
too harsh on the eye. If you are tempted back toward a high-chroma accent,
remember the screen is read in sunlight between batches, not at a desk.

The logo is the **whistle**: it is the J in RAJ, and its lanyard returns under
SPORTS, so the lockup carries a coach's signature without bolting on a separate
sports pictogram. Never a monogram in a rounded square, and no longer the
stride mark (four sheared bars) that preceded it.

It lives in exactly two places and they are twins: `App.brandLogoSVG()` /
`App.markSVG()` in `assets/js/core.js`, and `BrandLockup()` / `BrandMark()` in
`RajSportsApp/.../ui/Brand.kt`, which parses the **same path strings** so the
two cannot drift. Change one, change the other, and keep the viewBox
(360x176 for the lockup, 48x48 for the mark). The Android launcher icon is
`ic_launcher_fg.xml`, where figure and ground swap because the icon background
is evergreen. Grain and the top-of-page warmth are deliberately faint;
both are `position: fixed` and `pointer-events: none` so they never repaint on
scroll.

### Choosers are rails, not stacks

Picking a centre, a sport and a batch used to be fifteen full-width cards
stacked in a sheet. It is now four numbered **one-line horizontal rails**, so
the whole decision stays on one screen and the running answer (with the
resolved fee and which rate produced it) sits underneath. Any future
multi-step choice should follow that shape rather than growing another stack.

**Zero em-dashes in anything a user reads** (UI copy, WhatsApp messages, toasts,
errors). Code comments are fine. This is a house rule from the anti-slop design
skill and the single most common tell.

### Motion

Every animation has a job. Numbers count up once on arrival because the number
is the news; the nav pill and the tab underline are ONE element that travels,
because five highlights blinking reads as five things and one thing moving
reads as your position; a reminder row can be swiped right to open WhatsApp
with velocity-based commit, because the queue is ten parents and one thumb.
The only looping animation in the app is the light sweep on the single lead
card. All of it collapses under `prefers-reduced-motion`.
- Filters with 3+ options use a dropdown, never a wrapping row of chips.
  Dense rows use `.status` (dot + coloured text), not filled pills.
- Bump `?v=N` on every css/js reference in **all** HTML files when assets change.
- Never present the app as a demo in UI copy.

## Auth

Lockdown is ON. Two signed-in roles, both real Supabase Auth users:

| `app_metadata.am_role` | sees | lands on |
|---|---|---|
| `staff` | everything | `today.html` |
| `coach` | the register, at their own centres only | `coach.html` |

Passwords live in `~/.supabase/am-dummy-logins.txt` (mode 600), never in the
repo — `login.html` used to prefill the staff password and that file is served
publicly by GitHub Pages, so it was a live credential on the open web. Replace
these with real accounts before handover.

Anon may read only `centres`, `batches`, `sports` (the public timetable) and
insert into `applications` (the enrolment form). Nothing with a person or a
rupee in it is readable without a staff token — `migration-raj-2.sql` asserts
this rather than trusting the policy text.

### The coach role, and why it is shaped this way

A coach takes the register. They are not the people who see fees, reminders or
a parent's phone number. Migration `0039` (shared scope) adds:

- `staff_scopes` — who is assigned to which centres.
- `my_centres(tenant)`, `my_attendance_batches(tenant, date)`, `my_access()` —
  the only way a coach discovers anything. `my_access()` is what both clients
  route on after sign-in.
- `assert_attendance_access(tenant, batch)` — replaces `assert_staff_or_service`
  in `mark_attendance`, `attendance_roster` and `save_attendance_session`.

**`assert_staff()` was deliberately NOT loosened.** That one line guards
`record_fee_payment`, `reminder_queue`, payouts and every other definer
function on the platform; widening it to let a coach mark a register would
have handed them the whole academy. A coach passes no RLS policy either
(every one tests `auth_role() = 'staff'`), so the tables return nothing to
them and the guarded functions are their entire reach.

`attendance_history()` and `attendance_dashboard()` keep the staff guard on
purpose: their `p_batch` is an optional **filter**, so a per-batch check would
wave a null straight through and hand over every centre.

The proof is behavioural, not a reading of the grants:
`AcademyManager/supabase/tests/0039-attendance-access.sql` signs in as a coach
and asserts what they can and cannot reach. Run it with
`AcademyManager/scripts/run-test.sh <migration> <test>`; it is mutation-tested,
so it fails when the guard is broken.

## Working on this

```bash
npx http-server -p 8135 -c-1 .          # the web app
cd android-app && ./gradlew :app:assembleDebug
python3 scripts/check-message-parity.py  # the reminder wording, all three clients
./scripts/dry-run.sh supabase/x.sql     # validate against live, roll back
./scripts/test-migration.sh             # behaviour tests, roll back
../AcademyManager/scripts/migrate.sh --scope raj supabase/x.sql   # apply for real (ledger-checked)
```

`scripts/dry-run.sh` and `scripts/test-migration*.sh` run the SQL against the
**real** schema inside a transaction and roll it back. Use them before every
apply — this database has four other live tenants in it.
