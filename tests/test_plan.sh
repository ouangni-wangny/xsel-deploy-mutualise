# plan.sh : que lancer selon l'événement et les fichiers modifiés
SCRIPT="$REPO/scripts/plan.sh"

# Projet de test : backend (Laravel API) + frontend (Next) + manifeste, 2 commits.
mkrepo() {
  git init -q "$T/proj" && cd "$T/proj"
  git config user.email t@t; git config user.name t
  mkdir -p backend frontend
  echo '{"scripts":{"build":"next build"}}' > frontend/package.json
  echo x > backend/a.php; echo x > frontend/a.ts
  cat > .xsel-deploy.yml <<'Y'
version: 1
apps:
  backend:
    deploy_path: /home/u/api
    health_check_url: https://api.ex.com/up
  frontend:
    deploy_path: /home/u/web
    health_check_url: https://ex.com
    build_env:
      NEXT_PUBLIC_API_URL: https://api.ex.com/v1
Y
  git add -A; git commit -q -m one; B1="$(git rev-parse HEAD)"
}
commit_file() { echo "# change" >> "$1"; git add -A; git commit -q -m change; }
plan() { # plan <événement> [VAR=val…]  -> $OUT
  ev="$1"; shift
  run env REPO_DIR="$T/proj" EVENT_NAME="$ev" SHA="$(git -C "$T/proj" rev-parse HEAD)" "$@" bash "$SCRIPT"
}
names() { echo "$OUT" | sed -n "s/^$1=//p" | jq -r 'map(.name) | join(",")'; }

