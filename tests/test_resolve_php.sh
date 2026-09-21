# resolve-php.sh : choix du binaire PHP côté serveur (racines factices)
SCRIPT="$REPO/scripts/resolve-php.sh"

fake_php() { # fake_php <chemin> <X.Y>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\n[ "$1" = "-r" ] && echo "%s" || echo "PHP %s"\n' "$2" "$2" > "$1"; chmod +x "$1"
}
setup_roots() {
  export ALT_PHP_ROOT="$T/alt" EA_PHP_ROOT="$T/ea"
  fake_php "$T/alt/php82/usr/bin/php" 8.2
  fake_php "$T/alt/php84/usr/bin/php" 8.4
  fake_php "$T/ea/ea-php83/root/usr/bin/php" 8.3
}

test_version_demandee_utilise_alt_php() {
  setup_roots; PHP_VERSION_INPUT=8.4 run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "php_bin=$T/alt/php84/usr/bin/php"; assert_contains "$OUT" "php_version=8.4"
}
test_repli_sur_ea_php_si_pas_de_alt() {
  setup_roots; PHP_VERSION_INPUT=8.3 run bash "$SCRIPT"
  assert_contains "$OUT" "php_bin=$T/ea/ea-php83/root/usr/bin/php"
}
test_sans_indication_prend_la_plus_basse_version_conforme() {
  setup_roots; MIN_PHP=8.3 run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "php_version=8.3"
}
test_suit_le_php_cpanel_du_domaine() {
  need_php || return $?
  setup_roots
  mkstub uapi 'printf "{\"result\":{\"data\":[{\"vhost\":\"v1.ex.com\",\"version\":\"ea-php84\"}]}}\n"'
  MIN_PHP=8.3 DOMAIN=v1.ex.com run bash "$SCRIPT"
  assert_contains "$OUT" "php_version=8.4"; assert_contains "$OUT" "PHP cPanel du domaine"
}
test_ignore_le_php_du_domaine_sous_le_minimum() {
  need_php || return $?
  setup_roots
  mkstub uapi 'printf "{\"result\":{\"data\":[{\"vhost\":\"v1.ex.com\",\"version\":\"ea-php81\"}]}}\n"'
  MIN_PHP=8.3 DOMAIN=v1.ex.com run bash "$SCRIPT"
  assert_contains "$OUT" "php_version=8.3"
}
test_php_bin_explicite_est_respecte() {
  setup_roots; PHP_BIN_INPUT="$T/alt/php82/usr/bin/php" run bash "$SCRIPT"
  assert_contains "$OUT" "php_bin=$T/alt/php82/usr/bin/php"
}
test_echoue_si_version_inferieure_au_minimum() {
  setup_roots; PHP_BIN_INPUT="$T/alt/php82/usr/bin/php" MIN_PHP=8.3 run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "< 8.3 exigé par composer.json"
}
test_echoue_si_version_demandee_absente() {
  setup_roots; PHP_VERSION_INPUT=8.9 run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "PHP 8.9 introuvable"; assert_contains "$OUT" "8.2 8.3 8.4"
}
