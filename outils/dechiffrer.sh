#!/usr/bin/env bash
# Usage : outils/dechiffrer.sh <id_du_run>  (dans l'espace de travail de Claude uniquement)
set -euo pipefail
run="$1"; cle="${CLE_LECTURE:-/home/claude/.cles/lecture.key}"
job=$(gh api "repos/chantsdelaterre/planning/actions/runs/$run/jobs" --jq '.jobs[0].id')
bloc=$(gh api "repos/chantsdelaterre/planning/check-runs/$job/annotations" --paginate \
  --jq '[.[] | select(.title|startswith("chiffre-")) | {n:(.title|ltrimstr("chiffre-")|tonumber), m:.message}] | sort_by(.n) | map(.m) | join("")')
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s' "${bloc%%.*}" | base64 -d > "$tmp/cle.enc"
printf '%s' "${bloc#*.}" | base64 -d > "$tmp/sortie.enc"
openssl pkeyutl -decrypt -inkey "$cle" -pkeyopt rsa_padding_mode:oaep -in "$tmp/cle.enc" -out "$tmp/cle.txt"
openssl enc -d -aes-256-cbc -pbkdf2 -in "$tmp/sortie.enc" -pass file:"$tmp/cle.txt" | gunzip
