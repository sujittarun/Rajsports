/**
 * RAJ SPORTS — WhatsApp fee reminder engine (Supabase Edge Function)
 *
 * Adapted from the proven Gen Alpha engine, with three changes that matter:
 *   1. MULTI-TENANT. Everything is scoped by tenant_id and driven by
 *      tenants.config.whatsapp, so the same deployment serves the next
 *      coaching academy without a code change.
 *   2. AMOUNTS ARE RESOLVED, NEVER HARD-CODED. The queue comes from the
 *      reminder_queue() RPC, which runs the same fee-resolution chain the
 *      app shows. A parent can never be quoted a number the manager
 *      doesn't see in the app.
 *   3. MANUAL MODE IS FIRST-CLASS. Until the WABA is approved, mode
 *      'manual' means the engine prepares and reports but never sends;
 *      the manager sends from the app. Flipping to 'auto' needs no deploy.
 *
 * Routes (POST):
 *   /run       — the daily sweep      (cron, 15:00 IST)
 *   /retry     — the retry worker     (cron, every 5 min)
 *   /webhook   — Meta delivery status (GET verifies, POST ingests)
 *   /send      — send one reminder now (staff action from the app)
 *   /preview   — dry-run the queue, send nothing
 *
 * Secrets (never in the database):
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 *   META_WHATSAPP_TOKEN, META_WHATSAPP_PHONE_NUMBER_ID
 *   META_VERIFY_TOKEN
 */

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const META_TOKEN   = Deno.env.get("META_WHATSAPP_TOKEN") || "";
const META_PHONE   = Deno.env.get("META_WHATSAPP_PHONE_NUMBER_ID") || "";
const VERIFY_TOKEN = Deno.env.get("META_VERIFY_TOKEN") || "";
const GRAPH        = "https://graph.facebook.com/v20.0";

const DEFAULT_TENANT = "raj";

/** Meta's "healthy ecosystem" throttle. This is the ONLY code worth an
 *  automatic retry — everything else means the message will never land
 *  and a human has to look. Retrying 131026 just burns the number's
 *  reputation. */
const RETRYABLE = new Set(["131049"]);
const RETRY_SCHEDULE_MIN = [5, 30, 60];
const BATCH_LIMIT = 20;
const SEND_GAP_MS = 250;

