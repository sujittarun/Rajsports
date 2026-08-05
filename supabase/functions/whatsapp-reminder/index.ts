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
/* The caller's shared secret. This function is deployed --no-verify-jwt
   (Meta must be able to reach /webhook without a Supabase JWT), which
   means Supabase's gateway checks nothing — so the check has to live
   here. Without it, anyone who knows the URL can POST /run?tenant=X and
   send real WhatsApp messages to that academy's parents: the tenant is
   a query parameter, so it is cross-tenant by construction.
   Set with: supabase secrets set AM_FN_SECRET=... */
const FN_SECRET    = Deno.env.get("AM_FN_SECRET") || "";
/* Meta signs every webhook POST with sha256 over the raw body. Set
   META_APP_SECRET to have it verified; without it the webhook stays
   open, because a silently-rejected webhook loses delivery receipts. */
const APP_SECRET   = Deno.env.get("META_APP_SECRET") || "";
/* v26.0. Meta's webhook config now defaults to it, and v20.0 dated from
   2024 — a version at or past sunset starts returning generic errors
   that name nothing, which is how a missing app subscription showed up
   here as a bare "(#100) Invalid parameter".

   This constant drives RAJ's live reminders as well as MPP's, so the
   upgrade was made deliberately rather than as a side effect of
   debugging: the whole surface this function actually calls — templates,
   health_status, phone number, register, subscribed_apps and the send
   itself — was re-checked on v26 before it was committed. */
const GRAPH        = "https://graph.facebook.com/v26.0";

/** Constant-time compare, so a wrong secret cannot be found a byte at a
 *  time by timing the response. */
function secretsMatch(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Meta's X-Hub-Signature-256 over the raw request body. */
async function metaSignatureValid(raw: string, header: string | null): Promise<boolean> {
  if (!APP_SECRET) return true;            // not configured — see note above
  if (!header || !header.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(APP_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw));
  const hex = Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
  return secretsMatch(hex, header.slice("sha256=".length));
}

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
  /** True only once the approved templates carry a 5th variable for the
   *  collection account. Sending a parameter a template was not approved
   *  with makes Meta reject the message, so this stays off until the
   *  template really has it. */
  upiParam: boolean;
  /** This academy's OWN WhatsApp number. Empty means not onboarded yet,
   *  and sending refuses — it must never borrow the platform number. */
  phoneNumberId: string;
  /** This academy's WhatsApp Business Account, for template checks. */
  wabaId: string;
  /** This academy's Meta token, or the platform System User token when
   *  its number lives in our Business Manager. */
  token: string;
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

  /* WHICH NUMBER THIS ACADEMY SENDS FROM.
     This used to be a single global env var, so every academy's parents
     got a message from "Academy Manager". Now it is resolved per tenant,
     and the platform number is NOT a fallback — see sendTemplate. The
     token is optional: when a client's number sits in our own Business
     Manager, one System User token sends from all of them, and only the
     phone number id differs. whatsapp_credentials() is service-role only
     because it hands back a live token. */
  let phoneNumberId = "";
  let wabaId = "";
  let token = "";
  try {
    const creds = await rpc("whatsapp_credentials", { p_tenant: tenant });
    if (creds?.ok) {
      phoneNumberId = String(creds.phoneNumberId || "");
      wabaId = String(creds.wabaId || "");
      token = String(creds.token || "");
    }
  } catch (_) {
    /* leave blank — sendTemplate fails closed rather than borrowing the
       platform number, which is the whole point of this change */
  }

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
    upiParam: wa.upiParam === true,
    phoneNumberId,
    wabaId,
    // fall back to the platform System User token, NOT to the platform NUMBER
    token: token || META_TOKEN,
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
  upi_id: string | null; upi_name: string | null; upi_source: string | null;
};

const cap = (s: string) => s ? s[0].toUpperCase() + s.slice(1) : s;
const money = (n: number | null) =>
  n == null ? "" : "₹" + Math.round(n).toLocaleString("en-IN");

function longDate(iso: string) {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString("en-IN",
    { day: "numeric", month: "short", year: "numeric" });
}

/* Where this parent pays. resolve_upi() picks the account in Postgres
   (batch, then centre, then the academy) and reminder_queue carries it
   here, so a BTV parent and a Pushpak parent are told different
   accounts without this function deciding which.

   A plain UPI id, not a upi:// link: WhatsApp does not reliably turn
   one into something tappable, and a "tap to pay" that does nothing is
   worse than an id a parent can paste into any UPI app. */
