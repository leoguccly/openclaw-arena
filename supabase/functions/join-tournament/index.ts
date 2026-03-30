import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface JoinTournamentBody {
  tournament_id: string;
}

interface TournamentParticipant {
  id: string;
  tournament_id: string;
  user_id: string;
  joined_at: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// PostgreSQL error codes and application-level error messages returned by the
// join_tournament_txn RPC. We inspect both pg_exception_detail / message to
// distinguish the four business-rule rejections.
const PG_UNIQUE_VIOLATION = "23505";

// ---------------------------------------------------------------------------
// Helper — map RPC error to HTTP response
// ---------------------------------------------------------------------------

function mapRpcError(err: unknown): Response {
  const message =
    err instanceof Error ? err.message.toLowerCase() : String(err).toLowerCase();

  // Unique-violation code → already joined
  // deno-lint-ignore no-explicit-any
  const code = (err as any)?.code ?? "";

  if (code === PG_UNIQUE_VIOLATION || message.includes("already joined")) {
    return new Response(
      JSON.stringify({ error: "You have already joined this tournament." }),
      {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  if (message.includes("tournament_not_found") || message.includes("tournament not found")) {
    return new Response(
      JSON.stringify({ error: "Tournament not found." }),
      {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  if (message.includes("tournament_closed") || message.includes("tournament is closed")) {
    return new Response(
      JSON.stringify({ error: "This tournament is no longer accepting participants." }),
      {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  if (message.includes("tournament_full") || message.includes("tournament is full")) {
    return new Response(
      JSON.stringify({ error: "This tournament has reached its participant limit." }),
      {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  if (message.includes("insufficient_balance") || message.includes("insufficient balance")) {
    return new Response(
      JSON.stringify({ error: "Insufficient balance to join this tournament." }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Unrecognised DB error — do not leak internals
  console.error("[join-tournament] Unhandled RPC error:", err);
  return new Response(
    JSON.stringify({ error: "An error occurred. Please try again." }),
    {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Authentication ---
  const user = await getUserFromAuth(req.headers.get("authorization"), req);
  if (!user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[join-tournament] Request from user ${user.id}`);

  // --- Rate limiting ---
  const rateLimitResult = checkRateLimit(user.id, "join-tournament");
  if (!rateLimitResult.allowed) {
    return new Response(
      JSON.stringify({
        error: "Rate limit exceeded",
        retryAfter: rateLimitResult.retryAfter,
      }),
      {
        status: 429,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Retry-After": String(rateLimitResult.retryAfter ?? 1),
        },
      }
    );
  }

  // --- Parse body ---
  let body: JoinTournamentBody;
  try {
    body = await req.json() as JoinTournamentBody;
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Validate tournament_id ---
  const { tournament_id } = body;

  if (!tournament_id || typeof tournament_id !== "string") {
    return new Response(
      JSON.stringify({ error: "tournament_id is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!UUID_REGEX.test(tournament_id)) {
    return new Response(
      JSON.stringify({ error: "tournament_id must be a valid UUID" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[join-tournament] User ${user.id} attempting to join tournament ${tournament_id}`
  );

  // --- Call RPC ---
  const supabase = getSupabaseAdmin();

  const { data, error } = await supabase.rpc("join_tournament_txn", {
    p_tournament_id: tournament_id,
    p_user_id: user.id,
  });

  if (error) {
    return mapRpcError(error);
  }

  const participant = data as TournamentParticipant;

  console.log(
    `[join-tournament] User ${user.id} successfully joined tournament ${tournament_id}`
  );

  return new Response(
    JSON.stringify({ success: true, data: participant }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
