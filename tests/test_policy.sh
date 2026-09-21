# policy.sh (avertissements) et validation du deploy_path (plan.sh)
proj() { git init -q "$T/p" && cd "$T/p" && git config user.email t@t && git config user.name t && mkdir -p backend .github/workflows
  printf 'version: 1\napps:\n  backend:\n    deploy_path: /home/u/api\n    health_check_url: %s\n' "${1:-https://api.ex.com/up}" > .xsel-deploy.yml; }
pol() { run env REPO_DIR="$T/p" "$@" bash "$REPO/scripts/policy.sh"; }

test_avertit_si_env_est_versionne() {
  proj; echo "APP_KEY=x" > backend/.env; git add -A; git commit -q -m m
  pol; assert_eq "$RC" 0; assert_contains "$OUT" "backend/.env est versionné"
}
test_silencieux_si_projet_sain() {
  proj; echo "APP_KEY=" > backend/.env.example; printf 'backend/.env\n' > .gitignore; git add -A; git commit -q -m m
  pol; assert_eq "$RC" 0; assert_eq "$OUT" ""
}
test_avertit_sur_health_check_http() {
  proj http://api.ex.com/up; git add -A; git commit -q -m m
  pol; assert_contains "$OUT" "health_check_url en http://"
}
test_kit_flottant_ou_sha_ne_declenche_rien() {
  proj; git add -A; git commit -q -m m
  printf 'jobs:\n  a:\n    uses: ouangni-wangny/xsel-deploy-mutualise/.github/workflows/pipeline.yml@v1\n' > .github/workflows/a.yml
  pol KIT_LATEST=v1.9.0; assert_eq "$OUT" ""
  printf 'jobs:\n  a:\n    uses: ouangni-wangny/xsel-deploy-mutualise/.github/workflows/pipeline.yml@%s\n' "$(printf 'a%.0s' $(seq 40))" > .github/workflows/a.yml
  pol KIT_LATEST=v1.9.0; assert_eq "$OUT" ""
}
test_avertit_si_le_kit_epingle_est_en_retard() {
  proj; git add -A; git commit -q -m m
  printf 'jobs:\n  a:\n    uses: ouangni-wangny/xsel-deploy-mutualise/.github/workflows/pipeline.yml@v1.4.0\n' > .github/workflows/a.yml
  pol KIT_LATEST=v1.10.0; assert_contains "$OUT" "épinglé sur v1.4.0 alors que v1.10.0 est disponible"     # tri de versions, pas alphabétique
  pol KIT_LATEST=v1.4.0;  assert_eq "$OUT" ""
}
test_avertit_si_le_kit_est_reference_par_une_branche() {
  proj; git add -A; git commit -q -m m
  printf 'jobs:\n  a:\n    uses: ouangni-wangny/xsel-deploy-mutualise/.github/workflows/pipeline.yml@main\n' > .github/workflows/a.yml
  pol; assert_contains "$OUT" "référencé par « @main »"
}
test_plan_refuse_un_deploy_path_dangereux() {
  proj; for bad in "relatif/chemin" "/home/u/../etc"; do
    printf 'version: 1\napps:\n  backend: {deploy_path: "%s"}\n' "$bad" > .xsel-deploy.yml
    run env REPO_DIR="$T/p" EVENT_NAME=workflow_dispatch REF=refs/heads/main bash "$REPO/scripts/plan.sh"
    assert_eq "$RC" 1; assert_contains "$OUT" "chemin absolu sans « .. »"
  done
}