/* ------------------------------------------------------------------ */
/* Supabase REST helpers (service role — bypasses RLS by design)        */
/* ------------------------------------------------------------------ */
async function db(path: string, init: RequestInit = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(body?.message || `db ${res.status}`);
  return body;
}
const rpc = (fn: string, args: Record<string, unknown>) =>
  db(`/rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });
const insert = (table: string, row: unknown) =>
  db(`/${table}`, {
    method: "POST",
    body: JSON.stringify(row),
    headers: { Prefer: "return=representation" },
  });
const update = (table: string, filter: string, patch: unknown) =>
  db(`/${table}?${filter}`, { method: "PATCH", body: JSON.stringify(patch) });

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });

/* ------------------------------------------------------------------ */
/* Config                                                              */
/* ------------------------------------------------------------------ */
type WaConfig = {
  enabled: boolean;
  mode: "manual" | "auto";
  dryRun: boolean;
  sendHourIST: number;
  managerPhone: string;
  templates: Record<string, string>;
  brand: string;
  lang: string;
  /** Fetched by Meta on every send, so it must stay publicly reachable. */
  headerImage: string;
};

/* The platform's own mark, not a tenant's. With one shared sender the
   header is the same for everyone; per-academy branding arrives when
   each academy has its own number. */
const DEFAULT_HEADER_IMAGE =
  "https://sujittarun.github.io/AcademyManager/assets/branding/whatsapp-header.jpg";

async function loadConfig(tenant: string): Promise<WaConfig> {
  const rows = await db(`/tenants?id=eq.${tenant}&select=name,config`);
  const cfg = rows?.[0]?.config || {};
  const wa = cfg.whatsapp || {};
  return {
    enabled: !!wa.enabled,
    mode: wa.mode === "auto" ? "auto" : "manual",
    dryRun: wa.dryRun !== false,
    sendHourIST: Number(wa.sendHourIST ?? 15),
    managerPhone: String(wa.managerPhone || ""),
    templates: wa.templates || {},
    brand: String(cfg.brand || rows?.[0]?.name || "the academy"),
    lang: String(wa.templateLang || "en"),
    headerImage: String(wa.headerImage || DEFAULT_HEADER_IMAGE),
  };
}

/* ------------------------------------------------------------------ */
/* Message composition                                                 */
/* ------------------------------------------------------------------ */
type QueueRow = {
  enrollment_id: number; member_id: number; member_name: string;
  parent_name: string | null; phone: string | null;
  centre: string | null; batch: string | null; sport: string | null;
  due_date: string; days_since: number; stage: "heads_up" | "due" | "overdue";
  amount: number | null; months: number; fee_source: string;
  whatsapp_status: string; blocked_reason: string | null; already_sent: boolean;
};

const cap = (s: string) => s ? s[0].toUpperCase() + s.slice(1) : s;
const money = (n: number | null) =>
  n == null ? "" : "₹" + Math.round(n).toLocaleString("en-IN");

function longDate(iso: string) {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString("en-IN",
    { day: "numeric", month: "short", year: "numeric" });
}

/** The exact words a parent reads on the MANUAL path, where free text
 *  is allowed because the owner is sending it himself. The automatic
 *  path cannot use this — a business-initiated message must be an
 *  approved template — so the two are kept saying the same thing by
 *  hand. Change one, change the other.
 *
 *  Kept identical to App.reminderText()
 *  in assets/js/core.js so a hand-sent and an auto-sent reminder are
 *  indistinguishable — the client's "no bad customer experience" rule. */
function messageBody(r: QueueRow, cfg: WaConfig): string {
  const name = r.member_name || "your child";
  const amt = r.amount != null ? money(r.amount) : "";
  const where = [r.centre, r.sport ? cap(r.sport) : null].filter(Boolean).join(", ");
  const at = where ? ` (${where})` : "";

  if (r.stage === "heads_up") {
    return `Hello! ${name}'s coaching fee at ${cfg.brand}${at} is due on ` +
      `${longDate(r.due_date)}.${amt ? ` Amount: ${amt}.` : ""}` +
      ` Sharing this early so you can plan.`;
  }
  if (r.stage === "due") {
    return `Hello! ${name}'s coaching fee at ${cfg.brand}${at} is due today.` +
      `${amt ? ` Amount: ${amt}.` : ""}` +
      ` Kindly complete the payment to continue the batch.`;
  }
  const n = r.days_since || 0;
  return `Hello! A gentle reminder that ${name}'s coaching fee at ${cfg.brand}${at} is pending` +
    `${n > 0 ? `, ${n} ${n === 1 ? "day" : "days"} overdue` : ""}.` +
    `${amt ? ` Amount: ${amt}.` : ""}` +
    ` Please clear it so ${name} does not miss sessions. Do reply if you need any help.`;
}

function templateFor(stage: string, cfg: WaConfig) {
  if (stage === "heads_up") return cfg.templates.headsUp || "utlity_fee_headsup";
  if (stage === "due")      return cfg.templates.dueToday || "utility_renewal_day";
  return cfg.templates.overdue || "utility_for_fee_reminder";
}

const wa91 = (p: string | null) => {
  const d = String(p || "").replace(/\D/g, "").slice(-10);
  return d.length === 10 ? "91" + d : "";
};

/* ------------------------------------------------------------------ */
/* Meta send                                                           */
/* ------------------------------------------------------------------ */
type SendResult =
  | { ok: true; messageId: string }
  | { ok: false; code: string; message: string; retryable: boolean };

