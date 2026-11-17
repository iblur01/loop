#!/usr/bin/env bash
# Loop — télécharge des jours de données décodées réelles depuis le serveur
# (GET /v1/export/decoded) vers les fixtures de test, pour faire tourner le
# moteur Swift sur du vrai volume depuis l'ordinateur (RealVolumeTests).
#
# Lit la config depuis Loop/Config/Secrets.xcconfig (LOOP_BASE_URL / LOOP_API_KEY /
# LOOP_DEVICE_ID) sauf si fournie en variables d'env.
#
# Usage:
#   scripts/fetch_fixtures.sh [NB_JOURS] [DATE_FIN_YYYY-MM-DD]
# Défauts: 10 jours se terminant aujourd'hui (UTC).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/Loop/Config/Secrets.xcconfig"
OUT="$ROOT/Packages/LoopStrapEngine/Tests/LoopStrapEngineTests/Resources/realdata"

# Parse Secrets.xcconfig (gère le truc https:/$()/).
cfg() { grep -E "^$1 *=" "$SECRETS" 2>/dev/null | head -1 | sed -E "s/^$1 *= *//; s#/\\\$\\(\\)/#/#g; s/[[:space:]]*$//"; }
BASE_URL="${LOOP_BASE_URL:-$(cfg LOOP_BASE_URL)}"
API_KEY="${LOOP_API_KEY:-$(cfg LOOP_API_KEY)}"
DEVICE="${LOOP_DEVICE_ID:-$(cfg LOOP_DEVICE_ID)}"

[ -n "$BASE_URL" ] && [ -n "$API_KEY" ] && [ -n "$DEVICE" ] || {
  echo "config manquante (BASE_URL/API_KEY/DEVICE) — vérifier $SECRETS" >&2; exit 1; }

DAYS="${1:-10}"
END="${2:-$(date -u +%F)}"
mkdir -p "$OUT"
echo "serveur=$BASE_URL device=$DEVICE jours=$DAYS fin=$END"
echo "sortie=$OUT"

ok=0
for i in $(seq 0 $((DAYS - 1))); do
  # macOS date arithmetic
  d=$(date -u -j -v-"${i}"d -f "%F" "$END" +%F 2>/dev/null || date -u -d "$END -$i day" +%F)
  url="$BASE_URL/v1/export/decoded?device=$DEVICE&date=$d"
  code=$(curl -s -o "$OUT/$d.json" -w "%{http_code}" -H "Authorization: Bearer $API_KEY" "$url")
  sz=$(wc -c < "$OUT/$d.json" | tr -d ' ')
  if [ "$code" = "200" ] && [ "$sz" -gt 200 ]; then
    echo "  $d  OK   ${sz} o"
    ok=$((ok + 1))
  else
    echo "  $d  vide/erreur (code=$code, ${sz} o) — supprimé"
    rm -f "$OUT/$d.json"
  fi
done
echo "terminé: $ok jour(s) avec données dans $OUT"
