# provision-nextjs.sh : déclaration de l'app Node (cloudlinux-selector / uapi PassengerApps), idempotente
SCRIPT="$REPO/scripts/provision-nextjs.sh"

# Sortie réelle de `cloudlinux-selector get --json --interpreter=nodejs` (serveur CloudLinux, abrégée)
cl_setup() {
  export HOME="$T/home" CL_LOG="$T/cl.log"; mkdir -p "$HOME"; : > "$CL_LOG"
  mkstub cloudlinux-selector 'echo "cl $*" >> "$CL_LOG"
    case "$1" in
      get) printf "%s" "{\"available_versions\": {\"20.20.2\": {\"base_dir\": \"/opt/alt/alt-nodejs20\", \"status\": \"enabled\", \"users\": {\"u\": {\"applications\": {\"app-existante.com\": {\"app_mode\": \"production\", \"app_status\": \"started\"}}}}}, \"22.23.2\": {\"base_dir\": \"/opt/alt/alt-nodejs22\", \"status\": \"enabled\"}, \"24.20.0\": {\"base_dir\": \"/opt/alt/alt-nodejs24\", \"status\": \"disabled\"}}}";;
      create) [ "${CL_DENY:-}" = 1 ] && { echo "{\"result\": \"Domain not found\"}"; exit 1; }; echo "{\"result\": \"success\"}";;
    esac'
}

test_cloudlinux_declare_l_app_avec_la_bonne_version() {
  cl_setup; DEPLOY_PATH="$HOME/site.com" DOMAIN=site.com NODE_MAJOR=22 run bash "$SCRIPT"
  assert_eq "$RC" 0; [ -d "$HOME/site.com" ] || fail "dossier non créé"
  assert_file_contains "$CL_LOG" "create --json --interpreter=nodejs --version=22.23.2 --app-root=site.com --domain=site.com --app-uri=/ --app-mode=production --startup-file=server.js"
  assert_contains "$OUT" "app Node déclarée : site.com/ → site.com (Node 22.23.2"
}
test_cloudlinux_idempotent_si_l_app_existe() {
  cl_setup; DEPLOY_PATH="$HOME/app-existante.com" DOMAIN=app-existante.com run bash "$SCRIPT"
  assert_eq "$RC" 0; assert_contains "$OUT" "déjà déclarée"; assert_not_contains "$(cat "$CL_LOG")" "create"
}
test_cloudlinux_version_absente_ou_desactivee_echoue_clairement() {
  cl_setup; DEPLOY_PATH="$HOME/s" DOMAIN=s.com NODE_MAJOR=24 run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "Node 24 indisponible"; assert_contains "$OUT" "20 22 24"
}
test_cloudlinux_refus_remonte_l_erreur() {
  cl_setup; CL_DENY=1 DEPLOY_PATH="$HOME/s" DOMAIN=s.com run bash "$SCRIPT"
  assert_eq "$RC" 1; assert_contains "$OUT" "Domain not found"
}
test_passenger_uapi_sans_cloudlinux() {
  export HOME="$T/home" UAPI_LOG="$T/uapi.log"; mkdir -p "$HOME"; : > "$UAPI_LOG"
  mkstub uapi 'echo "uapi $*" >> "$UAPI_LOG"; echo "{\"result\":{\"data\":{},\"status\":1}}"'
  DEPLOY_PATH="$HOME/apps/front" DOMAIN=ex.com run bash "$SCRIPT"
  assert_eq "$RC" 0
  assert_file_contains "$UAPI_LOG" "register_application name=apps-front path=$HOME/apps/front domain=ex.com base_uri=/ deployment_mode=production enabled=1"
}
test_sans_outil_ni_domaine_donne_les_instructions_sans_echouer() {
  export HOME="$T/home"; mkdir -p "$HOME"
  DEPLOY_PATH="$HOME/x" run bash "$SCRIPT"; assert_eq "$RC" 0; assert_contains "$OUT" "Setup Node.js App"
  DEPLOY_PATH="$HOME/x" DOMAIN=x.com run bash "$SCRIPT"; assert_eq "$RC" 0; assert_contains "$OUT" "ni cloudlinux-selector ni uapi"
}