async function sendTemplate(to: string, r: QueueRow, cfg: WaConfig): Promise<SendResult> {
  if (!META_TOKEN || !META_PHONE) {
    return { ok: false, code: "no_credentials", retryable: false,
             message: "Meta WhatsApp credentials are not configured." };
  }
  /* One WhatsApp Business account sends for every academy, so the
     templates on it are shared and their wording cannot name one. The
     academy is a PARAMETER — {{2}} — and this is the only place that
     supplies it. Get the order wrong and a Leo parent is told they owe
     money to Raj.

       {{1}} student   {{2}} academy   {{3}} amount   {{4}} due date

     The header is not decoration: a template approved WITH a media
     header must be SENT with one, or Meta rejects the message
     outright. */
  const body = {
    messaging_product: "whatsapp",
    to,
    type: "template",
    template: {
      name: templateFor(r.stage, cfg),
      language: { code: cfg.lang },
      components: [
        {
          type: "header",
          parameters: [{ type: "image", image: { link: cfg.headerImage } }],
        },
        {
          type: "body",
          parameters: [
            { type: "text", text: r.member_name || "Player" },
            { type: "text", text: cfg.brand },
            { type: "text", text: r.amount != null ? money(r.amount) : "the coaching fee" },
            { type: "text", text: longDate(r.due_date) },
          ],
        },
      ],
    },
  };

  try {
    const res = await fetch(`${GRAPH}/${META_PHONE}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${META_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const out = await res.json();
    if (!res.ok) {
      const code = String(out?.error?.code ?? out?.error?.error_subcode ?? "unknown");
      return { ok: false, code,
               message: String(out?.error?.message || "Send failed"),
               retryable: RETRYABLE.has(code) };
    }
    return { ok: true, messageId: String(out?.messages?.[0]?.id || "") };
  } catch (e) {
    // A network blip is worth one more try; a rejection from Meta is not.
    return { ok: false, code: "network", retryable: true, message: String(e) };
  }
}

/* ------------------------------------------------------------------ */
/* Recording                                                           */
/* ------------------------------------------------------------------ */
async function logFlow(tenant: string, memberId: number, reminderId: number | null,
                       step: string, detail?: string, meta: unknown = {}) {
  await insert("wa_flow_events", {
    tenant_id: tenant, member_id: memberId, reminder_id: reminderId,
    step, detail: detail ?? null, meta,
  });
}

async function timeline(tenant: string, memberId: number, enrollmentId: number,
                        title: string, body?: string) {
  await insert("member_timeline", {
    tenant_id: tenant, member_id: memberId, enrollment_id: enrollmentId,
    kind: "reminder", title, body: body ?? null,
  });
}

/** One reminder, start to finish. Every exit path writes a row, so
 *  "nothing happened" is never an unexplained silence. */
async function processOne(tenant: string, r: QueueRow, cfg: WaConfig, dry: boolean) {
  const to = wa91(r.phone);

  // The database already decided this one is not sendable; record why and stop.
  if (r.blocked_reason) {
    const [row] = await insert("reminder_events", {
      tenant_id: tenant, member_id: r.member_id, enrollment_id: r.enrollment_id,
      stage: r.stage, status: "manual_followup", due_date: r.due_date,
      overdue_days: Math.max(r.days_since, 0), amount: r.amount, months: r.months,
      to_phone: r.phone, followup_reason: r.blocked_reason, sent_by: "system", dry_run: dry,
    });
    await logFlow(tenant, r.member_id, row.id, "manual_followup", r.blocked_reason);
    await timeline(tenant, r.member_id, r.enrollment_id,
      "Needs a call", reasonText(r.blocked_reason));
    return { enrollment: r.enrollment_id, outcome: "manual_followup", reason: r.blocked_reason };
  }

  const template = templateFor(r.stage, cfg);
  const body = messageBody(r, cfg);

  const [row] = await insert("reminder_events", {
    tenant_id: tenant, member_id: r.member_id, enrollment_id: r.enrollment_id,
    stage: r.stage, status: "queued", due_date: r.due_date,
    overdue_days: Math.max(r.days_since, 0), amount: r.amount, months: r.months,
    to_phone: r.phone, template, message_body: body, sent_by: "system", dry_run: dry,
  });
  await logFlow(tenant, r.member_id, row.id, "reminder_created",
    `${r.stage} · ${money(r.amount)} · from the ${r.fee_source} rate`);

  // Dry run / manual mode: prepared, reported, deliberately not sent.
  if (dry) {
    await update("reminder_events", `id=eq.${row.id}`, { status: "dry_run" });
    await logFlow(tenant, r.member_id, row.id, "dry_run", "Prepared, not sent");
    return { enrollment: r.enrollment_id, outcome: "dry_run", amount: r.amount, body };
  }

  const sent = await sendTemplate(to, r, cfg);
  if (sent.ok) {
    await update("reminder_events", `id=eq.${row.id}`,
      { status: "accepted", message_id: sent.messageId });
    await logFlow(tenant, r.member_id, row.id, "sent", template, { message_id: sent.messageId });
    await timeline(tenant, r.member_id, r.enrollment_id,
      "WhatsApp reminder sent", `${money(r.amount)} · ${r.stage.replace("_", " ")}`);
    return { enrollment: r.enrollment_id, outcome: "sent", messageId: sent.messageId };
  }

  if (sent.retryable) {
    const next = new Date(Date.now() + RETRY_SCHEDULE_MIN[0] * 60000).toISOString();
    await update("reminder_events", `id=eq.${row.id}`, {
      status: "retry_scheduled", error_code: sent.code,
      error_message: sent.message, next_retry_at: next, retry_count: 0,
    });
    await logFlow(tenant, r.member_id, row.id, "retry_scheduled", sent.code, { next_retry_at: next });
    return { enrollment: r.enrollment_id, outcome: "retry_scheduled", code: sent.code };
  }

  await update("reminder_events", `id=eq.${row.id}`, {
    status: "failed", error_code: sent.code, error_message: sent.message,
    followup_reason: "delivery_failure", next_retry_at: null,
  });
  await logFlow(tenant, r.member_id, row.id, "failed", `${sent.code}: ${sent.message}`);
  await timeline(tenant, r.member_id, r.enrollment_id,
    "Reminder failed", `${sent.message}. Please call the parent.`);
  return { enrollment: r.enrollment_id, outcome: "failed", code: sent.code };
}

function reasonText(reason: string) {
  switch (reason) {
    case "missing_phone":      return "No valid parent number saved.";
    case "wrong_phone_number": return "The saved number is marked wrong.";
    case "whatsapp_opted_out": return "The parent opted out of WhatsApp.";
    case "overdue_15_days":    return "More than 15 days overdue. Automatic reminders stop here.";
    case "fee_not_set":        return "No fee is set for this student.";
    default:                   return reason;
  }
}

/* ------------------------------------------------------------------ */
/* Templates                                                           */
/* ------------------------------------------------------------------ */

/** The WABA this token is allowed to manage.
 *
 *  Asked of the token itself rather than of the phone number: a system
 *  user token carries granular scopes listing exactly which business
 *  accounts it may touch, so this answers "which WABA" and "is the
 *  token scoped correctly" in one call. A phone number does not expose
 *  its parent account at all — the first attempt at this asked for a
 *  field that does not exist.
 */
async function wabaId(): Promise<string> {
  const res = await fetch(
    `${GRAPH}/debug_token?input_token=${encodeURIComponent(META_TOKEN)}`,
    { headers: { Authorization: `Bearer ${META_TOKEN}` } },
  );
  const out = await res.json();
  if (!res.ok) {
    const t = META_TOKEN;
    throw new Error(
      (out?.error?.message || "could not inspect the token") +
      ` | token shape: length=${t.length}, starts_EAA=${t.startsWith("EAA")}`,
    );
  }
  const scopes = (out?.data?.granular_scopes || []) as Array<
    { scope: string; target_ids?: string[] }
  >;
  const wa = scopes.find((g) =>
    g.scope === "whatsapp_business_management" || g.scope === "whatsapp_business_messaging"
  );
  let id = wa?.target_ids?.[0];

  /* Fall back to asking the business directly. A system user token can
     carry the whatsapp scopes without target_ids when the WhatsApp
     account is reachable through the business rather than assigned to
     the user directly — the permission is there, the asset pointer is
     not. Ids are not secrets, so both paths are safe to report on. */
  if (!id) {
    const biz = scopes.find((g) => g.scope === "business_management")?.target_ids || [];
    for (const b of biz) {
      const r = await fetch(
        `${GRAPH}/${b}/owned_whatsapp_business_accounts?fields=id,name`,
        { headers: { Authorization: `Bearer ${META_TOKEN}` } },
      );
      const o = await r.json();
      if (r.ok && o?.data?.length) { id = String(o.data[0].id); break; }
    }
  }

  if (!id) {
    throw new Error(
      "no WhatsApp business account reachable from this token. In Business " +
      "Settings > System users, select the user, Add assets, and give it Full " +
      "control of the WhatsApp account — then regenerate the token. " +
      "granular scopes: " + JSON.stringify(scopes),
    );
  }
  return String(id);
}

/**
 * What Meta thinks of our templates.
 *
 * A send fails outright if a template is not APPROVED, and the failure
 * arrives as a code on a message that was never delivered — long after
 * anyone could act on it. This asks first, and it asks with the token
 * that already lives here, so checking never means handling a
 * credential.
 *
 * It also reports whether each template's shape matches what
 * sendTemplate() actually sends: a media header and four body
 * parameters. An approved template with three is approved and wrong.
 */
async function templateStatus(cfg: WaConfig, override?: string) {
  const waba = override || await wabaId();
  const res = await fetch(
    `${GRAPH}/${waba}/message_templates?fields=name,status,category,language,components,rejected_reason&limit=50`,
    { headers: { Authorization: `Bearer ${META_TOKEN}` } },
  );
  const out = await res.json();
  if (!res.ok) return { error: out?.error?.message || "could not list templates" };

  const wanted = [cfg.templates.headsUp, cfg.templates.dueToday, cfg.templates.overdue];
  const found = (out?.data || []).map((t: Record<string, unknown>) => {
    const comps = (t.components || []) as Array<Record<string, unknown>>;
    const header = comps.find((c) => c.type === "HEADER");
    const bodyText = String(comps.find((c) => c.type === "BODY")?.text || "");
    const params = new Set(bodyText.match(/\{\{\d+\}\}/g) || []);
    return {
      name: t.name,
      status: t.status,
      category: t.category,
      language: t.language,
      header: header ? String(header.format || "") : "none",
      body_params: params.size,
      // what this engine requires, stated rather than assumed
      usable: t.status === "APPROVED" &&
              String(header?.format || "") === "IMAGE" &&
              params.size === 4,
      rejected_reason: t.rejected_reason || undefined,
    };
  });

  return {
    waba,
    needed: wanted,
    templates: found,
    missing: wanted.filter((w) => !found.some((f: { name: unknown }) => f.name === w)),
    ready: wanted.every((w) => found.some((f: { name: unknown; usable: boolean }) => f.name === w && f.usable)),
  };
}

/* ------------------------------------------------------------------ */
/* Routes                                                              */
/* ------------------------------------------------------------------ */

/** The daily sweep. */
async function runSweep(tenant: string, force = false) {
  const cfg = await loadConfig(tenant);
  const queue: QueueRow[] = await rpc("reminder_queue", { p_tenant: tenant, p_on: null });
  const live = force || (cfg.enabled && cfg.mode === "auto" && !cfg.dryRun);

  // In manual mode the cron reports and writes NOTHING. A reminder_events
  // row has to mean "we actually attempted to reach this parent" — if the
  // daily cron logged dry runs, tenant_health's sent/delivered counters
  // would quietly become fiction, which is worse than no number at all.
  // The live backlog is always available from reminder_queue().
  if (!live) {
    const sendable = queue.filter((r) => !r.blocked_reason && !r.already_sent);
    return {
      tenant, mode: cfg.mode, sending: false as const,
      note: "Manual mode. Nothing sent and nothing logged. " +
            "The manager sends these from the Reminders screen.",
      queued: queue.length,
      would_send: sendable.length,
      needs_a_call: queue.filter((r) => r.blocked_reason).length,
      amount_due: sendable.reduce((a, r) => a + (Number(r.amount) || 0), 0),
    };
  }

  const dry = false;
  const todo = queue.filter((r) => !r.already_sent).slice(0, BATCH_LIMIT);
  const results = [];
  for (const r of todo) {
    try {
      results.push(await processOne(tenant, r, cfg, dry));
    } catch (e) {
      results.push({ enrollment: r.enrollment_id, outcome: "error", error: String(e) });
    }
    if (!dry) await new Promise((res) => setTimeout(res, SEND_GAP_MS));
  }

  return {
    tenant, mode: cfg.mode, sending: true as const,
    queued: queue.length, skipped_already_sent: queue.length - todo.length,
    processed: results.length, results,
  };
}

/** The retry worker. */
async function runRetries(tenant: string) {
  const cfg = await loadConfig(tenant);
  if (!cfg.enabled || cfg.mode !== "auto" || cfg.dryRun) {
    return { tenant, skipped: "sending is not live" };
  }

  const due = await db(
    `/reminder_events?tenant_id=eq.${tenant}&status=eq.retry_scheduled` +
    `&next_retry_at=lte.${new Date().toISOString()}&select=*&limit=${BATCH_LIMIT}`,
  );

  const results = [];
  for (const ev of due) {
    // Re-check the contact BEFORE every attempt: a number marked wrong
    // since the last try must stop immediately, not burn its retries.
    const [m] = await db(`/members?id=eq.${ev.member_id}&select=whatsapp_status,parent_phone,phone,name`);
    if (!m || m.whatsapp_status !== "active") {
      await update("reminder_events", `id=eq.${ev.id}`, {
        status: "manual_followup", next_retry_at: null,
        followup_reason: m?.whatsapp_status === "opted_out" ? "whatsapp_opted_out" : "wrong_phone_number",
      });
      await logFlow(tenant, ev.member_id, ev.id, "manual_followup", "contact status changed");
      results.push({ id: ev.id, outcome: "manual_followup" });
      continue;
    }

    const attempt = (ev.retry_count || 0) + 1;
    if (attempt > RETRY_SCHEDULE_MIN.length) {
      await update("reminder_events", `id=eq.${ev.id}`, {
        status: "failed", next_retry_at: null, followup_reason: "retry_exhausted",
      });
      await logFlow(tenant, ev.member_id, ev.id, "failed", "retries exhausted");
      results.push({ id: ev.id, outcome: "retry_exhausted" });
      continue;
    }

    const row: QueueRow = {
      enrollment_id: ev.enrollment_id, member_id: ev.member_id,
      member_name: m.name, parent_name: null,
      phone: m.parent_phone || m.phone,
      centre: null, batch: null, sport: null,
      due_date: ev.due_date, days_since: ev.overdue_days, stage: ev.stage,
      amount: ev.amount, months: ev.months, fee_source: "retry",
      whatsapp_status: m.whatsapp_status, blocked_reason: null, already_sent: false,
    };

    const sent = await sendTemplate(wa91(row.phone), row, cfg);
    if (sent.ok) {
      await update("reminder_events", `id=eq.${ev.id}`, {
        status: "accepted", message_id: sent.messageId,
        next_retry_at: null, retry_count: attempt,
      });
      await logFlow(tenant, ev.member_id, ev.id, "sent", `retry ${attempt}`);
      results.push({ id: ev.id, outcome: "sent" });
    } else if (sent.retryable && attempt < RETRY_SCHEDULE_MIN.length) {
      const next = new Date(Date.now() + RETRY_SCHEDULE_MIN[attempt] * 60000).toISOString();
      await update("reminder_events", `id=eq.${ev.id}`, {
        retry_count: attempt, next_retry_at: next, error_code: sent.code,
      });
      results.push({ id: ev.id, outcome: "rescheduled" });
    } else {
      await update("reminder_events", `id=eq.${ev.id}`, {
        status: "failed", next_retry_at: null, retry_count: attempt,
        error_code: sent.code, error_message: sent.message,
        followup_reason: sent.retryable ? "retry_exhausted" : "delivery_failure",
      });
      await logFlow(tenant, ev.member_id, ev.id, "failed", `${sent.code}: ${sent.message}`);
      results.push({ id: ev.id, outcome: "failed" });
    }
    await new Promise((res) => setTimeout(res, SEND_GAP_MS));
  }
  return { tenant, due: due.length, results };
}

/** Meta delivery webhook. */
async function handleWebhook(req: Request) {
  if (req.method === "GET") {
    const u = new URL(req.url);
    if (u.searchParams.get("hub.verify_token") === VERIFY_TOKEN && VERIFY_TOKEN) {
      return new Response(u.searchParams.get("hub.challenge") || "", { status: 200 });
    }
    return new Response("forbidden", { status: 403 });
  }

  const payload = await req.json().catch(() => ({}));
  const statuses = payload?.entry?.[0]?.changes?.[0]?.value?.statuses || [];

  for (const s of statuses) {
    const messageId = String(s.id || "");
    if (!messageId) continue;

    await insert("wa_webhook_events", { message_id: messageId, kind: s.status, payload: s })
      .catch(() => {});

    const [ev] = await db(`/reminder_events?message_id=eq.${messageId}&select=*`);
    if (!ev) continue;

    if (s.status === "delivered" || s.status === "read") {
      // Never move backwards: a late "delivered" must not undo a "read".
      if (!(s.status === "delivered" && ev.status === "read")) {
        await update("reminder_events", `id=eq.${ev.id}`, { status: s.status });
        await logFlow(ev.tenant_id, ev.member_id, ev.id, s.status);
        await timeline(ev.tenant_id, ev.member_id, ev.enrollment_id,
          s.status === "read" ? "Reminder read by parent" : "Reminder delivered");
      }
    } else if (s.status === "failed") {
      const code = String(s.errors?.[0]?.code ?? "unknown");
      const msg = String(s.errors?.[0]?.title || s.errors?.[0]?.message || "Delivery failed");
      if (RETRYABLE.has(code) && (ev.retry_count || 0) < RETRY_SCHEDULE_MIN.length) {
        await update("reminder_events", `id=eq.${ev.id}`, {
          status: "retry_scheduled", error_code: code, error_message: msg,
          next_retry_at: new Date(Date.now() + RETRY_SCHEDULE_MIN[0] * 60000).toISOString(),
        });
        await logFlow(ev.tenant_id, ev.member_id, ev.id, "retry_scheduled", code);
      } else {
        await update("reminder_events", `id=eq.${ev.id}`, {
          status: "failed", error_code: code, error_message: msg,
          next_retry_at: null, followup_reason: "delivery_failure",
        });
        await logFlow(ev.tenant_id, ev.member_id, ev.id, "failed", `${code}: ${msg}`);
        await timeline(ev.tenant_id, ev.member_id, ev.enrollment_id,
          "Reminder failed", `${msg}. Please call the parent.`);
      }
    }
  }
  return json({ received: statuses.length });
}

/** Send one reminder on demand (the app's "send now" for a single student). */
async function sendOne(tenant: string, enrollmentId: number) {
  const cfg = await loadConfig(tenant);
  const queue: QueueRow[] = await rpc("reminder_queue", { p_tenant: tenant, p_on: null });
  const row = queue.find((r) => r.enrollment_id === enrollmentId);
  if (!row) return json({ error: "That student has nothing due today." }, 404);
  const dry = !cfg.enabled || cfg.mode !== "auto" || cfg.dryRun;
  return json(await processOne(tenant, row, cfg, dry));
}

/* ------------------------------------------------------------------ */
Deno.serve(async (req) => {
  const url = new URL(req.url);
  const route = url.pathname.split("/").filter(Boolean).pop() || "";
  const tenant = url.searchParams.get("tenant") || DEFAULT_TENANT;

  try {
    if (route === "webhook") return await handleWebhook(req);
    if (req.method !== "POST") return json({ error: "POST only" }, 405);

    switch (route) {
      case "run":     return json(await runSweep(tenant, url.searchParams.get("force") === "1"));
      case "retry":   return json(await runRetries(tenant));
      case "templates": {
        const cfg = await loadConfig(tenant);
        // ?waba=... skips discovery. Meta's asset model has more ways to
        // withhold an id than are worth guessing at from here.
        return json(await templateStatus(cfg, url.searchParams.get("waba") || undefined));
      }
      case "probe": {
        /* What can this token actually see? Each answer narrows the
           fault: a phone number it can read but a WABA it cannot means
           messaging works and management does not, which is a different
           fix from a token with no assets at all. Ids are identifiers,
           not secrets — the token itself is never echoed. */
        const ask = async (label: string, path: string) => {
          try {
            const r = await fetch(`${GRAPH}/${path}`, {
              headers: { Authorization: `Bearer ${META_TOKEN}` },
            });
            const o = await r.json();
            return { probe: label, ok: r.ok, result: r.ok ? o : (o?.error?.message || o) };
          } catch (e) {
            return { probe: label, ok: false, result: String(e) };
          }
        };
        return json({
          phone_number: await ask("the number itself", `${META_PHONE}?fields=id,display_phone_number,verified_name,quality_rating`),
          its_waba: await ask("the account that owns it", `${META_PHONE}?fields=whatsapp_business_account{id,name}`),
          me: await ask("who the token is", "me?fields=id,name"),
          businesses: await ask("businesses it can see", "me/businesses?fields=id,name"),
        });
      }
      case "preview": {
        const cfg = await loadConfig(tenant);
        const queue: QueueRow[] = await rpc("reminder_queue", { p_tenant: tenant, p_on: null });
        return json({
          tenant, mode: cfg.mode, enabled: cfg.enabled, dry_run: cfg.dryRun,
          would_send: queue.filter((r) => !r.blocked_reason && !r.already_sent)
            .map((r) => ({ student: r.member_name, phone: r.phone, stage: r.stage,
                           amount: r.amount, fee_from: r.fee_source, text: messageBody(r, cfg) })),
          needs_a_call: queue.filter((r) => r.blocked_reason)
            .map((r) => ({ student: r.member_name, why: reasonText(r.blocked_reason!) })),
        });
      }
      case "send": {
        const b = await req.json().catch(() => ({}));
        if (!b.enrollment_id) return json({ error: "enrollment_id is required" }, 400);
        return await sendOne(tenant, Number(b.enrollment_id));
      }
      default: return json({ error: `Unknown route "${route}"` }, 404);
    }
  } catch (e) {
    console.error(route, e);
    return json({ error: String(e) }, 500);
  }
});
