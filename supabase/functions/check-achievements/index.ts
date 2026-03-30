import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin } from "../_shared/supabase-client.ts";

// ---------------------------------------------------------------------------
// Constants — achievement codes and thresholds
// ---------------------------------------------------------------------------

/**
 * All achievement codes must match the `code` column in the `achievements` table.
 * These are referenced as stable string literals; changes here must be mirrored
 * in the DB seed / migration.
 */
const ACH_CLAW_CRUSHER = "ACH-001";  // Beat OpenClaw ROI 3 times
const ACH_DAREDEVIL    = "ACH-002";  // Survived 100x leverage
const ACH_ARENA_ELITE  = "ACH-003";  // Top 10 in a tournament
const ACH_GOLDEN_CLAW  = "ACH-004";  // 50%+ ROI on a single trade
const ACH_STREAK_KEEPER = "ACH-005"; // 7-day login streak
const ACH_SURVIVOR     = "ACH-006";  // Trade open 24+ hours without liquidation

const CLAW_CRUSHER_REQUIRED = 3;
const GOLDEN_CLAW_ROI_THRESHOLD = 0.5; // realised_pnl / margin > 0.5
const STREAK_KEEPER_THRESHOLD = 7;     // days
const SURVIVOR_HOLD_MS = 24 * 60 * 60 * 1_000; // 24 hours in milliseconds

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type TriggerEvent = "trade_closed" | "tournament_settled" | "streak_claimed";

interface CheckAchievementsRequest {
  user_id: string;
  trigger_event: TriggerEvent;
  event_data: Record<string, unknown>;
}

interface AchievementRow {
  id: string;          // The achievement code, e.g. 'ACH-001' (PK in achievements table)
  name: string;
  description: string;
  required_count: number;
}

interface UserProgressRow {
  achievement_id: string;
  current_count: number;
}

