# detect-app.sh : convention plutôt que configuration
SCRIPT="$REPO/scripts/detect-app.sh"

laravel_app() { mkdir -p "$1"; cat > "$1/composer.json" <<'J'
{"require":{"php":"^8.3","laravel/framework":"^13.0","ext-intl":"*"}}
J
cat > "$1/composer.lock" <<'J'
{"packages":[{"name":"a/b","require":{"php":">=8.1","ext-zip":"*","ext-mbstring":"*","ext-json":"*"}}]}
J
}

test_detecte_laravel_php_min_et_extensions() {
  laravel_app app; run bash "$SCRIPT" app
  assert_eq "$RC" 0
  assert_contains "$OUT" "stack=laravel"
  assert_contains "$OUT" "min_php=8.3"
  assert_contains "$OUT" "required_exts=intl json mbstring zip"
}
test_ajoute_les_extensions_supplementaires() {
  laravel_app app; EXTRA_EXTS="gd, Exif" run bash "$SCRIPT" app
  assert_contains "$OUT" "required_exts=exif gd intl json mbstring zip"
}
test_detecte_next_et_node_par_defaut() {
  mkdir app; echo '{"dependencies":{"next":"15.0.0"}}' > app/package.json
  run bash "$SCRIPT" app
  assert_contains "$OUT" "stack=nextjs-passenger"; assert_contains "$OUT" "node_version=22"
}
test_node_depuis_nvmrc_puis_engines() {
  mkdir a b; echo '{"dependencies":{"next":"15"}}' > a/package.json; echo 'v24.1.0' > a/.nvmrc
  echo '{"dependencies":{"next":"15"},"engines":{"node":">=20 <23"}}' > b/package.json
  run bash "$SCRIPT" a; assert_contains "$OUT" "node_version=24"
  run bash "$SCRIPT" b; assert_contains "$OUT" "node_version=20"
}
test_input_explicite_prime_sur_la_detection() {
  laravel_app app; STACK_INPUT=nextjs-passenger NODE_INPUT=18 run bash "$SCRIPT" app
  assert_contains "$OUT" "stack=nextjs-passenger"; assert_contains "$OUT" "node_version=18"
}
test_stack_indetectable_echoue_avec_message() {
  mkdir app; echo '{}' > app/package.json; run bash "$SCRIPT" app
  assert_eq "$RC" 1; assert_contains "$OUT" "stack indétectable"
}
test_stack_invalide_echoue() {
  mkdir app; STACK_INPUT=rails run bash "$SCRIPT" app
  assert_eq "$RC" 1; assert_contains "$OUT" "stack invalide"
}
