#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — notify.sh
#
# Exécuté SUR LE RUNNER. Envoie un message d'échec vers les canaux configurés :
#   - NOTIFY_WEBHOOK_URL : webhook entrant Slack / Discord / compatible
#     (corps JSON portant à la fois "text" et "content")
#   - TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID : bot Telegram
# Aucun canal configuré : ne fait rien (succès). Un échec d'envoi n'échoue jamais
# le job (avertissement) — on ne masque pas l'incident d'origine. Les URL/jetons ne
# sont jamais affichés.
#
# Env : NOTIFY_TITLE  NOTIFY_BODY  [TELEGRAM_API_BASE (tests)]
# =============================================================================
set -uo pipefail

TITLE="${NOTIFY_TITLE:-Échec CI/CD}"
BODY="${NOTIFY_BODY:-}"
TEXT="${TITLE}"$'\n'"${BODY}"
SENT=0
echo "message : ${TITLE}"

if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
  PAYLOAD="$(jq -n --arg t "$TEXT" '{text: $t, content: $t}')"
  if curl -fsS -o /dev/null --max-time 15 -H 'Content-Type: application/json' -d "$PAYLOAD" "$NOTIFY_WEBHOOK_URL" 2>/dev/null; then
    echo "notification envoyée (webhook)"; SENT=1
  else
    echo "::warning::échec d'envoi de la notification (webhook)"
  fi
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
  if curl -fsS -o /dev/null --max-time 15 "${BASE}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
       --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${TEXT}" 2>/dev/null; then
    echo "notification envoyée (Telegram)"; SENT=1
  else
    echo "::warning::échec d'envoi de la notification (Telegram)"
  fi
fi

[ "$SENT" -eq 1 ] || echo "aucune notification envoyée (aucun canal configuré ou envoi en échec)"
exit 0