interface NewlyEarned {
  id: string;           // Achievement code, e.g. 'ACH-001'
  name: string;
  description: string;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Awards an achievement to a user. Uses INSERT ... ON CONFLICT DO NOTHING for
 * full idempotency — calling this multiple times is safe.
 *
 * Returns true if the achievement was newly inserted, false if already present.
 */
async function awardAchievement(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievementId: string,
  achievementCode: string
): Promise<boolean> {
  const { error } = await supabase.from("user_achievements").insert({
    user_id: userId,
    achievement_id: achievementId,
    earned_at: new Date().toISOString(),
  });

  // PostgreSQL unique violation (23505) means it was already awarded — not an error.
  if (error) {
    const pgCode = (error as { code?: string }).code ?? "";
    if (pgCode === "23505") {
      return false;
    }
    console.error(
      `[check-achievements] Failed to award ${achievementCode} to user ${userId}:`,
      error.message
    );
    return false;
  }

  console.log(
    `[check-achievements] Awarded ${achievementCode} to user ${userId}`
  );
  return true;
}

/**
 * Checks whether the user has already earned a specific achievement.
 */
async function hasEarned(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievementId: string
): Promise<boolean> {
  const { data, error } = await supabase
    .from("user_achievements")
    .select("achievement_id")
    .eq("user_id", userId)
    .eq("achievement_id", achievementId)
    .maybeSingle();

  if (error) {
    console.error(
      `[check-achievements] hasEarned query error for user ${userId}:`,
      error.message
    );
    // Treat as not earned to avoid blocking re-evaluation; awardAchievement
    // is idempotent anyway via ON CONFLICT DO NOTHING.
    return false;
  }

  return data !== null;
}

/**
 * Upserts the user's progress counter for a progress-tracked achievement and
 * returns the new count.
 */
async function upsertProgress(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievementId: string,
  increment: number
): Promise<number> {
  // Fetch current count first so we can do the arithmetic in TypeScript.
  const { data: existing, error: fetchError } = await supabase
    .from("user_achievement_progress")
    .select("current_count")
    .eq("user_id", userId)
    .eq("achievement_id", achievementId)
    .maybeSingle();

  if (fetchError) {
    console.error(
      `[check-achievements] upsertProgress fetch error for user ${userId} ach ${achievementId}:`,
      fetchError.message
    );
    return 0;
  }

  const currentRow = existing as UserProgressRow | null;
  const newCount = (currentRow?.current_count ?? 0) + increment;

  const { error: upsertError } = await supabase
    .from("user_achievement_progress")
    .upsert(
      {
        user_id: userId,
        achievement_id: achievementId,
        current_count: newCount,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "user_id,achievement_id" }
    );

  if (upsertError) {
    console.error(
      `[check-achievements] upsertProgress upsert error for user ${userId}:`,
      upsertError.message
    );
    return currentRow?.current_count ?? 0;
  }

  return newCount;
}

// ---------------------------------------------------------------------------
// Achievement evaluators
// ---------------------------------------------------------------------------

/**
 * ACH-001 Claw Crusher — Beat OpenClaw's ROI 3 times.
 *
 * Triggered by: trade_closed
 * event_data: { user_roi: number, openclaw_roi: number }
 */
async function evaluateClawCrusher(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievement: AchievementRow,
  eventData: Record<string, unknown>
): Promise<boolean> {
  const userRoi = typeof eventData.user_roi === "number" ? eventData.user_roi : null;
  const openclawRoi = typeof eventData.openclaw_roi === "number" ? eventData.openclaw_roi : null;

  if (userRoi === null || openclawRoi === null) {
    console.log(
      `[check-achievements] ACH-001 skipped — missing user_roi or openclaw_roi in event_data`
    );
    return false;
  }

  if (userRoi <= openclawRoi) {
    return false;
  }

  // User beat OpenClaw this trade — increment progress
  const newCount = await upsertProgress(supabase, userId, achievement.id, 1);
  console.log(
    `[check-achievements] ACH-001 progress for user ${userId}: ${newCount}/${CLAW_CRUSHER_REQUIRED}`
  );

  if (newCount >= CLAW_CRUSHER_REQUIRED) {
    return await awardAchievement(supabase, userId, achievement.id, ACH_CLAW_CRUSHER);
  }

  return false;
}

/**
 * ACH-002 Daredevil — Trade at 100x leverage without being liquidated.
 *
 * Triggered by: trade_closed
 * event_data: { leverage: number, status: string }
 */
async function evaluateDaredevil(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievement: AchievementRow,
  eventData: Record<string, unknown>
): Promise<boolean> {
  const leverage = typeof eventData.leverage === "number" ? eventData.leverage : 0;
  const status = typeof eventData.status === "string" ? eventData.status : "";

  if (leverage < 100 || status === "liquidated") {
    return false;
  }

  return await awardAchievement(supabase, userId, achievement.id, ACH_DAREDEVIL);
}

/**
 * ACH-003 Arena Elite — Finish in the top 10 of a tournament.
 *
 * Triggered by: tournament_settled
 * event_data: { rank: number, total_participants: number }
 */
async function evaluateArenaElite(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievement: AchievementRow,
  eventData: Record<string, unknown>
): Promise<boolean> {
  const rank = typeof eventData.rank === "number" ? eventData.rank : Infinity;
  const totalParticipants =
    typeof eventData.total_participants === "number" ? eventData.total_participants : 0;

  // Top 10 threshold: min(10, total_participants)
  const threshold = Math.min(10, totalParticipants);

  if (rank > threshold) {
    return false;
  }

  return await awardAchievement(supabase, userId, achievement.id, ACH_ARENA_ELITE);
}

/**
 * ACH-004 Golden Claw — Achieve 50%+ ROI on a single trade.
 * ROI = realised_pnl / margin > 0.5
 *
 * Triggered by: trade_closed
 * event_data: { realised_pnl: number, margin: number }
 */
async function evaluateGoldenClaw(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievement: AchievementRow,
  eventData: Record<string, unknown>
): Promise<boolean> {
  const realisedPnl =
    typeof eventData.realised_pnl === "number" ? eventData.realised_pnl : null;
  const margin = typeof eventData.margin === "number" ? eventData.margin : null;

  if (realisedPnl === null || margin === null || margin === 0) {
    return false;
  }

  const roi = realisedPnl / margin;
  if (roi <= GOLDEN_CLAW_ROI_THRESHOLD) {
    return false;
  }

  return await awardAchievement(supabase, userId, achievement.id, ACH_GOLDEN_CLAW);
}

/**
 * ACH-005 Streak Keeper — Maintain a 7-day login/claim streak.
 *
 * Triggered by: streak_claimed
 * event_data: { streak: number }
 */
async function evaluateStreakKeeper(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievement: AchievementRow,
  eventData: Record<string, unknown>
): Promise<boolean> {
  const streak = typeof eventData.streak === "number" ? eventData.streak : 0;

  if (streak < STREAK_KEEPER_THRESHOLD) {
    return false;
  }

  return await awardAchievement(supabase, userId, achievement.id, ACH_STREAK_KEEPER);
}

/**
 * ACH-006 Survivor — Hold a trade open for 24+ hours without being liquidated.
 *
 * Triggered by: trade_closed
 * event_data: { created_at: string, updated_at: string, status: string }
 */
async function evaluateSurvivor(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievement: AchievementRow,
  eventData: Record<string, unknown>
): Promise<boolean> {
  const status = typeof eventData.status === "string" ? eventData.status : "";
  const createdAtRaw = typeof eventData.created_at === "string" ? eventData.created_at : null;
  const updatedAtRaw = typeof eventData.updated_at === "string" ? eventData.updated_at : null;

  if (status !== "closed" || !createdAtRaw || !updatedAtRaw) {
    return false;
  }

  const createdAt = Date.parse(createdAtRaw);
  const updatedAt = Date.parse(updatedAtRaw);

  if (isNaN(createdAt) || isNaN(updatedAt)) {
    console.log(
      `[check-achievements] ACH-006 skipped — unparseable timestamps for user ${userId}`
    );
    return false;
  }

  const holdDurationMs = updatedAt - createdAt;
  if (holdDurationMs < SURVIVOR_HOLD_MS) {
    return false;
  }

  return await awardAchievement(supabase, userId, achievement.id, ACH_SURVIVOR);
}

// ---------------------------------------------------------------------------
// Evaluator dispatch table
// ---------------------------------------------------------------------------

type Evaluator = (
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  achievement: AchievementRow,
  eventData: Record<string, unknown>
) => Promise<boolean>;

/**
 * Maps achievement codes to their evaluator functions and the trigger events
 * that should activate them. Achievements are skipped when the incoming
 * trigger_event does not match any of their eligible triggers.
 */
const EVALUATORS: Record<
  string,
  { triggers: TriggerEvent[]; evaluate: Evaluator }
> = {
  [ACH_CLAW_CRUSHER]:   { triggers: ["trade_closed"],        evaluate: evaluateClawCrusher },
  [ACH_DAREDEVIL]:      { triggers: ["trade_closed"],        evaluate: evaluateDaredevil },
  [ACH_ARENA_ELITE]:    { triggers: ["tournament_settled"],  evaluate: evaluateArenaElite },
  [ACH_GOLDEN_CLAW]:    { triggers: ["trade_closed"],        evaluate: evaluateGoldenClaw },
  [ACH_STREAK_KEEPER]:  { triggers: ["streak_claimed"],      evaluate: evaluateStreakKeeper },
  [ACH_SURVIVOR]:       { triggers: ["trade_closed"],        evaluate: evaluateSurvivor },
};

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

