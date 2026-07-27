/* ============================================================
   RAJ SPORTS — cloud adapter (window.RS)
   Supabase over fetch. No SDK, no build step.

   Cloud-first, unlike the Leo/Machaxi apps: this app's data IS the
   product (who owes what), so there is no seed-data fallback that
   could show a manager a stale or invented number. If the network is
   down the UI says so rather than guessing.

   Two access tiers:
     · anon key  — the public admission form + pay page only
     · staff JWT — everything else (RLS scopes it to tenant 'raj')
   ============================================================ */
(function () {
  "use strict";

  var APP_VER = "3";   // keep in step with the ?v= cache-buster in the HTML
  var PROJECT = "https://ugsklcipzyiogxynshnh.supabase.co";
  var BASE    = PROJECT + "/rest/v1";
  var AUTH    = PROJECT + "/auth/v1";
  var KEY     = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVnc2tsY2lwenlpb2d4eW5zaG5oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4OTUyMzksImV4cCI6MjA5ODQ3MTIzOX0.w7xkjdTkYN2qA0oxMKLUNtua0ScKVHKQzfEyIayh9eo";
  var TENANT  = "raj";
  var SKEY    = "rs-session";

  /* ---------------- session ---------------- */
  function session() {
    try { return JSON.parse(localStorage.getItem(SKEY)); } catch (e) { return null; }
  }
  function save(s) { try { localStorage.setItem(SKEY, JSON.stringify(s)); } catch (e) {} }
  function clear() { try { localStorage.removeItem(SKEY); } catch (e) {} }

  function tokenReq(body) {
    var grant = body.refresh_token ? "refresh_token" : "password";
    return fetch(AUTH + "/token?grant_type=" + grant, {
      method: "POST",
      headers: { apikey: KEY, "Content-Type": "application/json" },
      body: JSON.stringify(body)
    }).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) throw new Error(j.error_description || j.msg || j.error || "Sign-in failed");
        var meta = (j.user && j.user.app_metadata) || {};
        var s = {
          access_token: j.access_token,
          refresh_token: j.refresh_token,
          expires_at: Date.now() + (j.expires_in || 3600) * 1000,
          email: j.user && j.user.email,
          role: meta.am_role || "",
          tenant: meta.tenant_id || ""
        };
        if (s.tenant !== TENANT && s.role !== "operator") {
          throw new Error("This account does not belong to Raj Sports.");
        }
        save(s);
        return s;
      });
    });
  }

  // Resolve the bearer to use, refreshing the token when it is close to
  // expiring so a manager mid-task is never bounced to the login screen.
  function bearer() {
    var s = session();
    if (!s || !s.access_token) return Promise.resolve(KEY);
    if (s.expires_at - Date.now() > 90000) return Promise.resolve(s.access_token);
    return tokenReq({ refresh_token: s.refresh_token })
      .then(function (n) { return n.access_token; })
      .catch(function () { clear(); return KEY; });
  }

  /* ---------------- transport ---------------- */
  function req(path, opts) {
    opts = opts || {};
    return bearer().then(function (tok) {
      var h = {
        apikey: KEY,
        Authorization: "Bearer " + tok,
        "Content-Type": "application/json"
      };
      if (opts.prefer) h.Prefer = opts.prefer;
      if (opts.count)  h.Prefer = (h.Prefer ? h.Prefer + "," : "") + "count=exact";
      return fetch(BASE + path, {
        method: opts.method || "GET",
        headers: h,
        body: opts.body ? JSON.stringify(opts.body) : undefined
      }).then(function (r) {
        return r.text().then(function (t) {
          var j = null;
          try { j = t ? JSON.parse(t) : null; } catch (e) { j = t; }
          if (!r.ok) {
            var msg = (j && (j.message || j.hint || j.error)) || ("Request failed (" + r.status + ")");
            var err = new Error(msg);
            err.status = r.status;
            throw err;
          }
          return j;
        });
      });
    });
  }

  function get(path)        { return req(path); }
  function post(path, body) { return req(path, { method: "POST", body: body, prefer: "return=representation" }); }
  function patch(path, body){ return req(path, { method: "PATCH", body: body, prefer: "return=representation" }); }
  function del(path)        { return req(path, { method: "DELETE" }); }
  function rpc(fn, args)    { return req("/rpc/" + fn, { method: "POST", body: args || {} }); }

  var T = "tenant_id=eq." + TENANT;

  /* ---------------- reference data ----------------
     Centres / batches / sports change roughly never but are needed on
     every screen, so they are cached in memory for the page's life. */
  var refCache = null;
  function reference(force) {
    if (refCache && !force) return Promise.resolve(refCache);
    return Promise.all([
      get("/centres?" + T + "&select=*&order=sort"),
      get("/batches?" + T + "&select=*&order=sort"),
      get("/sports?"  + T + "&select=*&order=sort"),
      get("/coaches?" + T + "&select=*&order=name")
    ]).then(function (r) {
      refCache = { centres: r[0] || [], batches: r[1] || [], sports: r[2] || [], coaches: r[3] || [] };
      refCache.centreById = index(refCache.centres);
      refCache.batchById  = index(refCache.batches);
      refCache.sportByCode = refCache.sports.reduce(function (a, s) { a[s.code] = s; return a; }, {});
      return refCache;
    });
  }
  function index(rows) { return rows.reduce(function (a, r) { a[r.id] = r; return a; }, {}); }
  function invalidate() { refCache = null; }

  /* ---------------- students ---------------- */
  // One call for the roster: members with their enrollments embedded.
  function students(opts) {
    opts = opts || {};
    var q = "/members?" + T +
      "&select=*,enrollments(*)" +
      "&order=name.asc";
    if (opts.status) q += "&status=eq." + encodeURIComponent(opts.status);
    return get(q);
  }

  function student(id) {
    return get("/members?" + T + "&id=eq." + id + "&select=*,enrollments(*)")
      .then(function (r) { return (r && r[0]) || null; });
  }

  function timeline(memberId) {
    return get("/member_timeline?" + T + "&member_id=eq." + memberId +
               "&select=*&order=at.desc&limit=80");
  }

  function saveStudent(id, fields) {
    fields.updated_at = new Date().toISOString();
    return id
      ? patch("/members?" + T + "&id=eq." + id, fields)
      : post("/members", Object.assign({ tenant_id: TENANT }, fields));
  }

  function saveEnrollment(id, fields) {
    fields.updated_at = new Date().toISOString();
    return id
      ? patch("/enrollments?" + T + "&id=eq." + id, fields)
      : post("/enrollments", Object.assign({ tenant_id: TENANT }, fields));
  }

  /* ---------------- fees ---------------- */
  function feeRules() {
    return get("/fee_rules?" + T + "&select=*&order=id.desc");
  }
  function saveFeeRule(id, fields) {
    return id
      ? patch("/fee_rules?" + T + "&id=eq." + id, fields)
      : post("/fee_rules", Object.assign({ tenant_id: TENANT }, fields));
  }
  function deleteFeeRule(id) { return del("/fee_rules?" + T + "&id=eq." + id); }

  // What should THIS enrollment pay? Always ask the server — the same
  // function the reminder engine uses, so the number a parent sees on
  // WhatsApp and the number staff sees in the app can never diverge.
  function feeFor(enrollmentId, months) {
    return rpc("enrollment_fee", { p_enrollment: enrollmentId, p_months: months || null });
  }

  function payments(opts) {
    opts = opts || {};
    var q = "/payments?" + T + "&select=*&order=on_date.desc,id.desc&limit=" + (opts.limit || 300);
    if (opts.from) q += "&on_date=gte." + opts.from;
    if (opts.to)   q += "&on_date=lte." + opts.to;
    if (opts.enrollment) q += "&enrollment_id=eq." + opts.enrollment;
    return get(q);
  }

  function recordPayment(a) {
    return rpc("record_fee_payment", {
      p_tenant: TENANT,
      p_enrollment: a.enrollment,
      p_amount: a.amount,
      p_months: a.months || null,
      p_mode: a.mode || "UPI",
      p_kind: a.kind || "renewal",
      p_on_date: a.date || null,
      p_ref: a.ref || null,
      p_status: a.status || "paid",
      p_collected_by: a.by || null,
      p_note: a.note || null
    });
  }

  /* ---------------- reminders ---------------- */
  // The single source of truth for "who needs chasing today".
  function reminderQueue(onDate) {
    return rpc("reminder_queue", { p_tenant: TENANT, p_on: onDate || null });
  }

  function reminderHistory(limit) {
    return get("/reminder_events?" + T + "&select=*&order=created_at.desc&limit=" + (limit || 100));
  }

  function logManualReminder(a) {
    return rpc("log_manual_reminder", {
      p_tenant: TENANT,
      p_enrollment: a.enrollment,
      p_stage: a.stage,
      p_amount: a.amount,
      p_phone: a.phone,
      p_body: a.body || null,
      p_channel: a.channel || "whatsapp",
      p_by: a.by || "staff"
    });
  }

  function setWhatsappStatus(memberId, status) {
    return patch("/members?" + T + "&id=eq." + memberId, { whatsapp_status: status });
  }

  /* ---------------- payouts ---------------- */
  function payoutRules() {
    return get("/payout_rules?" + T + "&select=*&order=party,id");
  }
  function savePayoutRule(id, fields) {
    return id
      ? patch("/payout_rules?" + T + "&id=eq." + id, fields)
      : post("/payout_rules", Object.assign({ tenant_id: TENANT }, fields));
  }
  function deletePayoutRule(id) { return del("/payout_rules?" + T + "&id=eq." + id); }

  function payouts(month) {
    var q = "/payouts?" + T + "&select=*&order=party,id";
    if (month) q += "&period_month=eq." + month;
    return get(q);
  }
  function computePayouts(month) {
    return rpc("compute_payouts", { p_tenant: TENANT, p_month: month });
  }
  function markPayoutPaid(id, on) {
    return patch("/payouts?" + T + "&id=eq." + id,
                 { status: "paid", paid_on: on || null, updated_at: new Date().toISOString() });
  }

  /* ---------------- coaches, centres, batches, sports ----------------
     CREATES go through RPCs, never a raw POST. The server generates the
     code, checks for a duplicate name, validates the timing and writes
     the audit row — so the web app and the Android app cannot drift into
     two different sets of rules. UPDATES are plain PATCHes; the table
     constraints and the audit trigger catch anything invalid. */
  function addSport(name, icon) {
    return rpc("add_sport", { p_tenant: TENANT, p_name: name, p_icon: icon || null }).then(tap(invalidate));
  }
  function addCentre(f) {
    return rpc("add_centre", {
      p_tenant: TENANT, p_name: f.name, p_short: f.short_name || null,
      p_address: f.address || null, p_contact: f.contact || null
    }).then(tap(invalidate));
  }
  function addBatch(f) {
    return rpc("add_batch", {
      p_tenant: TENANT, p_centre: f.centre_id, p_name: f.name,
      p_days: f.days, p_start: f.start_time, p_end: f.end_time,
      p_sport: f.sport || null, p_coach: f.coach_id || null, p_capacity: f.capacity || null
    }).then(tap(invalidate));
  }
  // A timing change is what parents feel, so it has its own audited path.
  function updateBatchTiming(id, days, start, end) {
    return rpc("update_batch_timing", {
      p_tenant: TENANT, p_batch: id, p_days: days, p_start: start, p_end: end
    }).then(tap(invalidate));
  }

  function saveCoach(id, f) {
    return (id ? patch("/coaches?" + T + "&id=eq." + id, f)
               : post("/coaches", Object.assign({ tenant_id: TENANT }, f))).then(tap(invalidate));
  }
  function saveCentre(id, f) { return patch("/centres?" + T + "&id=eq." + id, f).then(tap(invalidate)); }
  function saveBatch(id, f)  { return patch("/batches?" + T + "&id=eq." + id, f).then(tap(invalidate)); }
  function saveSport(id, f)  { return patch("/sports?"  + T + "&id=eq." + id, f).then(tap(invalidate)); }

  function deleteSport(id)  { return del("/sports?"  + T + "&id=eq." + id).then(tap(invalidate)); }
  function deleteCentre(id) { return del("/centres?" + T + "&id=eq." + id).then(tap(invalidate)); }
  function deleteBatch(id)  { return del("/batches?" + T + "&id=eq." + id).then(tap(invalidate)); }

  function tap(fn) { return function (v) { fn(); return v; }; }

  /* ---------------- observability ---------------- */
  function auditLog(limit) {
    return get("/audit_log?" + T + "&select=*&order=at.desc&limit=" + (limit || 60));
  }
  function health() { return rpc("tenant_health", { p_tenant: TENANT }); }

  /* ---------------- admissions ---------------- */
  // Runs on the ANON key from the public page — the only public write.
  function submitApplication(f) {
    return fetch(BASE + "/applications", {
      method: "POST",
      headers: { apikey: KEY, Authorization: "Bearer " + KEY,
                 "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify(Object.assign({ tenant_id: TENANT, status: "pending" }, f))
    }).then(function (r) {
      if (!r.ok) return r.text().then(function (t) { throw new Error(t || "Could not submit"); });
      return true;
    });
  }
  function applications(status) {
    var q = "/applications?" + T + "&select=*&order=created_at.desc";
    if (status) q += "&status=eq." + status;
    return get(q);
  }
  function approveApplication(id) {
    return rpc("approve_application", { p_tenant: TENANT, p_application: id, p_by: (session() || {}).email || "staff" });
  }
  function rejectApplication(id) {
    return patch("/applications?" + T + "&id=eq." + id,
                 { status: "rejected", reviewed_at: new Date().toISOString(),
                   reviewed_by: (session() || {}).email || "staff" });
  }

  /* ---------------- settings + analytics ---------------- */
  function tenantConfig() {
    return get("/tenants?id=eq." + TENANT + "&select=config")
      .then(function (r) { return (r && r[0] && r[0].config) || {}; })
      .catch(function () { return {}; });
  }
  // Events feed the Academy Manager console: usage, adoption and errors.
  // Fire-and-forget on the anon key so a signed-out page (and a failure
  // during sign-in itself) can still report.
  function track(name, props, level) {
    var body = {
      tenant_id: TENANT, name: name, level: level || "info",
      props: Object.assign({ ver: APP_VER }, props || {}),
      page: location.pathname.split("/").pop() || "index.html",
      session_id: sessionId()
    };
    fetch(BASE + "/events", {
      method: "POST",
      headers: { apikey: KEY, Authorization: "Bearer " + KEY,
                 "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify(body)
    }).catch(function () {});
  }

  // Anything that breaks in front of the manager becomes an operator-visible
  // signal, rather than a silent dead end nobody hears about.
  function reportError(where, err) {
    try {
      track("client_error", {
        where: where,
        message: String((err && err.message) || err || "").slice(0, 300),
        stack: String((err && err.stack) || "").slice(0, 600),
        ua: navigator.userAgent.slice(0, 160)
      }, "error");
    } catch (e) {}
  }
  window.addEventListener("error", function (e) { reportError("window.onerror", e.error || e.message); });
  window.addEventListener("unhandledrejection", function (e) { reportError("unhandledrejection", e.reason); });
  function sessionId() {
    try {
      var k = sessionStorage.getItem("rs-sid");
      if (!k) { k = Math.random().toString(36).slice(2) + Date.now().toString(36);
                sessionStorage.setItem("rs-sid", k); }
      return k;
    } catch (e) { return null; }
  }

  window.RS = {
    TENANT: TENANT, PROJECT: PROJECT,
    // auth
    signIn: function (e, p) { return tokenReq({ email: e, password: p }); },
    signOut: clear,
    session: session,
    signedIn: function () { var s = session(); return !!(s && s.access_token); },
    // data
    reference: reference, invalidate: invalidate,
    students: students, student: student, timeline: timeline,
    saveStudent: saveStudent, saveEnrollment: saveEnrollment,
    feeRules: feeRules, saveFeeRule: saveFeeRule, deleteFeeRule: deleteFeeRule,
    feeFor: feeFor, payments: payments, recordPayment: recordPayment,
    reminderQueue: reminderQueue, reminderHistory: reminderHistory,
    logManualReminder: logManualReminder, setWhatsappStatus: setWhatsappStatus,
    payoutRules: payoutRules, savePayoutRule: savePayoutRule,
    deletePayoutRule: deletePayoutRule, payouts: payouts,
    computePayouts: computePayouts, markPayoutPaid: markPayoutPaid,
    addSport: addSport, addCentre: addCentre, addBatch: addBatch,
    updateBatchTiming: updateBatchTiming,
    saveCoach: saveCoach, saveCentre: saveCentre, saveBatch: saveBatch, saveSport: saveSport,
    deleteSport: deleteSport, deleteCentre: deleteCentre, deleteBatch: deleteBatch,
    auditLog: auditLog, health: health, reportError: reportError,
    submitApplication: submitApplication, applications: applications,
    approveApplication: approveApplication, rejectApplication: rejectApplication,
    tenantConfig: tenantConfig, track: track,
    // escape hatches
    get: get, post: post, patch: patch, rpc: rpc
  };
})();
