#!/usr/bin/env bash
# Rejoue toutes les migrations sur une base locale neuve, puis vérifie les garde-fous.
# Usage : outils/tester.sh   (PGHOST/PGPORT/PGUSER du PostgreSQL local)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGHOST:=/tmp/pgtest}" "${PGPORT:=54329}" "${PGUSER:=postgres}"
export PGHOST PGPORT PGUSER
base=planning_test
url="postgresql:///$base?host=$PGHOST&port=$PGPORT&user=$PGUSER"

reinit() { dropdb --if-exists "$base"; createdb "$base"; psql "$url" -X -q -v ON_ERROR_STOP=1 -f outils/banc-test/supabase-minimal.sql; }

echo "1. Base neuve + réplique minimale"; reinit
echo "2. Analyse"; outils/appliquer.sh analyser "$url"
echo "3. Refus sans validation quand une migration l'exige"
if outils/appliquer.sh appliquer "$url" >/dev/null 2>&1; then echo "ÉCHEC : appliqué sans validation"; exit 1; fi
echo "   ok"
echo "4. Application avec validation"; outils/appliquer.sh appliquer "$url" --avec-validation
echo "5. Rejeu : plus rien à faire"
n=$(outils/appliquer.sh analyser "$url" | grep -c '^  - ' || true); [ "$n" = 0 ] || { echo "ÉCHEC : rejeu non idempotent"; exit 1; }
echo "   ok"
echo "6. Garde-fous"; psql "$url" -X -q -At -v ON_ERROR_STOP=1 -f outils/banc-test/verifications.sql

echo "7. Une migration « planning » qui tente de modifier Suivi des temps échoue"
tmp=$(mktemp -d); cp -r migrations outils "$tmp/"
printf -- '-- portee: planning\nupdate public.collaborateurs set nom = nom;\n' > "$tmp/migrations/9999_malveillante.sql"
if "$tmp/outils/appliquer.sh" appliquer "$url" >/dev/null 2>&1; then echo "ÉCHEC : la migration a pu modifier public"; exit 1; fi
echo "   ok (refusée par les droits)"
echo "8. Une migration « planning » contenant drop passe en validation"
printf -- '-- portee: planning\ndrop table if exists planning.inexistante;\n' > "$tmp/migrations/9999_malveillante.sql"
"$tmp/outils/appliquer.sh" analyser "$url" | grep -q '9999_malveillante.sql (validation)' || { echo "ÉCHEC : drop non détecté"; exit 1; }
echo "   ok"
echo "9. Une méta-commande psql est refusée"
printf -- '-- portee: validation\n\\! env\n' > "$tmp/migrations/9999_malveillante.sql"
if "$tmp/outils/appliquer.sh" analyser "$url" >/dev/null 2>&1; then echo "ÉCHEC : méta-commande acceptée"; exit 1; fi
echo "   ok"
rm -rf "$tmp"
echo "Tous les tests sont passés."
