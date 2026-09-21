# preflight.sh : contrôles serveur avant transfert
SCRIPT="$REPO/scripts/preflight.sh"

setup() {
  mkstub rsync 'echo "rsync  version 3.2.7  protocol version 31"'
  mkstub php 'echo "PHP 8.4.25 (cli)"'
  mkdir -p "$T/site"; export STACK=laravel DEPLOY_PATH="$T/site" PHP_BIN="$T/bin/php" COMPOSER_ON_SERVER=false
}

test_laravel_ok() {
  setup; run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "rsync (serveur) : rsync  version 3.2.7"; assert_contains "$OUT" "php_bin : PHP 8.4.25"
  assert_contains "$OUT" "espace disque libre"; assert_not_contains "$OUT" "COMPOSER_FALLBACK"
}
test_echoue_sans_rsync_avec_message_clair() {
  setup; rm "$T/bin/rsync"; PATH="$T/bin:/usr/bin:/bin" run bash "$SCRIPT"
  command -v rsync >/dev/null 2>&1 && [ -x /usr/bin/rsync ] && return 0   # rsync système présent : test non concluant
  assert_eq "$RC" 1; assert_contains "$OUT" "rsync introuvable"
}
test_echoue_si_php_introuvable_et_liste_les_binaires() {
  setup; PHP_BIN="/absent/php" run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "php_bin introuvable : /absent/php"; assert_contains "$OUT" "binaires trouvés sur le serveur"
}
test_signale_composer_absent_en_mode_serveur() {
  setup; COMPOSER_ON_SERVER=true COMPOSER_BIN=/absent/composer run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "COMPOSER_FALLBACK=1"
}
test_ne_verifie_pas_composer_en_mode_artefact() {
  setup; COMPOSER_ON_SERVER=false COMPOSER_BIN=/absent/composer run bash "$SCRIPT"
  assert_not_contains "$OUT" "COMPOSER_FALLBACK"
}
test_next_ne_demande_pas_de_php() {
  setup; STACK=nextjs-passenger PHP_BIN="" run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_not_contains "$OUT" "php_bin"
}
