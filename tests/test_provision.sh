# provision-laravel.sh : dossiers, base MySQL + utilisateur (uapi), .env de production
SCRIPT="$REPO/scripts/provision-laravel.sh"

setup() {
  mkstub uapi 'echo "uapi $*" >> "$UAPI_LOG"
    case "$*" in
      *get_restrictions*)     echo "{\"result\":{\"data\":{\"prefix\":\"sisadmin_\",\"max_username_length\":16},\"status\":1}}";;
      *create_database*)      if [ "${DB_DENY:-}" = 1 ]; then echo "{\"result\":{\"errors\":[\"quota atteint\"],\"status\":0}}";
                              elif [ "${DB_EXISTS:-}" = 1 ]; then echo "{\"result\":{\"errors\":[\"The database already exists.\"],\"status\":0}}";
                              else echo "{\"result\":{\"status\":1}}"; fi;;
      *create_user*)          if [ "${USER_EXISTS:-}" = 1 ]; then echo "{\"result\":{\"errors\":[\"user exists\"],\"status\":0}}"; else echo "{\"result\":{\"status\":1}}"; fi;;
      *set_privileges_on_database*) echo "{\"result\":{\"status\":1}}";;
    esac'
  export UAPI_LOG="$T/uapi.log" DEPLOY_PATH="$T/site"; : > "$UAPI_LOG"
  printf 'APP_NAME=SIS\nAPP_ENV=local\nAPP_KEY=\nAPP_DEBUG=true\nAPP_URL=http://localhost\nDB_CONNECTION=sqlite\nDB_HOST=127.0.0.1\nDB_PORT=3306\nDB_DATABASE=sis\nDB_USERNAME=root\nDB_PASSWORD=\nLOG_LEVEL=debug\n' > "$T/example"
  export ENV_EXAMPLE_B64="$(base64 < "$T/example" | tr -d '\n')"
}
env_val() { grep "^$1=" "$DEPLOY_PATH/.env" | head -n 1 | cut -d= -f2-; }

test_cree_base_utilisateur_et_env_de_production() {
  setup; APP_URL=https://api.ex.com DB_NAME=sis run bash "$SCRIPT"
  assert_eq "$RC" 0
  assert_eq "$(env_val APP_ENV)" production; assert_eq "$(env_val APP_DEBUG)" false; assert_eq "$(env_val APP_URL)" https://api.ex.com
  assert_eq "$(env_val APP_NAME)" SIS                       # valeurs de l'exemple conservées
  assert_eq "$(env_val LOG_LEVEL)" debug
  case "$(env_val APP_KEY)" in base64:?*) ;; *) fail "APP_KEY non générée : $(env_val APP_KEY)";; esac
  assert_eq "$(env_val DB_CONNECTION)" mysql; assert_eq "$(env_val DB_HOST)" localhost
  assert_eq "$(env_val DB_DATABASE)" sisadmin_sis; assert_eq "$(env_val DB_USERNAME)" sisadmin_sis
  pw="$(env_val DB_PASSWORD)"; [ "${#pw}" -eq 24 ] || fail "mot de passe de 24 caractères attendu, obtenu ${#pw}"
  assert_file_contains "$UAPI_LOG" "create_database name=sisadmin_sis"
  assert_file_contains "$UAPI_LOG" "set_privileges_on_database user=sisadmin_sis database=sisadmin_sis"
}
test_le_mot_de_passe_n_est_jamais_affiche_et_l_env_est_en_600() {
  setup; DB_NAME=sis run bash "$SCRIPT"
  pw="$(env_val DB_PASSWORD)"; [ -n "$pw" ] || fail "pas de mot de passe généré"
  assert_not_contains "$OUT" "$pw"
  assert_eq "$(ls -l "$DEPLOY_PATH/.env" | cut -c1-10)" "-rw-------"
}
test_ne_touche_a_rien_si_env_existe() {
  setup; mkdir -p "$DEPLOY_PATH"; echo "APP_KEY=base64:precieux" > "$DEPLOY_PATH/.env"
  DB_NAME=sis run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "inchangé"; assert_eq "$(cat "$DEPLOY_PATH/.env")" "APP_KEY=base64:precieux"
  assert_eq "$(grep -c create_ "$UAPI_LOG")" 0
}
test_prefixe_cpanel_non_double_et_utilisateur_tronque() {
  setup; DB_NAME=sisadmin_application_tres_longue run bash "$SCRIPT"
  assert_eq "$(env_val DB_DATABASE)" sisadmin_application_tres_longue
  assert_eq "$(env_val DB_USERNAME)" sisadmin_applica             # 16 caractères max
}
test_base_existante_reutilisee_avec_avertissement() {
  setup; DB_EXISTS=1 DB_NAME=sis run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "existe déjà : réutilisée"; assert_eq "$(env_val DB_DATABASE)" sisadmin_sis
}
test_utilisateur_existant_ne_fabrique_pas_de_faux_mot_de_passe() {
  setup; USER_EXISTS=1 DB_NAME=sis run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "DB_PASSWORD à renseigner"; assert_eq "$(env_val DB_PASSWORD)" ""
}
test_refus_de_creation_echoue_sans_ecrire_d_env() {
  setup; DB_DENY=1 DB_NAME=sis run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "quota atteint"; [ ! -f "$DEPLOY_PATH/.env" ] || fail ".env créé malgré l'échec"
}
test_sans_uapi_cree_quand_meme_l_env_avec_avertissement() {
  setup; rm "$T/bin/uapi"; DB_NAME=sis run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "uapi indisponible"; assert_eq "$(env_val APP_DEBUG)" false
}
test_sans_base_demandee_seul_l_env_est_cree() {
  setup; run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_eq "$(grep -c create_ "$UAPI_LOG")" 0; assert_eq "$(env_val DB_CONNECTION)" sqlite
}
