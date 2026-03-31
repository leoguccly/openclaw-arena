import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface AchievementDefinition {
  id: string;
  name: string;
  description: string;
  icon_key: string;
  required_count: number;
  is_progress_tracked: boolean;
}

interface UserAchievementRow {
  achievement_id: string;
  earned_at: string;
}

interface UserProgressRow {
  achievement_id: string;
  current_count: number;
}

interface EarnedAchievement extends AchievementDefinition {
  earned_at: string;
}

interface InProgressAchievement extends AchievementDefinition {
  current_count: number;
  required_count: number;
}

interface AchievementsResponse {
  earned: EarnedAchievement[];
  in_progress: InProgressAchievement[];
  locked: AchievementDefinition[];
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 1. Authentication ---
  const user = await getUserFromAuth(req.headers.get("Authorization"), req);
  if (!user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[get-achievements] Request from user ${user.id}`);

  // --- 2. Rate limiting ---
  const rateLimitResult = checkRateLimit(user.id, "get-achievements");
  if (!rateLimitResult.allowed) {
    return new Response(
      JSON.stringify({
        error: "Too many requests. Please wait before trying again.",
        retryAfter: rateLimitResult.retryAfter,
      }),
      {
        status: 429,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Retry-After": String(rateLimitResult.retryAfter ?? 10),
        },
      }
    );
  }

  const supabase = getSupabaseAdmin();

  // --- 3. Fetch all three datasets in parallel ---
  // achievements:            the full catalogue of achievement definitions
  // user_achievements:       which achievements this user has already earned
  // user_achievement_progress: current progress counts for tracked achievements
  const [definitionsResult, earnedResult, progressResult] = await Promise.all([
    supabase
      .from("achievements")
      .select("*")
      .order("required_count"),

    supabase
      .from("user_achievements")
      .select("achievement_id, earned_at")
      .eq("user_id", user.id),

    supabase
      .from("user_achievement_progress")
      .select("achievement_id, current_count")
      .eq("user_id", user.id),
  ]);

  // Any error from the definitions query is fatal — we cannot categorise
  // without the full catalogue.
  if (definitionsResult.error) {
    console.error(
      `[get-achievements] Failed to fetch achievement definitions:`,
      definitionsResult.error.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Non-fatal: if we cannot read earned/progress rows, treat them as empty
  // so the user at least sees the locked catalogue.
  if (earnedResult.error) {
    console.error(
      `[get-achievements] Failed to fetch user_achievements for ${user.id}:`,
      earnedResult.error.message
    );
  }
  if (progressResult.error) {
    console.error(
      `[get-achievements] Failed to fetch user_achievement_progress for ${user.id}:`,
      progressResult.error.message
    );
  }

  const definitions = (definitionsResult.data ?? []) as AchievementDefinition[];
  const earnedRows = (earnedResult.data ?? []) as UserAchievementRow[];
  const progressRows = (progressResult.data ?? []) as UserProgressRow[];

  // --- 4. Build lookup maps for O(1) categorisation ---
  const earnedMap = new Map<string, string>(); // achievement_id → earned_at
  for (const row of earnedRows) {
    earnedMap.set(row.achievement_id, row.earned_at);
  }

  const progressMap = new Map<string, number>(); // achievement_id → current_count
  for (const row of progressRows) {
    progressMap.set(row.achievement_id, row.current_count);
  }

  // --- 5. Categorise each achievement ---
  const result: AchievementsResponse = {
    earned: [],
    in_progress: [],
    locked: [],
  };

  for (const def of definitions) {
    if (earnedMap.has(def.id)) {
      result.earned.push({
        ...def,
        earned_at: earnedMap.get(def.id)!,
      });
    } else if (progressMap.has(def.id)) {
      result.in_progress.push({
        ...def,
        current_count: progressMap.get(def.id)!,
        required_count: def.required_count,
      });
    } else {
      result.locked.push(def);
    }
  }

  console.log(
    `[get-achievements] User ${user.id} — ` +
    `earned: ${result.earned.length}, in_progress: ${result.in_progress.length}, ` +
    `locked: ${result.locked.length}`
  );

  return new Response(
    JSON.stringify({ success: true, data: result }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
