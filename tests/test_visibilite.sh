# check-cert.sh (jours avant expiration) et notify.sh (webhook / Telegram)
need_openssl() { command -v openssl >/dev/null 2>&1 || { echo SKIP; return 99; }; }

test_check_cert_retourne_les_jours_restants() {
  need_openssl || return $?; need_php || return $?
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 6 -subj /CN=localhost >/dev/null 2>&1
  PORT=$(( 20000 + RANDOM % 20000 ))
  openssl s_server -accept "$PORT" -cert "$T/c.pem" -key "$T/k.pem" -www >/dev/null 2>&1 & SRV=$!
  trap 'kill $SRV 2>/dev/null' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do (echo | openssl s_client -connect "127.0.0.1:$PORT" >/dev/null 2>&1) && break; sleep 0.3; done
  run bash "$REPO/scripts/check-cert.sh" 127.0.0.1 "$PORT"
  assert_eq "$RC" 0
  case "$OUT" in 4|5|6) ;; *) fail "6 jours de validité attendus (±1), obtenu « $OUT »" ;; esac
}
test_check_cert_echoue_proprement_si_injoignable() {
  need_openssl || return $?
  run bash "$REPO/scripts/check-cert.sh" 127.0.0.1 1
  assert_eq "$RC" 1; assert_eq "$OUT" ""
}

# serveur PHP qui enregistre chaque requête reçue dans $T/hits
start_sink() {
  need_php || return $?
  cat > "$T/sink.php" <<'P'
<?php
file_put_contents(__DIR__ . '/hits', $_SERVER['REQUEST_URI'] . ' ' . file_get_contents('php://input') . "\n", FILE_APPEND);
echo '{"ok":true}';
P
  PORT=$(( 20000 + RANDOM % 20000 )); SINK="http://127.0.0.1:$PORT"
  php -S "127.0.0.1:$PORT" "$T/sink.php" >/dev/null 2>&1 & SRV=$!
  trap 'kill $SRV 2>/dev/null' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$SINK/" && break; sleep 0.3; done
  rm -f "$T/hits"
}
test_notify_webhook_envoie_text_et_content() {
  start_sink || return $?
  NOTIFY_WEBHOOK_URL="$SINK/hook" NOTIFY_TITLE="❌ CI/CD en échec" NOTIFY_BODY="repo: acme/site" run bash "$REPO/scripts/notify.sh"
  assert_eq "$RC" 0; assert_contains "$OUT" "notification envoyée (webhook)"
  assert_not_contains "$OUT" "$SINK"                                   # l'URL n'est jamais affichée
  body="$(cat "$T/hits")"; assert_contains "$body" "/hook"
  assert_eq "$(sed 's#^[^ ]* ##' "$T/hits" | jq -r .text)" "$(sed 's#^[^ ]* ##' "$T/hits" | jq -r .content)"
  assert_contains "$(sed 's#^[^ ]* ##' "$T/hits" | jq -r .text)" "acme/site"
}
test_notify_telegram_utilise_le_bot_sans_afficher_le_jeton() {
  start_sink || return $?
  TELEGRAM_API_BASE="$SINK" TELEGRAM_BOT_TOKEN="123:SECRETTOKEN" TELEGRAM_CHAT_ID="42" NOTIFY_TITLE=T NOTIFY_BODY=B run bash "$REPO/scripts/notify.sh"
  assert_contains "$OUT" "notification envoyée (Telegram)"; assert_not_contains "$OUT" "SECRETTOKEN"
  assert_contains "$(cat "$T/hits")" "/bot123:SECRETTOKEN/sendMessage"; assert_contains "$(cat "$T/hits")" "chat_id=42"
}
test_notify_sans_canal_ne_fait_rien_et_reussit() {
  run bash "$REPO/scripts/notify.sh"; assert_eq "$RC" 0; assert_contains "$OUT" "aucun canal configuré"
}
test_notify_n_echoue_jamais_meme_si_l_envoi_echoue() {
  NOTIFY_WEBHOOK_URL="http://127.0.0.1:1/x" run bash "$REPO/scripts/notify.sh"
  assert_eq "$RC" 0; assert_contains "$OUT" "::warning::échec d'envoi"
}