test_push_deploie_seulement_l_app_modifiee() {
  mkrepo; commit_file backend/a.php
  plan push REF=refs/heads/main BEFORE="$B1"
  assert_eq "$RC" 0; assert_eq "$(names ci_apps)" "backend"; assert_eq "$(names deploy_apps)" "backend"
}
test_push_hors_branche_de_deploiement_ne_deploie_pas() {
  mkrepo; commit_file frontend/a.ts
  plan push REF=refs/heads/feature BEFORE="$B1"
  assert_eq "$(names ci_apps)" "frontend"; assert_eq "$(names deploy_apps)" ""; assert_contains "$OUT" "has_deploy=false"
}
test_manifeste_modifie_concerne_toutes_les_apps() {
  mkrepo; commit_file .xsel-deploy.yml
  plan push REF=refs/heads/main BEFORE="$B1"
  assert_eq "$(names deploy_apps)" "backend,frontend"
}
test_workflows_modifies_concernent_toutes_les_apps() {
  mkrepo; mkdir -p .github/workflows; commit_file .github/workflows/cicd.yml
  plan push REF=refs/heads/main BEFORE="$B1"
  assert_eq "$(names ci_apps)" "backend,frontend"
}
test_premiere_poussee_ou_diff_impossible_prend_tout() {
  mkrepo
  plan push REF=refs/heads/main BEFORE=0000000000000000000000000000000000000000
  assert_eq "$(names deploy_apps)" "backend,frontend"
  plan push REF=refs/heads/main BEFORE=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  assert_eq "$(names deploy_apps)" "backend,frontend"
}
test_pull_request_lance_la_ci_sans_deployer() {
  mkrepo; commit_file backend/a.php
  plan pull_request REF=refs/pull/1/merge BASE_SHA="$B1"
  assert_eq "$(names ci_apps)" "backend"; assert_eq "$(names deploy_apps)" ""
}
test_dispatch_prend_tout_et_accepte_un_filtre() {
  mkrepo
  plan workflow_dispatch REF=refs/heads/main
  assert_eq "$(names deploy_apps)" "backend,frontend"
  plan workflow_dispatch REF=refs/heads/main ONLY_APPS="frontend"
  assert_eq "$(names deploy_apps)" "frontend"; assert_eq "$(names ci_apps)" "frontend"
}
test_dispatch_doctor_ne_lance_que_le_diagnostic() {
  mkrepo
  plan workflow_dispatch REF=refs/heads/main ACTION=doctor
  assert_eq "$(names doctor_apps)" "backend,frontend"; assert_eq "$(names deploy_apps)" ""; assert_eq "$(names ci_apps)" ""
}
test_schedule_ne_lance_que_le_monitoring_avec_les_urls_des_apps() {
  mkrepo; plan schedule REF=refs/heads/main
  assert_contains "$OUT" 'monitor_urls=["https://api.ex.com/up","https://ex.com"]'
  assert_contains "$OUT" "has_monitor=true"; assert_contains "$OUT" "has_ci=false"; assert_contains "$OUT" "has_deploy=false"
}
test_ci_none_et_deploy_false_sont_respectes() {
  mkrepo
  cat > .xsel-deploy.yml <<'Y'
version: 1
apps:
  backend: { deploy_path: /a, ci: none }
  frontend: { deploy_path: /b, deploy: false }
Y
  git add -A; git commit -q -m m
  plan workflow_dispatch REF=refs/heads/main
  assert_eq "$(names ci_apps)" "frontend"; assert_eq "$(names deploy_apps)" "backend"
}
test_valeurs_par_defaut_et_normalisation() {
  mkrepo; plan workflow_dispatch REF=refs/heads/main
  be="$(echo "$OUT" | sed -n 's/^deploy_apps=//p' | jq -c '.[0]')"; fe="$(echo "$OUT" | sed -n 's/^deploy_apps=//p' | jq -c '.[1]')"
  assert_eq "$(jq -r .path <<<"$be")" "backend"; assert_eq "$(jq -r .php_bin <<<"$be")" "auto"
  assert_eq "$(jq -r .manage_web_php <<<"$be")" "true"; assert_eq "$(jq -r .composer_on_server <<<"$be")" "false"
  # false par défaut, même avec un package.json + script build (squelette Laravel/Vite d'une API)
  assert_eq "$(jq -r .build_frontend_assets <<<"$be")" "false"
  assert_eq "$(jq -r .build_frontend_assets <<<"$fe")" "false"
  assert_eq "$(jq -r .build_env <<<"$fe")" "NEXT_PUBLIC_API_URL=https://api.ex.com/v1"
}
test_valeurs_explicites_l_emportent() {
  mkrepo
  cat > .xsel-deploy.yml <<'Y'
version: 1
apps:
  backend:
    path: backend
    deploy_path: /a
    php_version: 8.4
    php_bin: /opt/alt/php84/usr/bin/php
    php_extensions: [intl, gd]
    composer_on_server: true
    manage_web_php: false
    build_frontend_assets: true
    protect_paths: [public/uploads, custom]
Y
  git add -A; git commit -q -m m; plan workflow_dispatch REF=refs/heads/main
  a="$(echo "$OUT" | sed -n 's/^deploy_apps=//p' | jq -c '.[0]')"
  assert_eq "$(jq -r .php_version <<<"$a")" "8.4"; assert_eq "$(jq -r .php_extensions <<<"$a")" "intl,gd"
  assert_eq "$(jq -r .composer_on_server <<<"$a")" "true"; assert_eq "$(jq -r .manage_web_php <<<"$a")" "false"
  assert_eq "$(jq -r .build_frontend_assets <<<"$a")" "true"
  assert_eq "$(jq -r .protect_paths <<<"$a")" $'public/uploads\ncustom'
}
test_erreurs_de_manifeste_explicites() {
  mkrepo; rm .xsel-deploy.yml; plan push REF=refs/heads/main BEFORE="$B1"
  assert_eq "$RC" 1; assert_contains "$OUT" "manifeste introuvable"
  printf 'version: 2\napps: {a: {deploy_path: /x}}\n' > .xsel-deploy.yml; plan push REF=refs/heads/main BEFORE="$B1"
  assert_eq "$RC" 1; assert_contains "$OUT" "version: 1"
  printf 'version: 1\napps: {}\n' > .xsel-deploy.yml; plan push REF=refs/heads/main BEFORE="$B1"
  assert_eq "$RC" 1; assert_contains "$OUT" "au moins une app"
}
test_avertit_sur_cle_inconnue_et_sans_health_check() {
  mkrepo; printf 'version: 1\napps:\n  backend: {deploy_path: /a, phpversion: 8.4}\n' > .xsel-deploy.yml; git add -A; git commit -q -m m
  plan workflow_dispatch REF=refs/heads/main
  assert_eq "$RC" 0; assert_contains "$OUT" "clé inconnue « phpversion »"; assert_contains "$OUT" "pas de health_check_url"
}

