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
    const password = `tg_${tgId}_${Deno.env.get("INTERNAL_SECRET")}`;

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } }
    );

    // 尝试登录，失败则注册
    let { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (signInError) {
      // 用户不存在，注册新用户
      const { data: signUpData, error: signUpError } = await supabase.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          tg_id: tgId,
          first_name: tgUser.first_name ?? "",
          username: tgUser.username ?? "",
        },
      });

      if (signUpError) {
        return new Response(
          JSON.stringify({ error: signUpError.message }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // 注册后再登录拿 token
      const { data: retryData, error: retryError } = await supabase.auth.signInWithPassword({
        email,
        password,
      });

      if (retryError || !retryData.session) {
        return new Response(
          JSON.stringify({ error: "Auth failed after signup" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      signInData = retryData;
    }

    return new Response(
      JSON.stringify({
        access_token: signInData!.session!.access_token,
        refresh_token: signInData!.session!.refresh_token,
        user: signInData!.user,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (err) {
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
