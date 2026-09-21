# ensure-php-extensions.sh : vérifie / active les extensions PHP du serveur
SCRIPT="$REPO/scripts/ensure-php-extensions.sh"

setup() {
  mkstub php 'case "$1" in
    -m) printf "[PHP Modules]\n"; cat "$MODS"; printf "\n[Zend Modules]\nZend OPcache\n";;
    -r) case "$2" in *"\".\""*) echo 8.4;; *) echo 84;; esac;;
  esac'
  mkstub selectorctl 'echo "selectorctl $*" >> "$SELLOG"
    [ "${SEL_FAIL:-}" = 1 ] && { echo "refusé"; exit 1; }
    for a; do case "$a" in --enable-user-extensions=*) IFS=, read -ra L <<<"${a#*=}"; for e in "${L[@]}"; do echo "$e" >> "$MODS"; done;; esac; done'
  export MODS="$T/mods" SELLOG="$T/sel.log" PHP_BIN="$T/bin/php"; : > "$SELLOG"
}

test_tout_present_ne_touche_a_rien() {
  setup; printf 'json\nmbstring\nPDO_mysql\n' > "$MODS"
  REQUIRED_EXTS="json mbstring pdo_mysql" run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "extensions PHP OK (3)"; assert_eq "$(cat "$SELLOG")" ""
}
test_active_l_extension_manquante_via_selectorctl() {
  setup; printf 'json\n' > "$MODS"
  REQUIRED_EXTS="json zip" run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "extensions PHP OK (2)"
  assert_file_contains "$SELLOG" "--enable-user-extensions=zip --version=8.4"
}
test_echoue_si_selectorctl_refuse() {
  setup; printf 'json\n' > "$MODS"
  SEL_FAIL=1 REQUIRED_EXTS="json zip gd" run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "extensions PHP manquantes pour"; assert_contains "$OUT" "zip gd"
}
test_echoue_sans_selectorctl_avec_message_clair() {
  setup; rm "$T/bin/selectorctl"; printf 'json\n' > "$MODS"
  REQUIRED_EXTS="json zip" run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "selectorctl indisponible"
}
test_mode_diagnostic_n_active_rien() {
  setup; printf 'json\n' > "$MODS"
  CHECK_ONLY=1 REQUIRED_EXTS="json zip" run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "diagnostic : rien n'est activé"; assert_eq "$(cat "$SELLOG")" ""
}
test_aucune_extension_requise() {
  setup; REQUIRED_EXTS="" run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "aucune extension requise"
}