test_dispatch_provision_ne_lance_que_les_apps_a_provisionner() {
  mkrepo
  cat > .xsel-deploy.yml <<'Y'
version: 1
apps:
  backend: { deploy_path: /a, provision: { database: sis } }
  frontend: { deploy_path: /b }
Y
  git add -A; git commit -q -m m
  plan workflow_dispatch REF=refs/heads/main ACTION=provision
  assert_eq "$RC" 0; assert_eq "$(names provision_apps)" "backend"; assert_eq "$(names deploy_apps)" ""; assert_eq "$(names ci_apps)" ""
  assert_eq "$(echo "$OUT" | sed -n 's/^provision_apps=//p' | jq -r '.[0].provision_database')" "sis"
  assert_contains "$OUT" "has_provision=true"
}
test_provision_n_est_jamais_lance_par_un_push() {
  mkrepo; printf 'version: 1\napps:\n  backend: {deploy_path: /a, provision: true}\n' > .xsel-deploy.yml; git add -A; git commit -q -m m
  plan push REF=refs/heads/main BEFORE=0000000000000000000000000000000000000000
  assert_contains "$OUT" "has_provision=false"
}
test_protect_paths_automatique_pour_une_app_imbriquee() {
  # Sous-domaine cPanel rangé dans le dossier du domaine principal (PECI, Univers Gravure) :
  # sans protection, le rsync --delete du frontend effacerait le backend.
  mkrepo
  cat > .xsel-deploy.yml <<'Y'
version: 1
apps:
  backend:
    deploy_path: /home/u/site.com/backend
  frontend:
    deploy_path: /home/u/site.com/
    protect_paths: [uploads, backend]
  autre:
    path: frontend
    deploy_path: /home/u/site.com-old
Y
  git add -A; git commit -q -m m; plan workflow_dispatch REF=refs/heads/main
  apps="$(echo "$OUT" | sed -n 's/^deploy_apps=//p')"
  assert_eq "$(jq -r '.[] | select(.name=="frontend") | .protect_paths' <<<"$apps")" $'uploads\nbackend'   # sans doublon, ordre conservé
  assert_eq "$(jq -r '.[] | select(.name=="backend") | .protect_paths' <<<"$apps")" ""
  assert_eq "$(jq -r '.[] | select(.name=="autre") | .protect_paths' <<<"$apps")" ""                    # préfixe de nom ≠ dossier parent
  printf 'version: 1\napps:\n  backend: {deploy_path: /home/u/s/api}\n  frontend: {path: frontend, deploy_path: /home/u/s}\n' > .xsel-deploy.yml
  git add -A; git commit -q -m m2; plan workflow_dispatch REF=refs/heads/main
  assert_eq "$(echo "$OUT" | sed -n 's/^deploy_apps=//p' | jq -r '.[] | select(.name=="frontend") | .protect_paths')" "api"
  assert_contains "$OUT" "protect_paths frontend : api"
}
test_manifeste_de_staging_deploie_sa_branche_seulement() {
  mkrepo
  printf 'version: 1\ndeploy_branch: staging\nenvironment: staging\napps:\n  backend: {deploy_path: /home/u/api-staging}\n' > .xsel-deploy.staging.yml
  git add -A; git commit -q -m s
  plan push MANIFEST=.xsel-deploy.staging.yml REF=refs/heads/staging BEFORE="$B1"
  assert_eq "$RC" 0; assert_contains "$OUT" "environment=staging"
  assert_eq "$(echo "$OUT" | sed -n 's/^deploy_apps=//p' | jq -r '.[].deploy_path')" "/home/u/api-staging"
  plan push MANIFEST=.xsel-deploy.staging.yml REF=refs/heads/main BEFORE="$B1"
  assert_eq "$(echo "$OUT" | sed -n 's/^deploy_apps=//p')" "[]"
}
test_deploiement_manuel_refuse_hors_de_la_branche_de_deploiement() {
  mkrepo
  plan workflow_dispatch REF=refs/heads/feature/x
  assert_eq "$RC" 1; assert_contains "$OUT" "déploiement manuel refusé depuis feature/x"
  plan workflow_dispatch REF=refs/heads/feature/x ACTION=doctor
  assert_eq "$RC" 0                                                         # diagnostic toujours permis
}
