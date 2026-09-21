# ensure-web-php.sh : version PHP du domaine + bloc handler du .htaccess
SCRIPT="$REPO/scripts/ensure-web-php.sh"

setup() {
  need_php || return $?
  WANT="ea-php$(php -r 'echo PHP_MAJOR_VERSION . PHP_MINOR_VERSION;')"
  mkdir -p "$T/docroot"; echo "$WANT" > "$T/state"
  mkstub uapi 'case "$*" in
    *php_get_vhost_versions*) printf "{\"result\":{\"data\":[{\"vhost\":\"v1.ex.com\",\"version\":\"%s\",\"documentroot\":\"%s\"}]}}\n" "$(cat "$STATE")" "$DOCROOT";;
    *php_set_vhost_versions*) echo "status: 1"; [ "${UAPI_FAIL:-}" = 1 ] || for a; do case "$a" in version=*) echo "${a#version=}" > "$STATE";; esac; done;;
  esac'
  export STATE="$T/state" DOCROOT="$T/docroot" PHP_BIN="$(command -v php)" DOMAIN=v1.ex.com
}

test_installe_le_handler_dans_un_htaccess_du_repo() {
  setup || return $?
  printf '# BEGIN Laravel\nRewriteEngine On\n# END Laravel\n' > "$DOCROOT/.htaccess"
  run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "(ré)installé"
  assert_file_contains "$DOCROOT/.htaccess" "AddHandler application/x-httpd-$WANT .php .php8 .phtml"
  assert_file_contains "$DOCROOT/.htaccess" "RewriteEngine On"
}
test_idempotent_ne_reecrit_pas_un_htaccess_deja_bon() {
  setup || return $?
  printf 'RewriteEngine On\n' > "$DOCROOT/.htaccess"; bash "$SCRIPT" >/dev/null; cp "$DOCROOT/.htaccess" "$T/before"
  run bash "$SCRIPT"
  assert_contains "$OUT" "contient déjà le handler"; cmp -s "$T/before" "$DOCROOT/.htaccess" || fail ".htaccess modifié"
}
test_remplace_un_ancien_handler_sans_perdre_le_reste() {
  setup || return $?
  printf '# php -- BEGIN cPanel-generated handler, do not edit\nAddHandler application/x-httpd-ea-php81 .php\n# php -- END cPanel-generated handler, do not edit\nRewriteEngine On\n' > "$DOCROOT/.htaccess"
  run bash "$SCRIPT"
  assert_eq "$(grep -c 'ea-php81' "$DOCROOT/.htaccess")" 0
  assert_file_contains "$DOCROOT/.htaccess" "RewriteEngine On"
}
test_cree_le_htaccess_s_il_n_existe_pas() {
  setup || return $?
  run bash "$SCRIPT"; [ -f "$DOCROOT/.htaccess" ] || fail ".htaccess non créé"
}
test_realigne_la_version_cpanel() {
  setup || return $?
  echo ea-php74 > "$STATE"; run bash "$SCRIPT"
  assert_contains "$OUT" "alignement via cPanel MultiPHP"; assert_eq "$(cat "$STATE")" "$WANT"
}
test_avertit_sans_bloquer_si_uapi_refuse() {
  setup || return $?
  echo ea-php74 > "$STATE"; UAPI_FAIL=1 run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "::warning::PHP web"
}
test_mode_diagnostic_ne_modifie_rien() {
  setup || return $?
  printf 'RewriteEngine On\n' > "$DOCROOT/.htaccess"; cp "$DOCROOT/.htaccess" "$T/before"
  CHECK_ONLY=1 run bash "$SCRIPT"
  assert_contains "$OUT" "ABSENT"; cmp -s "$T/before" "$DOCROOT/.htaccess" || fail ".htaccess modifié en mode diagnostic"
}
test_ignore_hors_cpanel_et_sans_domaine() {
  setup || return $?
  rm "$T/bin/uapi"; run bash "$SCRIPT"; assert_contains "$OUT" "uapi indisponible"
  mkstub uapi 'true'; DOMAIN="" run bash "$SCRIPT"; assert_contains "$OUT" "domaine inconnu"
}
