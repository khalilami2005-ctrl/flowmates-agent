// Cloud AI coach — the paid counterpart to the agent's local assistant.
//
// GET  ?teamId=<id>  -> { used, limit, remaining, planId, allowed }
// POST { message, team_id, history, local_context } -> { reply, usage }
//
// Both shapes are dictated by the desktop client, not chosen here:
//   GET  is read at coach_chat.rs:126-141
//   POST is read at coach_chat.rs:210-237 — it requires `reply` to be a
//        non-empty string and passes `reasoning` through when present.
//
// Deploy:  supabase functions deploy coach-chat
// Secret:  supabase secrets set ANTHROPIC_API_KEY=sk-ant-...

import Anthropic from "npm:@anthropic-ai/sdk@^0.68.0";
import { createClient } from "npm:@supabase/supabase-js@^2.93.0";

const MODEL = "claude-opus-5";
const MAX_MESSAGE_LEN = 2000; // mirrors coach_chat.rs MAX_MESSAGE_LEN
const MAX_HISTORY_TURNS = 20; // the client sends its whole log; we cap the tail

const SYSTEM_PROMPT = `You are the Flowmates coach. You help one person understand
their own working patterns from measurements taken on their machine.

The measurements come from an agent that samples the active window and describes
it with a small local vision model. Treat them as an approximate signal, not
ground truth: categories are inferred and sometimes wrong, and gaps mean the
machine was idle or locked, not that the person was idle.

Ground every claim in a number from the context you were given. If the data does
not support an answer, say what is missing instead of guessing. Do not invent
metrics that are not present.

Never moralise about productivity, never compare the person to an imagined norm,
and never suggest working longer hours. Their own trend is the only baseline.

Be brief: a few sentences, plain prose, no headers or bullet lists unless the
answer is genuinely a list.`;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** The client shows `error` verbatim, so these strings are user-facing. */
function fail(message: string, status: number): Response {
  return json({ error: message }, status);
}

Deno.serve(async (req: Request) => {
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    // A missing key is an operator error, not a user error — say so plainly
    // rather than letting the SDK throw something opaque.
    return fail("The AI coach is not configured on this backend.", 503);
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization) {
    return fail("You must be signed in to use the AI coach.", 401);
  }

  // Acting as the caller, not as the service role: every RPC below then runs
  // under their JWT, so RLS and auth.uid() apply exactly as they would from
  // the desktop client. A service-role client here would silently bypass the
  // quota's ownership checks.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: authorization } } },
  );

  if (req.method === "GET") {
    const { data, error } = await supabase.rpc("get_coach_usage");
    if (error) return fail(error.message, 403);
    return json(data);
  }

  if (req.method !== "POST") {
    return fail("Method not allowed.", 405);
  }

  let payload: {
    message?: string;
    team_id?: string | null;
    history?: Array<{ role?: string; content?: string }>;
    local_context?: unknown;
  };
  try {
    payload = await req.json();
  } catch {
    return fail("Malformed request body.", 400);
  }

  const message = (payload.message ?? "").trim();
  if (!message) return fail("Message cannot be empty.", 400);
  if (message.length > MAX_MESSAGE_LEN) {
    return fail(`Message must be ${MAX_MESSAGE_LEN} characters or fewer.`, 400);
  }

  // Claim the message before spending anything on the model. The RPC raises a
  // legible error when the plan is missing or the daily allowance is spent.
  const { data: usage, error: usageError } = await supabase.rpc(
    "consume_coach_message",
  );
  if (usageError) return fail(usageError.message, 403);

  // The client sends its entire local log; only the tail is useful and the
  // rest is tokens. The final entry is the message we already have.
  const history = (payload.history ?? [])
    .filter((m) =>
      (m.role === "user" || m.role === "assistant") &&
      typeof m.content === "string" && m.content.trim() !== ""
    )
    .slice(-MAX_HISTORY_TURNS - 1, -1)
    .map((m) => ({
      role: m.role as "user" | "assistant",
      content: m.content as string,
    }));

  const context = JSON.stringify(payload.local_context ?? {}).slice(0, 24_000);

  const anthropic = new Anthropic({ apiKey: anthropicKey });

  try {
    const response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 1024,
      thinking: { type: "adaptive" },
      output_config: { effort: "medium" },
      system: SYSTEM_PROMPT,
      messages: [
        ...history,
        {
          role: "user",
          content:
            `Measurements for the last 7 days, as JSON:\n${context}\n\n${message}`,
        },
      ],
    });

    // Safety classifiers can decline with HTTP 200 and an empty content array —
    // reading content[0] unconditionally would throw here.
    if (response.stop_reason === "refusal") {
      return fail(
        "The assistant declined to answer that. Try rephrasing your question.",
        422,
      );
    }

    const reply = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("")
      .trim();

    if (!reply) {
      return fail("The assistant returned an empty response.", 502);
    }

    return json({ reply, usage });
  } catch (e) {
    console.error("[coach-chat] model call failed:", e);
    // The message is already claimed. Refunding it would need a second RPC and
    // would hand a free retry to anyone who can make the model time out.
    return fail("The assistant is unavailable right now. Try again shortly.", 502);
  }
});
