// Cloud insights — writes a period summary into public.cloud_insights.
//
// POST { period_days, team_id, plan, local_report? } -> the inserted row
//
// Shape comes from entitlements.rs:210-238, which posts that body and returns
// the parsed JSON straight to the caller. `local_report` is present only for
// the `individual` plan (entitlements.rs:216).
//
// NOTE: nothing in the renderer calls request_cloud_insights today, so this
// function currently has no client. It is written against the Rust contract so
// that wiring the UI is the only remaining step.
//
// Deploy:  supabase functions deploy generate-insights
// Secret:  supabase secrets set ANTHROPIC_API_KEY=sk-ant-...

import Anthropic from "npm:@anthropic-ai/sdk@^0.68.0";
import { createClient } from "npm:@supabase/supabase-js@^2.93.0";

const MODEL = "claude-opus-5";

const SYSTEM_PROMPT = `You summarise one person's working period from measurements
taken on their machine.

Return prose only — no headers, no bullet lists. Three or four sentences.

Every claim must rest on a number present in the data. Where the data is thin,
say so rather than filling the gap. The categories were inferred by a small
local model and are sometimes wrong; treat them as a signal, not a fact.

Do not moralise, do not compare the person to any norm, and do not suggest
working longer. Describe what changed and what it suggests, nothing more.`;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    return json({ error: "Cloud insights are not configured on this backend." }, 503);
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization) {
    return json({ error: "You must be signed in." }, 401);
  }

  // Caller's JWT, not the service role: the insert below is then subject to the
  // same RLS as any other client write, and auth.uid() identifies the author.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: authorization } } },
  );

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData?.user) {
    return json({ error: "Your session has expired. Sign in again." }, 401);
  }
  const userId = userData.user.id;

  let payload: {
    period_days?: number;
    team_id?: string | null;
    plan?: string | null;
    local_report?: unknown;
  };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Malformed request body." }, 400);
  }

  // entitlements.rs already clamps to 1..30; clamp again rather than trust it.
  const periodDays = Math.min(Math.max(payload.period_days ?? 7, 1), 30);
  const teamId = payload.team_id ?? null;

  // Read the entitlement from the database rather than the request body — the
  // `plan` the client sends is a hint, and a client that could set its own plan
  // could grant itself the feature.
  const { data: entitlements, error: entError } = await supabase.rpc(
    "get_user_entitlements",
  );
  if (entError) return json({ error: entError.message }, 403);
  if (!entitlements?.features?.cloud_ai) {
    return json(
      { error: "Cloud insights require an Individual or Team license." },
      403,
    );
  }

  // For an individual plan the agent ships its own computed report; for a team
  // plan it doesn't, so fall back to the aggregates already synced up.
  let source = payload.local_report;
  if (!source) {
    const since = new Date(Date.now() - periodDays * 86_400_000).toISOString()
      .slice(0, 10);
    let query = supabase
      .from("work_sessions")
      .select("session_date, duration_seconds, category_breakdown, summary")
      .gte("session_date", since)
      .order("session_date", { ascending: false })
      .limit(200);
    if (teamId) query = query.eq("team_id", teamId);

    const { data: sessions, error: sessionsError } = await query;
    if (sessionsError) return json({ error: sessionsError.message }, 400);
    if (!sessions || sessions.length === 0) {
      return json(
        { error: "No activity in this period yet — nothing to summarise." },
        422,
      );
    }
    source = sessions;
  }

  const context = JSON.stringify(source).slice(0, 48_000);
  const anthropic = new Anthropic({ apiKey: anthropicKey });

  let body: string;
  let title: string;
  try {
    const response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 1024,
      thinking: { type: "adaptive" },
      output_config: {
        effort: "medium",
        format: {
          type: "json_schema",
          schema: {
            type: "object",
            properties: {
              title: {
                type: "string",
                description: "Six words or fewer, no trailing punctuation.",
              },
              body: {
                type: "string",
                description: "Three or four sentences of plain prose.",
              },
            },
            required: ["title", "body"],
            additionalProperties: false,
          },
        },
      },
      system: SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content:
            `Measurements for the last ${periodDays} days, as JSON:\n${context}`,
        },
      ],
    });

    if (response.stop_reason === "refusal") {
      return json({ error: "The model declined to summarise this period." }, 422);
    }

    const raw = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("");
    const parsed = JSON.parse(raw) as { title?: string; body?: string };
    title = (parsed.title ?? "").trim() || `Last ${periodDays} days`;
    body = (parsed.body ?? "").trim();
    if (!body) throw new Error("empty body");
  } catch (e) {
    console.error("[generate-insights] model call failed:", e);
    return json({ error: "Could not generate insights right now." }, 502);
  }

  const { data: inserted, error: insertError } = await supabase
    .from("cloud_insights")
    .insert({
      team_id: teamId,
      user_id: userId,
      period_days: periodDays,
      title,
      body,
      metrics: { source: payload.local_report ? "local_report" : "work_sessions" },
    })
    .select()
    .single();

  if (insertError) return json({ error: insertError.message }, 400);

  return json(inserted);
});
