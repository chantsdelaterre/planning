// planning-api : seule porte d'entrée de l'appli planning.
// 1. Établit l'identité à partir du jeton (même mécanisme que Suivi des temps) :
//    - jeton_admin : administrateur de Suivi des temps (table admins, actif) ;
//    - jeton       : collaborateur (RPC collab_session, actif) -> sa personne.
// 2. Transmet à public.planning_appel, qui exécute la logique avec les droits du planning.
// Ne journalise jamais de jeton ni de donnée.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const ACTIONS = new Set([
  "session", "semaine", "recap", "realise", "seance_creer", "seance_modifier", "seance_supprimer", "serie_creer", "serie_arreter",
  "affecter", "retirer", "suspendre", "reprendre", "jour_fermer",
  "admin_lire", "personne_creer", "personne_modifier", "personne_archiver", "personne_rattacher",
  "ref_enregistrer", "ref_archiver", "responsable", "habituel", "acces_regler", "lien_generer", "lien_revoquer", "admin_niveau", "alertes_lire", "alertes_vues",
]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);

  let corps: any;
  try { corps = await req.json(); } catch { return json({ ok: false, error: "JSON invalide" }, 400); }
  const action = String(corps?.action ?? "");
  if (!ACTIONS.has(action)) return json({ ok: false, error: "Action inconnue" }, 400);
  const params = corps?.params && typeof corps.params === "object" ? corps.params : {};

  const sb = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");

  // Identité
  let identite: Record<string, unknown> | null = null;
  const jetonAdmin = String(corps?.jeton_admin ?? "").trim();
  const jeton = String(corps?.jeton ?? "").trim();
  const lien = String(corps?.lien ?? "").trim();
  if (lien) {
    // Lien propre au planning : vérifié (empreinte, révocation, fiche active) dans la base.
    if (!/^[0-9a-f]{64}$/.test(lien)) return json({ ok: false, error: "lien_invalide" }, 401);
    identite = { type: "lien", jeton: lien };
  } else if (jetonAdmin) {
    const { data, error } = await sb.from("admins").select("admin_id").eq("token", jetonAdmin).eq("actif", true).maybeSingle();
    if (error) return json({ ok: false, error: "Erreur base (admin)" }, 500);
    if (data) identite = { type: "admin", admin_id: data.admin_id };
  } else if (jeton) {
    const { data, error } = await sb.rpc("collab_session", { p_token: jeton });
    if (error) return json({ ok: false, error: "Erreur base (session)" }, 500);
    if (data?.ok === true) {
      const collabId = data.collab?.collab_id;
      const { data: f, error: e2 } = await sb.from("collaborateurs").select("personne_id").eq("collab_id", collabId).single();
      if (e2 || !f) return json({ ok: false, error: "Erreur base (personne)" }, 500);
      identite = { type: "collab", collab_id: collabId, personne_id: f.personne_id };
    }
  }
  if (!identite) return json({ ok: false, error: "lien_invalide" }, 401);

  // Logique
  const { data, error } = await sb.rpc("planning_appel", { p_identite: identite, p_action: action, p_params: params });
  if (error) {
    // Les erreurs métier sont des messages en français destinés à l'écran.
    const metier = error.code === "P0001";
    return json({ ok: false, error: metier ? error.message : "Erreur base" }, metier ? 400 : 500);
  }
  return json({ ok: true, ...(data as Record<string, unknown>) });
});