function upiLine(r: QueueRow): string {
  if (!r.upi_id) return "";
  return ` Pay to UPI: ${r.upi_id}${r.upi_name ? ` (${r.upi_name})` : ""}.`;
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
  const pay = upiLine(r);

  if (r.stage === "heads_up") {
    return `Hello! ${name}'s coaching fee at ${cfg.brand}${at} is due on ` +
      `${longDate(r.due_date)}.${amt ? ` Amount: ${amt}.` : ""}` +
      ` Sharing this early so you can plan.${pay}`;
  }
  if (r.stage === "due") {
    return `Hello! ${name}'s coaching fee at ${cfg.brand}${at} is due today.` +
      `${amt ? ` Amount: ${amt}.` : ""}` +
      ` Kindly complete the payment to continue the batch.${pay}`;
  }
  const n = r.days_since || 0;
  return `Hello! A gentle reminder that ${name}'s coaching fee at ${cfg.brand}${at} is pending` +
    `${n > 0 ? `, ${n} ${n === 1 ? "day" : "days"} overdue` : ""}.` +
    `${amt ? ` Amount: ${amt}.` : ""}` +
    ` Please clear it so ${name} does not miss sessions. Do reply if you need any help.${pay}`;
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
  /* FAIL CLOSED. An academy with no number of its own does not send.
     The tempting alternative — quietly using the platform number — is
     the behaviour this change exists to remove: a client who believes
     their parents hear from THEM would still be sending as us, and
     would be spending the platform number's shared 250/day tier and
     staking its quality rating on their content. */
  if (!cfg.phoneNumberId) {
    return { ok: false, code: "no_number", retryable: false,
             message: `${cfg.brand} has no WhatsApp number of its own yet. ` +
                      `Add its phone number id to tenants.config.whatsapp.phoneNumberId ` +
                      `— reminders will not be sent from the platform number.` };
  }
  if (!cfg.token) {
    return { ok: false, code: "no_credentials", retryable: false,
             message: "No Meta access token for this academy." };
  }
  /* One WhatsApp Business account sends for every academy, so the
     templates on it are shared and their wording cannot name one. The
     academy is a PARAMETER — {{2}} — and this is the only place that
     supplies it. Get the order wrong and a Leo parent is told they owe
     money to Raj.

       {{1}} student   {{2}} academy   {{3}} amount   {{4}} due date
       {{5}} where to pay  — only when config.whatsapp.upiParam is true

     The header is not decoration: a template approved WITH a media
     header must be SENT with one, or Meta rejects the message
     outright. The same is true of the count of body variables: send
     five to a template approved with four and every message is
     rejected, so {{5}} is opt-in per academy. */
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
            ...(cfg.upiParam
              ? [{ type: "text",
                   text: r.upi_id
                     ? `${r.upi_id}${r.upi_name ? ` (${r.upi_name})` : ""}`
                     : "the account shared with you" }]
              : []),
          ],
        },
      ],
    },
  };

  try {
    // this academy's own number, resolved per tenant — never the platform's
    const res = await fetch(`${GRAPH}/${cfg.phoneNumberId}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${cfg.token}`, "Content-Type": "application/json" },
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

    /* A retry must name the same account the first attempt did, so it
       resolves through the same Postgres function rather than sending
       a blank or the academy default. Retries run within the hour, so
       this is the same answer unless staff deliberately changed it. */
    const [enr] = await db(
      `/enrollments?id=eq.${ev.enrollment_id}&select=centre_id,batch_id`);
    const upi = enr
      ? await rpc("resolve_upi",
          { p_tenant: tenant, p_centre: enr.centre_id, p_batch: enr.batch_id })
      : null;

    const row: QueueRow = {
      enrollment_id: ev.enrollment_id, member_id: ev.member_id,
      member_name: m.name, parent_name: null,
      phone: m.parent_phone || m.phone,
      centre: null, batch: null, sport: null,
      due_date: ev.due_date, days_since: ev.overdue_days, stage: ev.stage,
      amount: ev.amount, months: ev.months, fee_source: "retry",
      whatsapp_status: m.whatsapp_status, blocked_reason: null, already_sent: false,
      upi_id: upi?.vpa ?? null, upi_name: upi?.name ?? null,
      upi_source: upi?.source ?? null,
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

  /* Read the body ONCE as text: the signature is computed over the raw
     bytes, so parsing first and re-serialising would not reproduce it. */
  const raw = await req.text();
  if (!(await metaSignatureValid(raw, req.headers.get("x-hub-signature-256")))) {
    return new Response("bad signature", { status: 401 });
  }
  let payload: any = {};
  try { payload = JSON.parse(raw); } catch { payload = {}; }
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
    /* ---------- the door ----------
       Everything below this point can send messages, spend Meta quota,
       or read another academy's reminder queue, and `tenant` is a query
       parameter. /webhook is the one route Meta itself calls, so it is
       authenticated differently — by Meta's own signature — rather than
       waved through. */
    if (route === "webhook") return await handleWebhook(req);

    if (!FN_SECRET) {
      // Fail closed. An unset secret used to mean "wide open"; it now
      // means "not configured", which is a deployment error, not a
      // licence to send.
      console.error("AM_FN_SECRET is not set — refusing every call");
      return json({ error: "function not configured" }, 503);
    }
    if (!secretsMatch(req.headers.get("x-am-secret") || "", FN_SECRET)) {
      return json({ error: "unauthorized" }, 401);
    }

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
        /* ?id= identifies a single unknown id. Meta's dashboard shows
           several long numbers on one screen and names them
           inconsistently; asking the API what a thing IS beats
           squinting at the page. */
        const unknown = url.searchParams.get("id");
        if (unknown) {
          return json({
            id: unknown,
            as_waba: await ask("a WhatsApp Business Account?", `${unknown}?fields=id,name,currency,timezone_id`),
            its_numbers: await ask("...with these numbers", `${unknown}/phone_numbers?fields=id,display_phone_number,verified_name`),
            as_app: await ask("an App?", `${unknown}?fields=id,name,category,link`),
            as_business: await ask("a Business?", `${unknown}?fields=id,name,verification_status`),
            verification: await ask("what is outstanding on verification", `${unknown}?fields=verification_status,business_type,vertical,created_time,primary_page,link,is_disabled_for_integrity_reasons`),
            waba_health: await ask("account review + messaging tier", `${unknown}/owned_whatsapp_business_accounts?fields=id,name,account_review_status,business_verification_status,message_template_namespace`),
          });
        }
        /* `?waba=` asks the two questions that a bare "(#100) Invalid
           parameter" from /register hides: whether an app is actually
           subscribed to the account (nothing works if not), and whether
           the number has finished onboarding. Meta reports neither in
           the error. */
        const waba = url.searchParams.get("waba");
        /* Probe the number belonging to ?tenant=, so an operator can ask
           "is THIS academy's number healthy?". Falls back to the platform
           number when the tenant has none, because platform-level
           diagnostics are still useful. */
        const probeCfg = await loadConfig(tenant);
        const probePhone = probeCfg.phoneNumberId || META_PHONE;
        return json({
          for_tenant: tenant,
          using_number_id: probePhone,
          is_platform_number: !probeCfg.phoneNumberId,
          phone_number: await ask("the number itself", `${probePhone}?fields=id,display_phone_number,verified_name,quality_rating,status,code_verification_status,name_status,platform_type,throughput,account_mode,is_official_business_account,messaging_limit_tier`),
          its_waba: await ask("the account that owns it", `${probePhone}?fields=whatsapp_business_account{id,name}`),
          me: await ask("who the token is", "me?fields=id,name"),
          scopes: await ask("what the token is allowed to do", "me/permissions"),
          businesses: await ask("businesses it can see", "me/businesses?fields=id,name"),
          ...(waba ? {
            subscribed_apps: await ask("is an app subscribed to the WABA?", `${waba}/subscribed_apps`),
            waba_detail: await ask("the account's own state", `${waba}?fields=id,name,account_review_status`),
            /* Asked one field at a time. Graph fails the WHOLE request
               if any single field needs a permission the token lacks, so
               a combined read of six fields tells you nothing about the
               five that would have worked. */
            waba_limit: await ask("messaging limit", `${waba}?fields=message_template_namespace,currency,timezone_id`),
            waba_health2: await ask("health status", `${waba}?fields=health_status`),
            number_health: await ask("the number's health", `${probePhone}?fields=health_status`),
          } : {}),
        });
      }
      case "subscribe": {
        /* The step before registration, and the one whose absence is
           invisible: Cloud API will not register a number until an app
           is subscribed to its WABA, and /register reports that as a
           bare "(#100) Invalid parameter" naming nothing.
           `GET /{waba}/subscribed_apps` returning an empty array is the
           only way to see it. */
        const waba = url.searchParams.get("waba");
        if (!waba) return json({ error: "?waba=... is required" }, 400);
        const r = await fetch(`${GRAPH}/${waba}/subscribed_apps`, {
          method: "POST",
          headers: { Authorization: `Bearer ${META_TOKEN}` },
        });
        const out = await r.json();
        const after = await fetch(`${GRAPH}/${waba}/subscribed_apps`, {
          headers: { Authorization: `Bearer ${META_TOKEN}` },
        }).then((x) => x.json()).catch(() => null);
        return json({ subscribed: r.ok, meta: out, now_subscribed: after }, r.ok ? 200 : 400);
      }

      case "register": {
        /* The last setup step Cloud API needs: a number added to a WABA
           cannot send until it is registered, which is what WhatsApp
           Manager means by "Pending".
           
           The PIN is the caller's to choose and to remember — it becomes
           the number's two-step verification PIN, and it is needed again
           to move the number to another account later. It is never
           stored here and never defaulted, because a PIN nobody knows is
           worse than no PIN.
           
           Meta allows 10 registration attempts per number per 72 hours,
           so this reports rather than retries. */
        const b = await req.json().catch(() => ({}));
        const pin = String(b.pin || "");
        if (!/^\d{6}$/.test(pin)) {
          return json({ error: "a 6-digit pin is required: POST {\"pin\":\"123456\"}" }, 400);
        }
        /* India stores WhatsApp data locally, and some Indian WABAs
           will not register a number without the region named. Meta
           reports its absence as the same bare 100 as everything else,
           so it is offered rather than assumed. */
        const region = String(b.region || "");
        /* ?v=v23.0 overrides the Graph version for this call only.
           The function pins v20.0 for everything else, and changing that
           globally would move Raj's live sending at the same time — a
           diagnostic must not do that. */
        const ver = url.searchParams.get("v");
        const base = ver ? `https://graph.facebook.com/${ver}` : GRAPH;
        /* Register the number belonging to ?tenant=. Defaulting to the
           platform number here would mean an onboarding step for a new
           academy silently re-registered ours. */
        const regCfg = await loadConfig(tenant);
        if (!regCfg.phoneNumberId) {
          return json({ error: `${tenant} has no phoneNumberId configured; nothing to register.` }, 400);
        }
        const r = await fetch(`${base}/${regCfg.phoneNumberId}/register`, {
          method: "POST",
          headers: { Authorization: `Bearer ${regCfg.token}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            messaging_product: "whatsapp",
            pin,
            ...(region ? { data_localization_region: region } : {}),
          }),
        });
        const out = await r.json();
        if (!r.ok) {
          return json({
            registered: false,
            error: out?.error?.message || out,
            code: out?.error?.code,
            /* Meta's code 100 is "Invalid parameter" and says nothing on
               its own. The subcode and the user-facing pair are where it
               actually names the problem — a number that never finished
               Cloud API onboarding and one whose two-step PIN is already
               set both arrive here as a bare 100. */
            subcode: out?.error?.error_subcode,
            user_title: out?.error?.error_user_title,
            user_msg: out?.error?.error_user_msg,
            trace: out?.error?.fbtrace_id,
            hint: out?.error?.code === 133016
              ? "Ten attempts used in 72 hours; Meta has locked registration until the window clears."
              : out?.error?.code === 133005
                ? "That is not the number's existing two-step PIN. Use the one already set, or clear two-step verification in WhatsApp Manager first."
                : undefined,
          }, 400);
        }
        return json({ registered: true, meta: out });
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
      /* One real template message to ONE number you name, with sample
         values. It exists because there was no way to prove the WhatsApp
         setup works end to end without flipping a tenant to enabled+auto
         — which would let the next cron sweep message that academy's real
         parents. This route touches no tenant config, reads no queue and
         writes no reminder row; it is a wire test and nothing else.

         Still behind x-am-secret, because it can send a message. */
      case "test": {
        const b = await req.json().catch(() => ({}));
        const to = String(b.to || "").replace(/\D/g, "");
        if (to.length < 10) return json({ error: "to (a phone number) is required" }, 400);
        const cfg = await loadConfig(tenant);
        const stage = (b.stage === "due" || b.stage === "overdue") ? b.stage : "heads_up";
        const sample: QueueRow = {
          enrollment_id: 0, member_id: 0,
          member_name: String(b.student || "Aarav"),
          parent_name: null, phone: to,
          centre: null, batch: null, sport: null,
          due_date: String(b.due_date || new Date(Date.now() + 2 * 864e5).toISOString().slice(0, 10)),
          days_since: 0, stage,
          amount: b.amount == null ? 2400 : Number(b.amount),
          months: 1, fee_source: "test",
          whatsapp_status: "queued", blocked_reason: null, already_sent: false,
        };
        const res = await sendTemplate(to.length === 10 ? `91${to}` : to, sample, cfg);
        return json({
          test: true, to, stage,
          template: templateFor(stage, cfg),
          brand: cfg.brand,
          header_image: cfg.headerImage,
          result: res,
        }, res.ok ? 200 : 400);
      }
      default: return json({ error: `Unknown route "${route}"` }, 404);
    }
  } catch (e) {
    console.error(route, e);
    return json({ error: String(e) }, 500);
  }
});
