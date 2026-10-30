#!/usr/bin/env bash
# Applique les migrations de migrations/ dans l'ordre alphabétique.
#
#   outils/appliquer.sh analyser   <url>     -> liste ce qui reste à appliquer, classe chaque migration
#   outils/appliquer.sh appliquer  <url> [--avec-validation]
#
# Ne jamais afficher de données : seulement des noms de fichiers et des compteurs.
set -euo pipefail

mode="${1:?mode}"; url="${2:?url}"; avec_validation="${3:-}"
cd "$(dirname "$0")/.."
export PGOPTIONS="${PGOPTIONS:-} -c statement_timeout=120000"
PSQL=(psql "$url" -X -q -v ON_ERROR_STOP=1)

sortie() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT" || true; }

classe_de() {
  local f="$1" entete
  entete=$(head -n1 "$f" | tr -d '\r')
  # Méta-commandes psql (lignes commençant par \) : interdites partout.
  if grep -qE '^[[:space:]]*\\' "$f"; then echo "interdite"; return; fi
  if [ "$entete" != "-- portee: planning" ]; then echo "validation"; return; fi
  if grep -qiE '\b(drop|truncate)\b|delete[[:space:]]+from|\b(set|reset)[[:space:]]+(local[[:space:]]+|session[[:space:]]+)?role\b|session[[:space:]]+authorization|\bpg_read_file\b|\bdblink\b' "$f"; then
    echo "validation"; return
  fi
  echo "planning"
}

deja_appliquees() {
  local existe
  existe=$("${PSQL[@]}" -At -c "select to_regclass('planning._migrations') is not null")
  if [ "$existe" = "t" ]; then "${PSQL[@]}" -At -c "select nom from planning._migrations"; fi
}

mapfile -t appliquees < <(deja_appliquees)
a_faire=(); besoin_validation=false
for f in migrations/*.sql; do
  [ -e "$f" ] || continue
  nom=$(basename "$f")
  if printf '%s\n' "${appliquees[@]:-}" | grep -qxF "$nom"; then continue; fi
  c=$(classe_de "$f")
  if [ "$c" = "interdite" ]; then echo "::error::$nom contient une méta-commande psql : refusé"; exit 1; fi
  [ "$c" = "validation" ] && besoin_validation=true
  a_faire+=("$nom:$c")
done

echo "Migrations déjà appliquées : ${#appliquees[@]}"
echo "Migrations à appliquer : ${#a_faire[@]}"
for x in "${a_faire[@]:-}"; do [ -n "$x" ] && echo "  - ${x%%:*} (${x##*:})"; done

if [ "$mode" = "analyser" ]; then
  sortie "a_appliquer=$([ ${#a_faire[@]} -gt 0 ] && echo true || echo false)"
  sortie "besoin_validation=$besoin_validation"
  exit 0
fi

if $besoin_validation && [ "$avec_validation" != "--avec-validation" ]; then
  echo "::error::Une migration demande l'approbation de Coco : relancer via l'environnement validation-coco"
  exit 1
fi

for x in "${a_faire[@]:-}"; do
  [ -n "$x" ] || continue
  nom="${x%%:*}"; classe="${x##*:}"; f="migrations/$nom"
  empreinte=$(sha256sum "$f" | cut -c1-16)
  tmp=$(mktemp)
  {
    if [ "$classe" = "validation" ]; then
      # Sauvegarde des tables listées en en-tête, dans le schéma non exposé planning_sauvegardes.
      for t in $(grep -m1 -E '^-- sauvegarde:' "$f" | sed 's/^-- sauvegarde://' | tr ',' ' '); do
        case "$t" in *[!a-z0-9_.]*) echo "::error::Nom de table invalide dans sauvegarde : $t" >&2; exit 1;; esac
        cible="${t//./__}_$(date -u +%Y%m%d%H%M%S)"
        echo "create schema if not exists planning_sauvegardes;"
        echo "create table planning_sauvegardes.$cible as table $t;"
        echo "revoke all on planning_sauvegardes.$cible from public;"
      done
    else
      echo "set local role planning_proprietaire;"
    fi
    echo "\\i $f"
    echo "insert into planning._migrations (nom, classe, empreinte) values ('$nom', '$classe', '$empreinte');"
  } > "$tmp"
  echo "Application de $nom ($classe)…"
  if ! "${PSQL[@]}" -1 -f "$tmp" 2> "$tmp.err"; then
    # Message d'erreur sans les lignes DETAIL (qui peuvent contenir des valeurs).
    msg=$(grep -vE '^(DETAIL|psql:.*DETAIL)' "$tmp.err" | sed -E 's#postgres(ql)?://[^ ]*#[URL masquée]#g' | tr '\n' ' ' | cut -c1-900)
    echo "::error title=$nom::$msg"
    rm -f "$tmp" "$tmp.err"; exit 3
  fi
  grep -vE '^(DETAIL|psql:.*DETAIL)' "$tmp.err" >&2 || true
  rm -f "$tmp" "$tmp.err"
  echo "  ok"
done