  // --- 1. Service-role gate ---
  // This function is internal-only. It must never be exposed to end users.
  // Validate that the caller supplies the service_role key via the apikey header.
  const apikey = req.headers.get("apikey") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  if (!apikey || apikey !== serviceRoleKey) {
    console.warn("[check-achievements] Rejected request — service_role key missing or invalid");
    return new Response(
      JSON.stringify({ error: "Forbidden" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 2. Parse request body ---
  let body: CheckAchievementsRequest;
  try {
    body = await req.json() as CheckAchievementsRequest;
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 3. Validate required fields ---
  const { user_id, trigger_event, event_data } = body;

  if (!user_id || typeof user_id !== "string") {
    return new Response(
      JSON.stringify({ error: "user_id is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const validTriggers: TriggerEvent[] = ["trade_closed", "tournament_settled", "streak_claimed"];
  if (!validTriggers.includes(trigger_event)) {
    return new Response(
      JSON.stringify({
        error: `trigger_event must be one of: ${validTriggers.join(", ")}`,
      }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (typeof event_data !== "object" || event_data === null) {
    return new Response(
      JSON.stringify({ error: "event_data must be a JSON object" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[check-achievements] trigger=${trigger_event} user=${user_id} ` +
    `event_data=${JSON.stringify(event_data)}`
  );

  const supabase = getSupabaseAdmin();

  // --- 4. Fetch all achievement definitions ---
  const { data: definitionsData, error: defError } = await supabase
    .from("achievements")
    .select("id, name, description, required_count");

  if (defError) {
    console.error(
      "[check-achievements] Failed to fetch achievement definitions:",
      defError.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const definitions = (definitionsData ?? []) as AchievementRow[];

  // --- 5. Evaluate each achievement ---
  const newlyEarned: NewlyEarned[] = [];

  for (const def of definitions) {
    const entry = EVALUATORS[def.id];
    if (!entry) {
      // No evaluator registered — skip silently (future-proof for new codes)
      continue;
    }

    if (!entry.triggers.includes(trigger_event)) {
      // Wrong trigger type for this achievement — skip
      continue;
    }

    // Progress-tracking achievements (ACH-001) evaluate even if already earned,
    // because the progress may be reset or extended. All award calls are
    // idempotent via ON CONFLICT DO NOTHING, so double-awarding is safe.
    let wasEarned = false;
    try {
      wasEarned = await entry.evaluate(supabase, user_id, def, event_data);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(
        `[check-achievements] Evaluator for ${def.id} threw for user ${user_id}:`,
        message
      );
      // Continue evaluating other achievements
    }

    if (wasEarned) {
      newlyEarned.push({
        id: def.id,
        name: def.name,
        description: def.description,
      });
    }
  }

  console.log(
    `[check-achievements] Evaluation complete for user ${user_id} — ` +
    `newly earned: ${newlyEarned.length} (${newlyEarned.map((a) => a.id).join(", ") || "none"})`
  );

  return new Response(
    JSON.stringify({ success: true, data: { newly_earned: newlyEarned } }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
