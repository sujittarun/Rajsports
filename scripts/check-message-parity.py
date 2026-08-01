#!/usr/bin/env python3
"""The parent must hear one voice from Raj Sports.

The reminder wording exists three times — App.reminderText() on the web,
Fmt.reminderText() on Android and messageBody() in the edge function —
because each runs somewhere the others cannot. Three copies drift, and
the day they do a parent gets one message from the nightly cron and a
different one from the manager's thumb.

Two checks, because two are runnable and one is not:

  1. The web and the edge function are executed against the same rows
     and their output compared character for character.
  2. All three, Android included, must contain every sentence fragment
     the message is built from. Reword one and the other two fail.

    python3 scripts/check-message-parity.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANDROID = os.path.join(os.path.dirname(ROOT), "RajSportsApp")

WEB   = os.path.join(ROOT, "assets/js/core.js")
EDGE  = os.path.join(ROOT, "supabase/functions/whatsapp-reminder/index.ts")
KT    = os.path.join(ANDROID, "app/src/main/java/in/rajsports/manager/ui/Fmt.kt")

# Every static fragment the message is assembled from. If a sentence is
# reworded in one place, the other two no longer contain it.
FRAGMENTS = [
    "Hello! ",
    "'s coaching fee at ",
    " is due on ",
    " is due today.",
    " Amount: ",
    " Sharing this early so you can plan.",
    " Kindly complete the payment to continue the batch.",
    "Hello! A gentle reminder that ",
    " is pending",
    " overdue",
    " Please clear it so ",
    " does not miss sessions. Do reply if you need any help.",
    " Pay to UPI: ",
]

ROWS = [
    {"member_name": "Aarav", "stage": "heads_up", "amount": 1500, "due_date": "2026-08-05",
     "centre": "BTV", "sport": "basketball", "days_since": -2,
     "upi_id": "btv@okaxis", "upi_name": "BTV Sports"},
    {"member_name": "Diya", "stage": "due", "amount": 2000, "due_date": "2026-08-01",
     "centre": "Pushpak", "sport": None, "days_since": 0,
     "upi_id": "raj@okhdfcbank", "upi_name": None},
    {"member_name": "Kabir", "stage": "overdue", "amount": None, "due_date": "2026-07-20",
     "centre": None, "sport": "tennis", "days_since": 12,
     "upi_id": None, "upi_name": None},
    {"member_name": "Ira", "stage": "overdue", "amount": 900, "due_date": "2026-07-31",
     "centre": "PRC", "sport": "cricket", "days_since": 1,
     "upi_id": "prc.sports@ybl", "upi_name": "PRC Academy"},
]


def run_web(rows):
    """core.js is a browser IIFE, so it needs a window before it will load."""
    script = f"""
      global.window = global;
      global.document = {{
        documentElement: {{ setAttribute: () => {{}} }},
        querySelector: () => null, querySelectorAll: () => [],
        addEventListener: () => {{}},
      }};
      global.localStorage = {{ getItem: () => null, setItem: () => {{}} }};
      global.matchMedia = () => ({{ matches: false, addEventListener: () => {{}} }});
      window.matchMedia = global.matchMedia;
      Object.defineProperty(global, 'RS', {{ value: {{ track: () => {{}} }}, writable: true }});
      require({json.dumps(WEB)});
      const rows = {json.dumps(rows)};
      console.log(JSON.stringify(rows.map(r => window.App.reminderText(r, {{ brand: "Raj Sports" }}))));
    """
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(script); path = f.name
    try:
        out = subprocess.run(["node", path], capture_output=True, text=True)
        if out.returncode:
            return None, out.stderr.strip()
        return json.loads(out.stdout.strip().splitlines()[-1]), None
    finally:
        os.unlink(path)


def run_edge(rows):
    """messageBody() is module-private, so the harness imports the source
       text and evaluates just that function plus what it needs."""
    src = open(EDGE, encoding="utf-8").read()

    def block(start):
        """A whole declaration: balanced braces for a function, to the
           first top-level semicolon for a const."""
        i = src.index(start)
        depth, j = 0, i
        while j < len(src):
            c = src[j]
            if c in "{([":
                depth += 1
            elif c in "})]":
                depth -= 1
            elif c == ";" and depth == 0 and start.startswith("const"):
                return src[i:j + 1]
            if depth == 0 and c == "}" and start.startswith("function"):
                return src[i:j + 1]
            j += 1
        raise ValueError(f"could not delimit {start!r}")

    keep = [block(n) for n in ["const cap =", "const money =", "function longDate",
                               "function upiLine", "function messageBody"]]
    script = ("type QueueRow = any; type WaConfig = any;\n" + "\n".join(keep) +
              f"\nconst rows = {json.dumps(rows)};\n" +
              'console.log(JSON.stringify(rows.map((r: any) => '
              'messageBody(r, { brand: "Raj Sports" }))));\n')
    with tempfile.NamedTemporaryFile("w", suffix=".ts", delete=False) as f:
        f.write(script); path = f.name
    try:
        out = subprocess.run(["deno", "run", "--no-check", path],
                             capture_output=True, text=True)
        if out.returncode:
            return None, out.stderr.strip()
        return json.loads(out.stdout.strip().splitlines()[-1]), None
    finally:
        os.unlink(path)


def main() -> int:
    failures = []

    # ---- 1. the two runnable ones, compared exactly ----
    web, werr = run_web(ROWS)
    edge, eerr = run_edge(ROWS)
    if werr:
        failures.append(f"could not run the web builder: {werr}")
    if eerr:
        failures.append(f"could not run the edge builder: {eerr}")

    if web and edge:
        for i, (a, b) in enumerate(zip(web, edge)):
            if a != b:
                failures.append(
                    f"row {i} ({ROWS[i]['stage']}) differs between web and edge:\n"
                    f"      web  {a!r}\n      edge {b!r}")
        if not failures:
            print("✓ web and edge produce identical text for every stage. Sample:")
            for a in web:
                print(f"    {a}")

    # ---- 2. all three must carry every fragment ----
    print()
    for label, path in [("web", WEB), ("edge", EDGE), ("android", KT)]:
        if not os.path.exists(path):
            failures.append(f"missing {label}: {path}")
            continue
        text = open(path, encoding="utf-8").read()
        missing = [f for f in FRAGMENTS if f not in text]
        if missing:
            failures.append(f"{label} ({os.path.relpath(path, ROOT)}) is missing: " +
                            ", ".join(repr(m) for m in missing))
        else:
            print(f"✓ {label} carries all {len(FRAGMENTS)} message fragments")

    if failures:
        print("\n✗ the reminder wording has drifted:\n")
        for f in failures:
            print(f"  · {f}")
        print("\nA parent would hear two different voices from Raj Sports "
              "depending on which path sent the message. Fix all three.")
        return 1
    print("\n✓ one voice.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
