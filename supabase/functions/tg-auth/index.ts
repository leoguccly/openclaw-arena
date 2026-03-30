import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { initData } = await req.json();
    if (!initData) {
      return new Response(
        JSON.stringify({ error: "initData is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 解析 initData
    const params = new URLSearchParams(initData);
    const userStr = params.get("user");
    if (!userStr) {
      return new Response(
        JSON.stringify({ error: "No user in initData" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const tgUser = JSON.parse(userStr);
    const tgId = tgUser.id;
    const email = `tg_${tgId}@arena.internal`;
    const internalSecret = Deno.env.get("INTERNAL_SECRET");

    console.log(`[tg-auth] tgId=${tgId}, email=${email}`);

    if (!internalSecret) {
      return new Response(
        JSON.stringify({ error: "INTERNAL_SECRET not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // bcrypt has a 72-char limit; INTERNAL_SECRET is 64 chars, tg_id ~10 chars
    // Use only the first 16 chars of the secret to stay well under the limit
    const password = `tg_${tgId}_${internalSecret.slice(0, 16)}`;
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Step 1: 尝试登录
    console.log(`[tg-auth] Attempting signIn...`);
    const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (!signInError && signInData?.session) {
      // 登录成功 — 已有用户
      console.log(`[tg-auth] signIn OK — user=${signInData.user.id}`);
      return new Response(
        JSON.stringify({
          access_token: signInData.session.access_token,
          refresh_token: signInData.session.refresh_token,
          user: signInData.user,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[tg-auth] signIn failed: ${signInError?.message}. Trying signUp...`);

    // Step 2: 用 signUp 注册新用户（不用 admin API）
    const { data: signUpData, error: signUpError } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          tg_id: tgId,
          first_name: tgUser.first_name ?? "",
          username: tgUser.username ?? "",
        },
      },
    });

    console.log(`[tg-auth] signUp result: ${signUpError ? "FAILED: " + signUpError.message : "OK, user=" + signUpData?.user?.id}`);

    if (signUpError) {
      return new Response(
        JSON.stringify({ error: signUpError.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // signUp 可能直接返回 session（如果 email confirm 关闭的话）
    if (signUpData?.session) {
      console.log(`[tg-auth] signUp returned session directly`);
      return new Response(
        JSON.stringify({
          access_token: signUpData.session.access_token,
          refresh_token: signUpData.session.refresh_token,
          user: signUpData.user,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // signUp 成功但没返回 session — 需要 email 确认
    // 用 admin API 手动确认 email
    console.log(`[tg-auth] No session from signUp, confirming email via admin...`);
    if (signUpData?.user?.id) {
      const confirmRes = await fetch(`${supabaseUrl}/auth/v1/admin/users/${signUpData.user.id}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${serviceRoleKey}`,
          "apikey": serviceRoleKey,
        },
        body: JSON.stringify({ email_confirm: true }),
      });
      console.log(`[tg-auth] Confirm email HTTP ${confirmRes.status}`);
    }

    // Step 3: 再次登录
    console.log(`[tg-auth] Retry signIn after signUp...`);
    const { data: retryData, error: retryError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (retryError || !retryData?.session) {
      console.log(`[tg-auth] Retry failed: ${retryError?.message}`);
      return new Response(
        JSON.stringify({ error: retryError?.message ?? "Auth failed after signup" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[tg-auth] SUCCESS — user=${retryData.user.id}`);
    return new Response(
      JSON.stringify({
        access_token: retryData.session.access_token,
        refresh_token: retryData.session.refresh_token,
        user: retryData.user,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (err) {
    console.error("[tg-auth] FATAL:", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
