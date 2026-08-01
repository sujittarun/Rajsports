/* ============================================================
   RAJ SPORTS — app shell (window.App)
   Brand mark, theme, formatting, and the motion layer.

   Motion rules this file obeys (every animation here has a job):
   · Numbers count up ONCE on arrival, because the number is the
     news. Nothing loops except the sweep on the single lead card.
   · The nav indicator and the tab underline are ONE element that
     travels. Separate highlights fading in and out reads as many things
     blinking; one thing moving reads as your position.
   · Anything the user can drag keeps its velocity, so a flick works
     as well as a deliberate pull.
   · Everything collapses under prefers-reduced-motion.
   ============================================================ */
(function () {
  "use strict";

  var THEME_KEY = "rs-theme";
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------------- brand ----------------
     The whistle is the J in RAJ. Its lanyard returns under SPORTS,
     giving the lockup a coach's signature without adding a separate
     sports pictogram. Colours follow the active GROUNDS theme. */
  function brandLogoSVG(width, extraClass) {
    width = width || 150;
    return '<svg class="brand-logo' + (extraClass ? " " + extraClass : "") +
      '" style="width:' + width + 'px" viewBox="0 0 360 176" role="img" ' +
      'aria-label="Raj Sports">' +
      '<path class="brand-ink" fill-rule="evenodd" d="' +
        'M31 30h48c23 0 38 12 38 32 0 15-8 25-23 30l26 28H91L67 93H55v27H31a5 5 0 0 1-5-5V35a5 5 0 0 1 5-5Zm24 20v24h22c11 0 17-4 17-12s-6-12-17-12H55Z"/>' +
      '<path class="brand-ink" fill-rule="evenodd" d="' +
        'M133 120h-25l36-84c2-4 5-6 10-6h12c5 0 8 2 10 6l35 84h-26l-8-21h-34l-10 21Zm19-42h17l-8-24h-1l-8 24Z"/>' +
      '<path class="brand-green" d="' +
        'M223 37h27v52c0 20-12 33-30 33-17 0-29-11-29-27 0-14 9-24 23-28l3-1 1-24c0-3 2-5 5-5Z"/>' +
      '<path class="brand-green-dark" d="' +
        'm250 37 7-6v57c0 18-7 29-20 35 8-8 12-18 12-32l1-54Z"/>' +
      '<path class="brand-paper" d="m220 32 8-7h26c3 0 4 3 1 5l-8 7h-27Z"/>' +
      '<path class="brand-seam" d="M248 38v54c0 11-3 19-10 26"/>' +
      '<circle class="brand-hole" cx="220" cy="92" r="15"/>' +
      '<path class="brand-accent" d="m250 57 7-5v10l-7 5V57Z"/>' +
      '<path class="brand-lanyard" d="' +
        'M253 91c8-3 12 0 11 6-1 4-6 4-8 1 14 0 25 18 25 39 0 20-11 29-30 30-43 3-91-7-142-7-38 0-63 6-79 6"/>' +
      '<path class="brand-lanyard" d="' +
        'M31 166c-15 8-25 3-25-4 0-8 11-13 24-9l14 5-13 8Z"/>' +
      '<rect class="brand-accent" x="41" y="154" width="9" height="9" rx="2"/>' +
      '<text class="brand-sports" x="27" y="146">SPORTS</text>' +
    "</svg>";
  }

  /* The compact whistle mark is reserved for very small placements. */
  function markSVG(size) {
    size = size || 30;
    return '<svg class="mark" style="width:' + size + "px;height:" + size + 'px" ' +
      'viewBox="0 0 48 48" aria-hidden="true">' +
      '<path class="brand-green" d="M18 9h17v20c0 9-6 15-15 15S5 38 5 30c0-7 5-12 12-14l1-1V9Z"/>' +
      '<path class="brand-green-dark" d="m35 9 5-4v23c0 9-4 14-10 17 3-4 5-9 5-15V9Z"/>' +
      '<path class="brand-paper" d="m17 7 5-5h17c2 0 2 2 1 3l-5 4H18Z"/>' +
      '<path class="brand-seam" d="M35 9v21c0 5-2 9-5 12"/>' +
      '<circle class="brand-hole" cx="20" cy="30" r="7"/>' +
      '<path class="brand-accent" d="m35 17 5-4v7l-5 4v-7Z"/>' +
      '<path class="brand-lanyard" d="M38 30c5-2 7 1 5 4-2 2-5 0-4-2 5 1 7 5 7 10"/>' +
      "</svg>";
  }
  function wordmark() {
    return brandLogoSVG(150);
  }

  /* ---------------- theme ---------------- */
  function applyTheme(t) {
    document.documentElement.setAttribute("data-theme", t);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", t === "dark" ? "#14150f" : "#f6f5f1");
  }
  // Light by default. This app lives outdoors in daylight; dark is
  // opt-in, not a system-follow.
  function theme() { try { return localStorage.getItem(THEME_KEY) || "light"; } catch (e) { return "light"; } }
  function resolved() {
    var t = theme();
    if (t === "dark" || t === "light") return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  function setTheme(t) {
    try { localStorage.setItem(THEME_KEY, t); } catch (e) {}
    applyTheme(resolved());
  }
  applyTheme(resolved());
  if (window.matchMedia) {
    window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", function () {
      if (theme() === "auto") applyTheme(resolved());
    });
  }

  /* ---------------- formatting ----------------
     Local dates only. toISOString() is UTC and silently shifts an IST
     evening back a day, which would misdate a renewal. */
  function isoDate(d) {
    d = d || new Date();
    return d.getFullYear() + "-" +
           String(d.getMonth() + 1).padStart(2, "0") + "-" +
           String(d.getDate()).padStart(2, "0");
  }
  function parseDate(s) {
    if (!s) return null;
    var p = String(s).slice(0, 10).split("-");
    return new Date(+p[0], +p[1] - 1, +p[2]);
  }
  function money(n) {
    if (n === null || n === undefined || n === "") return "—".replace("—", "0");
    return "₹" + Math.round(Number(n)).toLocaleString("en-IN");
  }
  function moneyOrDash(n) {
    if (n === null || n === undefined || n === "") return "not set";
    return money(n);
  }
  function shortDate(s) {
    var d = parseDate(s);
    return d ? d.toLocaleDateString("en-IN", { day: "numeric", month: "short" }) : "";
  }
  function longDate(s) {
    var d = parseDate(s);
    return d ? d.toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" }) : "";
  }
  function relativeTime(value) {
    var then = new Date(value);
    if (!value || isNaN(then.getTime())) return "";
    var now = new Date();
    var seconds = Math.max(0, Math.floor((now.getTime() - then.getTime()) / 1000));
    if (seconds < 60) return "just now";
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return minutes + (minutes === 1 ? " min ago" : " mins ago");
    var hours = Math.floor(minutes / 60);
    if (hours < 24) return hours + (hours === 1 ? " hr ago" : " hrs ago");
    var yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
    if (then.getFullYear() === yesterday.getFullYear() &&
        then.getMonth() === yesterday.getMonth() &&
        then.getDate() === yesterday.getDate()) return "yesterday";
    var daysAgo = Math.floor((new Date(now.getFullYear(), now.getMonth(), now.getDate()) -
                              new Date(then.getFullYear(), then.getMonth(), then.getDate())) / 86400000);
    if (daysAgo < 7) return daysAgo + " days ago";
    return then.toLocaleDateString("en-IN", { day: "numeric", month: "short" });
  }
  function timeOf(t) {
    if (!t) return "";
    var p = String(t).split(":"), h = +p[0], m = p[1];
    var ap = h >= 12 ? "pm" : "am";
    h = h % 12 || 12;
    return h + (m !== "00" ? ":" + m : "") + ap;
  }
  var DAYNAMES = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  function days(arr) {
    if (!arr || !arr.length) return "";
    var s = arr.slice().sort(function (a, b) { return a - b; });
    var run = s.length > 2 && s.every(function (d, i) { return i === 0 || d === s[i - 1] + 1; });
    return run ? DAYNAMES[s[0]] + " to " + DAYNAMES[s[s.length - 1]]
               : s.map(function (d) { return DAYNAMES[d]; }).join(", ");
  }
  function initials(name) {
    return String(name || "?").trim().split(/\s+/).slice(0, 2)
      .map(function (w) { return w[0]; }).join("").toUpperCase();
  }
  function daysBetween(a, b) {
    var d1 = parseDate(a), d2 = parseDate(b) || new Date();
    if (!d1) return null;
    d2 = new Date(d2.getFullYear(), d2.getMonth(), d2.getDate());
    return Math.round((d2 - d1) / 86400000);
  }
  function esc(s) {
    return String(s === null || s === undefined ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  function cap(s) { return String(s || "").charAt(0).toUpperCase() + String(s || "").slice(1); }
  function phone10(p) {
    var d = String(p || "").replace(/\D/g, "");
    return d.length > 10 ? d.slice(-10) : d;
  }
  function waNumber(p) { var d = phone10(p); return d.length === 10 ? "91" + d : ""; }

  /* ---------------- fee state ----------------
     The one place that decides paid / due / overdue, so the roster,
     the dashboard and the reminder screen can never disagree. */
  function feeState(renewalOn) {
    if (!renewalOn) return { key: "unset", label: "No renewal date", cls: "status-muted", days: null };
    var n = daysBetween(renewalOn, null);
    if (n === null) return { key: "unset", label: "Not set", cls: "status-muted", days: null };
    if (n > 0)      return { key: "overdue", label: n + (n === 1 ? " day late" : " days late"),
                             cls: "status-overdue", days: n };
    if (n === 0)    return { key: "due", label: "Due today", cls: "status-due", days: 0 };
    if (n >= -7)    return { key: "soon", label: "Due in " + (-n) + (n === -1 ? " day" : " days"),
                             cls: "status-due", days: n };
    return { key: "paid", label: "Paid to " + shortDate(renewalOn), cls: "status-paid", days: n };
  }

  /* ---------------- count up ----------------
     A number that lands rather than appears. Runs once, on arrival,
     and only for values worth noticing. */
  function countUp(el, to, opts) {
    opts = opts || {};
    var fmt = opts.format || function (v) { return String(Math.round(v)); };
    if (reduced || !to) { el.textContent = fmt(to || 0); return; }
    var dur = opts.duration || 850, start = null, from = 0;
    function frame(ts) {
      if (start === null) start = ts;
      var p = Math.min((ts - start) / dur, 1);
      // ease-out cubic: fast arrival, gentle settle
      var e = 1 - Math.pow(1 - p, 3);
      el.textContent = fmt(from + (to - from) * e);
      if (p < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }
  function countMoney(el, to) {
    countUp(el, to, { format: function (v) { return money(v); } });
  }

  /* ---------------- toast ---------------- */
  function toastHost() {
    var el = document.querySelector(".toasts");
    if (!el) { el = document.createElement("div"); el.className = "toasts"; document.body.appendChild(el); }
    return el;
  }
  function toast(msg, kind) {
    var t = document.createElement("div");
    t.className = "toast" + (kind ? " toast-" + kind : "");
    t.textContent = msg;
    toastHost().appendChild(t);
    setTimeout(function () {
      t.setAttribute("data-leaving", "");
      setTimeout(function () { t.remove(); }, 380);
    }, kind === "bad" ? 4200 : 2600);
  }

  /* ---------------- sheet ----------------
     Drag the grip to dismiss, with damping past the top edge and
     velocity-based commit: a quick flick closes it even if it barely
     moved, which is how a real drawer behaves. */
  var openSheet = null;
  function sheet(opts) {
    closeSheet();
    var scrim = document.createElement("div");
    scrim.className = "scrim";
    var el = document.createElement("div");
    el.className = "sheet";
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-modal", "true");
    el.innerHTML = '<div class="sheet-grip"></div>' +
      (opts.title ? "<h2>" + esc(opts.title) + "</h2>" : "") + (opts.html || "");
    document.body.appendChild(scrim);
    document.body.appendChild(el);
    requestAnimationFrame(function () {
      scrim.setAttribute("data-open", "");
      el.setAttribute("data-open", "");
    });
    scrim.addEventListener("click", closeSheet);
    document.addEventListener("keydown", onEsc);
    openSheet = { el: el, scrim: scrim, onClose: opts.onClose };

    dragToDismiss(el);
    if (opts.onMount) opts.onMount(el);
    var f = el.querySelector("input, select, textarea, button");
    if (f && window.innerWidth >= 700) setTimeout(function () { f.focus(); }, 240);
    return el;
  }

  function dragToDismiss(el) {
    if (window.innerWidth >= 700) return;   // desktop shows a centred modal
    var grip = el.querySelector(".sheet-grip");
    if (!grip) return;
    var y0 = 0, t0 = 0, dy = 0, active = false;

    grip.addEventListener("pointerdown", function (e) {
      active = true; y0 = e.clientY; t0 = Date.now(); dy = 0;
      el.classList.add("is-dragging");
      grip.setPointerCapture(e.pointerId);   // keep events even if the finger leaves
    });
    grip.addEventListener("pointermove", function (e) {
      if (!active) return;
      dy = e.clientY - y0;
      // Dragging up is allowed but heavily damped. Things in the real
      // world slow before they stop; they do not hit a wall.
      if (dy < 0) dy = dy / 6;
      el.style.transform = "translateY(" + dy + "px)";
    });
    function end() {
      if (!active) return;
      active = false;
      el.classList.remove("is-dragging");
      el.style.transform = "";
      var v = Math.abs(dy) / Math.max(Date.now() - t0, 1);
      if (dy > el.offsetHeight * 0.32 || (dy > 40 && v > 0.45)) closeSheet();
    }
    grip.addEventListener("pointerup", end);
    grip.addEventListener("pointercancel", end);
  }

  function onEsc(e) { if (e.key === "Escape") closeSheet(); }
  function closeSheet() {
    if (!openSheet) return;
    var s = openSheet; openSheet = null;
    document.removeEventListener("keydown", onEsc);
    s.el.removeAttribute("data-open");
    s.scrim.removeAttribute("data-open");
    setTimeout(function () { s.el.remove(); s.scrim.remove(); }, 480);
    if (s.onClose) s.onClose();
  }

  function confirmSheet(opts) {
    return new Promise(function (resolve) {
      var done = false;
      sheet({
        title: opts.title,
        html: '<p class="muted small">' + esc(opts.body || "") + "</p>" +
              '<div class="stack mt-2">' +
              '<button class="btn btn-block ' + (opts.danger ? "btn-danger" : "btn-primary") +
              '" data-yes>' + esc(opts.confirm || "Confirm") + "</button>" +
              '<button class="btn btn-block" data-no>Cancel</button></div>',
        onMount: function (el) {
          el.querySelector("[data-yes]").addEventListener("click", function () {
            done = true; closeSheet(); resolve(true);
          });
          el.querySelector("[data-no]").addEventListener("click", closeSheet);
        },
        onClose: function () { if (!done) resolve(false); }
      });
    });
  }

  /* ---------------- swipe to send ----------------
     The queue is ten parents and one thumb. Dragging a row to the
     right past the threshold fires the action, so the list can be
     cleared without aiming at anything. Velocity counts, so a flick
     works too. The button stays for anyone who prefers to tap. */
  function swipeRow(node, onCommit) {
    if (reduced) return;
    var face = node.querySelector(".swipe-face");
    if (!face) return;
    var x0 = 0, y0 = 0, t0 = 0, dx = 0, active = false, decided = false, horizontal = false;
    var THRESHOLD = 96;

    face.addEventListener("pointerdown", function (e) {
      if (e.target.closest("button, a")) return;   // let controls win
      active = true; decided = false; horizontal = false;
      x0 = e.clientX; y0 = e.clientY; t0 = Date.now(); dx = 0;
    });
    face.addEventListener("pointermove", function (e) {
      if (!active) return;
      var mx = e.clientX - x0, my = e.clientY - y0;
      // Decide once whether this gesture is a swipe or a scroll, then
      // stay decided. Re-deciding mid-drag is what makes lists feel
      // like they are fighting the finger.
      if (!decided && (Math.abs(mx) > 8 || Math.abs(my) > 8)) {
        decided = true;
        horizontal = Math.abs(mx) > Math.abs(my);
        if (horizontal) {
          node.classList.add("is-dragging");
          face.setPointerCapture(e.pointerId);
        }
      }
      if (!horizontal) return;
      dx = Math.max(0, mx);                        // right only
      if (dx > THRESHOLD) dx = THRESHOLD + (dx - THRESHOLD) / 3;   // damped past commit
      face.style.transform = "translateX(" + dx + "px)";
    });
    function end() {
      if (!active) return;
      active = false;
      if (!horizontal) return;
      node.classList.remove("is-dragging");
      var v = dx / Math.max(Date.now() - t0, 1);
      var commit = dx > THRESHOLD || (dx > 34 && v > 0.4);
      face.style.transform = "";
      if (commit) onCommit();
    }
    face.addEventListener("pointerup", end);
    face.addEventListener("pointercancel", end);
  }

  /* ---------------- travelling indicators ---------------- */
  function slideTo(pill, target, host) {
    if (!pill || !target) return;
    var a = target.getBoundingClientRect(), b = host.getBoundingClientRect();
    pill.style.width = a.width + "px";
    pill.style.transform = "translateX(" + (a.left - b.left) + "px)";
  }

  /** Underline that travels between tab buttons. */
  function tabInk(host) {
    var ink = host.querySelector(".tab-ink");
    if (!ink) { ink = document.createElement("div"); ink.className = "tab-ink"; host.appendChild(ink); }
    function place() {
      var on = host.querySelector('button[aria-selected="true"]');
      slideTo(ink, on, host);
    }
    requestAnimationFrame(place);
    window.addEventListener("resize", place);
    return place;
  }

  /* ---------------- WhatsApp copy ----------------
     The exact words a parent reads. Kept identical to Fmt.reminderText()
     in the Android app and messageBody() in the edge function, so a
     hand-sent and an auto-sent reminder are indistinguishable. */
  /* Where this parent pays. The account is resolved in Postgres by
     resolve_upi() (batch, then centre, then the academy) and arrives on
     the queue row, so a BTV parent and a Pushpak parent are told
     different accounts without either client deciding which.

     A plain UPI id, not a upi:// link: WhatsApp does not reliably turn
     one into something tappable, and a "tap to pay" that does nothing
     is worse than an id a parent can paste into any UPI app. */
  function upiLine(r) {
    if (!r || !r.upi_id) return "";
    return " Pay to UPI: " + r.upi_id + (r.upi_name ? " (" + r.upi_name + ")" : "") + ".";
  }

  function reminderText(r, cfg) {
    var brand = (cfg && cfg.brand) || "Raj Sports";
    var name = r.member_name || "your child";
    var amt = r.amount != null ? money(r.amount) : "";
    var where = [r.centre, r.sport ? cap(r.sport) : null].filter(Boolean).join(", ");
    var at = where ? " (" + where + ")" : "";
    var pay = upiLine(r);

    if (r.stage === "heads_up") {
      return "Hello! " + name + "'s coaching fee at " + brand + at +
        " is due on " + longDate(r.due_date) + "." +
        (amt ? " Amount: " + amt + "." : "") +
        " Sharing this early so you can plan." + pay;
    }
    if (r.stage === "due") {
      return "Hello! " + name + "'s coaching fee at " + brand + at + " is due today." +
        (amt ? " Amount: " + amt + "." : "") +
        " Kindly complete the payment to continue the batch." + pay;
    }
    var n = r.days_since || 0;
    return "Hello! A gentle reminder that " + name + "'s coaching fee at " + brand + at +
      " is pending" + (n > 0 ? ", " + n + (n === 1 ? " day" : " days") + " overdue" : "") + "." +
      (amt ? " Amount: " + amt + "." : "") +
      " Please clear it so " + name + " does not miss sessions. Do reply if you need any help." + pay;
  }

  function waLink(phone, text) {
    var n = waNumber(phone);
    return n ? "https://wa.me/" + n + "?text=" + encodeURIComponent(text) : null;
  }
  function telLink(phone) {
    var n = phone10(phone);
    return n ? "tel:+91" + n : null;
  }

  /* ---------------- nav ---------------- */
  var ICONS = {
    today:     '<path d="M4 11.2 12 4.8l8 6.4V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z"/>',
    students:  '<circle cx="12" cy="8.2" r="3.6"/><path d="M4.8 20a7.2 7.2 0 0 1 14.4 0"/>',
    attendance:'<path d="M5 4h14v16H5z"/><path d="m8 9 2 2 5-5M8 16h8"/>',
    reminders: '<path d="M20.5 11.4a8 8 0 0 1-8.6 8 8 8 0 0 1-3.8-1L3.5 20l1.1-4.6a8 8 0 1 1 15.9-4Z"/>',
    fees:      '<path d="M7 5h9a3.6 3.6 0 0 1 0 7.2H7"/><path d="M7 8.6h11"/><path d="M7 12.2h4.6"/><path d="m11.6 12.2 5.8 7"/>',
    setup:     '<path d="M9.5 3h5l.7 2.1 2 .8 2-.9 2.5 4.3-1.7 1.5v2.4l1.7 1.5-2.5 4.3-2-.9-2 .8-.7 2.1h-5l-.7-2.1-2-.8-2 .9-2.5-4.3L4 13.2v-2.4L2.3 9.3 4.8 5l2 .9 2-.8z"/><circle cx="12" cy="12" r="3"/>'
  };
  var TABS = [
    { href: "today.html",     key: "today",     label: "Today" },
    { href: "students.html",  key: "students",  label: "Students" },
    { href: "attendance.html",key: "attendance",label: "Attend" },
    { href: "reminders.html", key: "reminders", label: "Reminders" },
    { href: "fees.html",      key: "fees",      label: "Fees" }
  ];

  function shell(active, title, opts) {
    opts = opts || {};
    var top = document.querySelector(".topbar");
    if (top && !top.dataset.built) {
      top.dataset.built = "1";
      top.innerHTML =
        '<div class="topbar-in">' +
          '<a class="topbar-brand" href="' + (opts.minimal ? "coach.html" : "today.html") +
          '" aria-label="Go to ' + (opts.minimal ? "Attendance" : "Today") + '">' +
            brandLogoSVG(92, "brand-logo--topbar") +
          "</a>" +
          "<h1>" + esc(title || "Raj Sports") + "</h1>" +
          '<button class="icon-btn" data-theme-toggle aria-label="Switch theme">' +
            (resolved() === "dark" ? "☀" : "☾") + "</button>" +
          (active === "setup" || opts.minimal ? "" :
            '<a class="icon-btn" href="setup.html" aria-label="Open setup">' +
              '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICONS.setup + "</svg></a>") +
          '<button class="icon-btn" data-signout aria-label="Sign out">' +
            '<svg viewBox="0 0 24 24" aria-hidden="true">' +
              '<path d="M14 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-3"/>' +
              '<path d="M10 12h11m-4-4 4 4-4 4"/>' +
            "</svg></button>" +
        "</div>";
      top.querySelector("[data-theme-toggle]").addEventListener("click", function () {
        setTheme(resolved() === "dark" ? "light" : "dark");
        this.textContent = resolved() === "dark" ? "☀" : "☾";
      });
      top.querySelector("[data-signout]").addEventListener("click", function () {
        RS.signOut();
        location.replace("./");
      });
    }

    var nav = document.querySelector(".nav");
    if (nav && !nav.dataset.built) {
      nav.dataset.built = "1";
      nav.innerHTML = '<div class="nav-in"><div class="nav-pill"></div>' + TABS.map(function (t) {
        return '<a href="' + t.href + '"' + (t.key === active ? ' aria-current="page"' : "") + ">" +
          '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" ' +
          'stroke-linecap="round" stroke-linejoin="round">' + ICONS[t.key] + "</svg>" +
          "<span>" + t.label + "</span></a>";
      }).join("") + "</div>";

      var host = nav.querySelector(".nav-in");
      var pill = nav.querySelector(".nav-pill");
      var current = nav.querySelector('a[aria-current="page"]');
      function place() { slideTo(pill, current, host); }
      // Two frames: one for layout, one so the pill has a from-state
      // to spring out of instead of appearing already in place.
      requestAnimationFrame(function () {
        pill.style.transition = "none";
        place();
        requestAnimationFrame(function () { pill.style.transition = ""; });
      });
      window.addEventListener("resize", place);
    }
  }

  function navBadge(n) {
    var link = document.querySelector('.nav a[href="reminders.html"]');
    if (!link) return;
    var old = link.querySelector(".badge");
    if (old) old.remove();
    if (!n) return;
    var b = document.createElement("span");
    b.className = "badge";
    b.textContent = n > 99 ? "99+" : n;
    link.querySelector("svg").insertAdjacentElement("afterend", b);
  }

  /* Where a signed-in person belongs. A coach can only reach the
     attendance functions, so every other screen would load as a wall of
     empty lists and permission errors. Send them to the one page that
     works instead of letting them discover that themselves. */
  function homeFor(role) { return role === "coach" ? "coach.html" : "today.html"; }

  function requireStaff() {
    if (!RS.signedIn()) {
      location.replace("login.html?next=" + encodeURIComponent(location.pathname.split("/").pop()));
      return false;
    }
    if (RS.role() === "coach") { location.replace("coach.html"); return false; }
    return true;
  }

  function requireSignedIn() {
    if (!RS.signedIn()) {
      location.replace("login.html?next=" + encodeURIComponent(location.pathname.split("/").pop()));
      return false;
    }
    return true;
  }

  /* ---------------- DOM helpers ---------------- */
  function $(s, r) { return (r || document).querySelector(s); }
  function $$(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
  function el(html) { var d = document.createElement("div"); d.innerHTML = html.trim(); return d.firstElementChild; }
  function skeleton(host, rows) {
    host.innerHTML = new Array(rows || 4).fill('<div class="skeleton skeleton-row"></div>').join("");
  }
  function fail(host, err) {
    host.innerHTML = '<div class="empty"><div class="empty-t">Could not load</div>' +
      '<div class="small">' + esc((err && err.message) || "Check your connection and try again.") + "</div></div>";
  }
  function empty(host, title, sub) {
    host.innerHTML = '<div class="empty"><div class="empty-t">' + esc(title) + "</div>" +
      (sub ? '<div class="small">' + esc(sub) + "</div>" : "") + "</div>";
  }

  /* A timeline entry's money comes from meta.amount and is formatted
     HERE, by the same money() every other screen uses. Older rows were
     written with the figure baked into the title, so those are shown
     as-is rather than rewritten. */
  function timelineLine(t) {
    var meta = t.meta || {};
    var bits = [];
    if (meta.amount != null) bits.push(money(meta.amount));
    if (meta.months)  bits.push(meta.months + (meta.months === 1 ? " month" : " months"));
    if (meta.mode)    bits.push(meta.mode);
    if (t.body)       bits.push(t.body);
    return { title: t.title, detail: bits.join(" · ") };
  }

  window.App = {
    reduced: reduced,
    brandLogoSVG: brandLogoSVG, markSVG: markSVG, wordmark: wordmark,
    setTheme: setTheme, theme: theme, resolvedTheme: resolved,
    isoDate: isoDate, parseDate: parseDate, money: money, moneyOrDash: moneyOrDash,
    shortDate: shortDate, longDate: longDate, relativeTime: relativeTime, timeOf: timeOf, days: days,
    initials: initials, daysBetween: daysBetween, esc: esc, cap: cap,
    phone10: phone10, waNumber: waNumber, waLink: waLink, telLink: telLink,
    feeState: feeState, reminderText: reminderText, timelineLine: timelineLine,
    countUp: countUp, countMoney: countMoney,
    swipeRow: swipeRow, tabInk: tabInk, navBadge: navBadge,
    toast: toast, sheet: sheet, closeSheet: closeSheet, confirm: confirmSheet,
    shell: shell, requireStaff: requireStaff, requireSignedIn: requireSignedIn,
    homeFor: homeFor,
    $: $, $$: $$, el: el, skeleton: skeleton, fail: fail, empty: empty
  };
})();
