# deploy-laravel.sh : mode artefact CI (défaut recommandé) et mode composer serveur
setup_app() {
  mkdir -p "$T/kit" "$T/app"; cp -R "$REPO/scripts/." "$T/kit/"
  echo "APP_KEY=base64:x" > "$T/app/.env"
  mkstub php 'echo "PHP $*" >> "$CALLS"'
  export CALLS="$T/calls" DEPLOY_PATH="$T/app" PHP_BIN="$T/bin/php" HEALTH_CHECK_URL=""; : > "$CALLS"
}

test_artefact_ci_rejoue_package_discover_sans_composer() {
  setup_app; mkdir -p "$T/app/vendor"; touch "$T/app/vendor/autoload.php"
  COMPOSER_ON_SERVER=false run bash "$T/kit/deploy-laravel.sh"
  assert_eq "$RC" 0
  assert_file_contains "$CALLS" "artisan package:discover"
  assert_file_contains "$CALLS" "artisan migrate --force"
  assert_not_contains "$(cat "$CALLS")" "install --no-dev"
}
test_artefact_ci_echoue_si_vendor_absent() {
  setup_app
  COMPOSER_ON_SERVER=false run bash "$T/kit/deploy-laravel.sh"
  assert_eq "$RC" 1; assert_contains "$OUT" "vendor/autoload.php absent"
}
test_composer_serveur_utilise_composer_s_il_existe() {
  setup_app; mkstub composer 'echo "COMPOSER $*" >> "$CALLS"'
  COMPOSER_ON_SERVER=true COMPOSER_BIN="$T/bin/composer" run bash "$T/kit/deploy-laravel.sh"
  assert_eq "$RC" 0; assert_file_contains "$CALLS" "COMPOSER install --no-dev"
}
test_composer_serveur_repli_sur_le_phar_du_workflow() {
  setup_app; touch "$T/kit/composer.phar"
  COMPOSER_ON_SERVER=true COMPOSER_BIN=/absent/composer run bash "$T/kit/deploy-laravel.sh"
  assert_eq "$RC" 0; assert_file_contains "$CALLS" "PHP $T/kit/composer.phar install --no-dev"
}
test_composer_serveur_echoue_sans_composer_ni_phar() {
  setup_app
  COMPOSER_ON_SERVER=true COMPOSER_BIN=/absent/composer run bash "$T/kit/deploy-laravel.sh"
  assert_eq "$RC" 1; assert_contains "$OUT" "composer introuvable"
}
test_defaut_sans_variable_reste_compatible_composer_serveur() {
  setup_app; touch "$T/kit/composer.phar"
  unset COMPOSER_ON_SERVER; COMPOSER_BIN=/absent/composer run bash "$T/kit/deploy-laravel.sh"
  assert_file_contains "$CALLS" "composer.phar install --no-dev"
}
test_refuse_de_deployer_sans_env() {
  setup_app; rm "$T/app/.env"; COMPOSER_ON_SERVER=false run bash "$T/kit/deploy-laravel.sh"
  assert_eq "$RC" 1; assert_contains "$OUT" ".env manquant"
}
