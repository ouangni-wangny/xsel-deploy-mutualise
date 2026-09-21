# init.sh : détection des apps, fichiers générés, clé SSH, secrets (gh factice)
SCRIPT="$REPO/scripts/init.sh"

fixture() {
  mkdir -p "$T/p/backend" "$T/p/frontend" "$T/p/docs"; cd "$T/p"
  echo '{"require":{"php":"^8.3","laravel/framework":"^13.0"}}' > backend/composer.json
  echo '{"dependencies":{"next":"15.0.0"}}' > frontend/package.json
  mkstub gh 'echo "gh $*" >> "$GH_LOG"; cat > "$GH_DIR/$(echo "$*" | sed "s/secret set \([A-Z_]*\).*/\1/")" 2>/dev/null; [ "$1 $2" = "repo view" ] && echo "acme/site"; exit 0'
  export GH_LOG="$T/gh.log" GH_DIR="$T/secrets" XSEL_KEY_DIR="$T/keys"; mkdir -p "$GH_DIR"; : > "$GH_LOG"
}

test_detecte_les_apps_et_ecrit_manifeste_et_workflow() {
  fixture; run bash "$SCRIPT" --user monuser
  assert_eq "$RC" 0
  assert_contains "$OUT" "  - backend"; assert_contains "$OUT" "  - frontend"
  assert_file_contains .xsel-deploy.yml "deploy_path: /home/monuser/backend"
  assert_file_contains .xsel-deploy.yml "deploy_path: /home/monuser/frontend"
  assert_file_contains .github/workflows/cicd.yml "pipeline.yml@v1"
  assert_file_contains .github/workflows/cicd.yml "options: [deploy, doctor, provision]"
  # l'API est listée avant le frontend (ordre de déploiement)
  [ "$(grep -n '^  backend:' .xsel-deploy.yml | cut -d: -f1)" -lt "$(grep -n '^  frontend:' .xsel-deploy.yml | cut -d: -f1)" ] || fail "backend doit précéder frontend"
}
test_le_manifeste_genere_est_accepte_par_plan_sh() {
  fixture; bash "$SCRIPT" --user u >/dev/null
  run env REPO_DIR="$T/p" EVENT_NAME=workflow_dispatch REF=refs/heads/main bash "$REPO/scripts/plan.sh"
  assert_eq "$RC" 0; assert_contains "$OUT" "backend, frontend"
}
test_ne_remplace_pas_les_fichiers_existants_sans_force() {
  fixture; echo "version: 1  # perso" > .xsel-deploy.yml
  run bash "$SCRIPT"; assert_contains "$OUT" "existe déjà : conservé"; assert_eq "$(cat .xsel-deploy.yml)" "version: 1  # perso"
  run bash "$SCRIPT" --force; assert_not_contains "$(cat .xsel-deploy.yml)" "perso"
}
test_dry_run_n_ecrit_rien() {
  fixture; run bash "$SCRIPT" --dry-run --generate-key --set-secrets --user u --host h --port 22 --repo a/b
  assert_eq "$RC" 0; assert_contains "$OUT" "[dry-run]"
  [ ! -e .xsel-deploy.yml ] && [ ! -e .github ] && [ ! -e "$T/keys" ] || fail "des fichiers ont été écrits en dry-run"
  assert_eq "$(cat "$GH_LOG")" ""
}
test_genere_une_cle_hors_du_depot_et_pose_les_4_secrets() {
  command -v ssh-keygen >/dev/null || return 99
  fixture; run bash "$SCRIPT" --generate-key --set-secrets --user monuser --host srv.ex.com --port 22 --repo acme/site
  assert_eq "$RC" 0
  ls "$T/keys"/xsel-deploy-* >/dev/null 2>&1 || fail "clé non générée dans XSEL_KEY_DIR"
  [ -z "$(git -C "$T/p" ls-files 2>/dev/null | grep -i deploy_key)" ] || fail "clé dans le dépôt"
  for n in DEPLOY_SSH_HOST DEPLOY_SSH_PORT DEPLOY_SSH_USER DEPLOY_SSH_PRIVATE_KEY; do assert_file_contains "$GH_LOG" "secret set $n --repo acme/site"; done
  assert_eq "$(cat "$GH_DIR/DEPLOY_SSH_HOST")" "srv.ex.com"
  assert_file_contains "$GH_DIR/DEPLOY_SSH_PRIVATE_KEY" "BEGIN OPENSSH PRIVATE KEY"
  assert_contains "$OUT" "ssh-ed25519"                        # clé PUBLIQUE affichée
  assert_not_contains "$OUT" "PRIVATE KEY"                    # jamais la privée
  assert_not_contains "$(cat "$GH_LOG")" "srv.ex.com"         # valeurs des secrets jamais en argument (visibles dans ps)
}
test_set_secrets_exige_les_parametres_et_une_cle() {
  fixture; run bash "$SCRIPT" --set-secrets --user u; assert_eq "$RC" 1; assert_contains "$OUT" "exige --user, --host et --port"
  run bash "$SCRIPT" --set-secrets --user u --host h --port 22; assert_eq "$RC" 1; assert_contains "$OUT" "exige --key-file ou --generate-key"
}
test_echoue_sans_app_detectee() {
  mkdir -p "$T/empty"; cd "$T/empty"; run bash "$SCRIPT"; assert_eq "$RC" 1; assert_contains "$OUT" "aucune app détectée"
}
