# conform.sh (règles de conformité, --fix, --json) et init.sh --check / --fix / --json.
# Le projet « avant » reproduit un monorepo réel au jour de son intégration :
# chaque règle bloquante correspond à un incident réellement vécu.
CONFORM="$REPO/scripts/conform.sh"; INIT="$REPO/scripts/init.sh"

projet_non_conforme() {
  git init -q "$T/p" && cd "$T/p" && git config user.email t@t && git config user.name t
  git remote add origin "https://github.com/client/site.git"
  mkdir -p backend/config backend/tests/Feature frontend .github/workflows
  echo '{"require":{"php":"^8.3","laravel/framework":"^13.0"}}' > backend/composer.json
  echo '{}' > backend/composer.lock
  echo '<?php // test' > backend/tests/Feature/ExampleTest.php
  cat > backend/phpunit.xml <<'X'
<phpunit>
    <testsuites>
        <testsuite name="Unit">
            <directory>tests/Unit</directory>
        </testsuite>
        <testsuite name="Feature">
            <directory>tests/Feature</directory>
        </testsuite>
    </testsuites>
    <source><include><directory>app</directory></include></source>
</phpunit>
X
  printf "<?php\nreturn ['connections' => [\n  'mysql' => [\n            'engine' => null,\n  ],\n  'mariadb' => [\n            'engine' => null,\n  ],\n]];\n" > backend/config/database.php
  echo '{"dependencies":{"next":"16.0.0"}}' > frontend/package.json
  echo '{}' > frontend/package-lock.json
  cat > frontend/next.config.ts <<'N'
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  poweredByHeader: false,
};

export default nextConfig;
N
  printf 'version: 1\napps:\n  backend:\n    deploy_path: /home/u/site/backend\n  frontend:\n    deploy_path: /home/u/site\n' > .xsel-deploy.yml
  printf 'jobs:\n  pipeline:\n    uses: ouangni-wangny/xsel-deploy-mutualise/.github/workflows/pipeline.yml@v1\n    secrets: inherit\n' > .github/workflows/cicd.yml
  git add -A && git commit -q -m init
}
ids() { jq -r '[.regles[] | select(.statut=="a_corriger") | .id] | sort | join(" ")' <<<"$OUT"; }

test_detecte_tous_les_manques_du_projet() {
  projet_non_conforme
  run bash "$CONFORM" --json
  assert_eq "$RC" 1
  assert_eq "$(ids)" "dependabot laravel-htaccess moteur-innodb next-standalone phpunit-dossier secrets-inherit version-node"
  assert_eq "$(jq -r '[.regles[] | select(.niveau=="erreur") | .id] | sort | join(" ")' <<<"$OUT")" "next-standalone phpunit-dossier secrets-inherit"
  assert_eq "$(jq -r '.conforme' <<<"$OUT")" "false"
}
test_fix_corrige_tout_et_le_projet_devient_conforme() {
  projet_non_conforme
  run bash "$CONFORM" --fix; assert_eq "$RC" 0; assert_contains "$OUT" "7 corrigé(s)"
  assert_file_contains frontend/next.config.ts 'output: "standalone",'
  assert_file_contains .github/workflows/cicd.yml 'DEPLOY_SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}'
  ! grep -qE "^[[:space:]]*secrets:[[:space:]]*inherit" .github/workflows/cicd.yml || fail "secrets: inherit encore actif"
  assert_file_contains backend/config/database.php "'engine' => env('DB_ENGINE', 'InnoDB'),"
  [ -f backend/tests/Unit/.gitkeep ] && [ -f backend/.htaccess ] && [ -f .github/dependabot.yml ] || fail "fichiers attendus absents"
  assert_eq "$(cat frontend/.nvmrc)" "22"
  ruby -ryaml -e 'YAML.load_file(".github/workflows/cicd.yml")' || fail "cicd.yml corrigé n'est plus du YAML valide"
  git add -A; run bash "$CONFORM" --json; assert_eq "$RC" 0; assert_eq "$(jq -r .conforme <<<"$OUT")" "true"
}
test_fix_est_idempotent() {
  projet_non_conforme; bash "$CONFORM" --fix >/dev/null; git add -A; git commit -q -m fix
  run bash "$CONFORM" --fix; assert_eq "$RC" 0; assert_contains "$OUT" "0 corrigé(s)"
  assert_eq "$(git status --porcelain)" ""
}
test_secrets_inherit_accepte_si_meme_proprietaire() {
  projet_non_conforme; git remote set-url origin git@github.com:ouangni-wangny/site.git
  run bash "$CONFORM" --json; assert_not_contains "$(ids)" "secrets-inherit"
  run env PROJECT_REPO=autre/site bash "$CONFORM" --json; assert_contains "$(ids)" "secrets-inherit"   # le pipeline fait foi
}
test_policy_ignore_desactive_une_regle() {
  projet_non_conforme; printf 'policy:\n  ignore: [laravel-htaccess, phpunit-dossier]\n' >> .xsel-deploy.yml
  run bash "$CONFORM" --fix --json
  assert_eq "$(jq -r '[.regles[] | select(.statut=="ignore") | .id] | sort | join(" ")' <<<"$OUT")" "laravel-htaccess phpunit-dossier"
  [ ! -f backend/.htaccess ] && [ ! -d backend/tests/Unit ] || fail "une règle ignorée a été corrigée"
}
test_erreurs_non_corrigeables_restent_bloquantes() {
  projet_non_conforme; git rm -q --cached frontend/package-lock.json; rm frontend/package-lock.json
  echo "APP_KEY=secret" > backend/.env; git add -f backend/.env; git commit -q -m m
  run bash "$CONFORM" --fix --json; assert_eq "$RC" 1
  assert_eq "$(jq -r '[.regles[] | select(.statut=="a_corriger") | .id] | join(" ")' <<<"$OUT")" "npm-lock"
  assert_eq "$(jq -r '.regles[] | select(.id=="env-versionne") | .statut' <<<"$OUT")" "corrige"
  [ -z "$(git ls-files backend/.env)" ] && [ -f backend/.env ] || fail ".env doit sortir de l'index sans être supprimé"
  assert_file_contains backend/.gitignore ".env"
}
test_next_output_different_n_est_pas_ecrase() {
  projet_non_conforme; perl -pi -e 's/poweredByHeader: false,/output: "export",/' frontend/next.config.ts
  run bash "$CONFORM" --fix --json
  assert_eq "$(jq -r '.regles[] | select(.id=="next-standalone") | .statut' <<<"$OUT")" "a_corriger"
  assert_file_contains frontend/next.config.ts 'output: "export",'
}
test_version_node_du_manifeste_suffit() {
  projet_non_conforme; perl -0pi -e 's/(deploy_path: \/home\/u\/site\n)/$1    node_version: "20"\n/' .xsel-deploy.yml
  run bash "$CONFORM" --json; assert_not_contains "$(ids)" "version-node"
}
test_annotate_ecrit_le_resume_du_run() {
  projet_non_conforme; export GITHUB_STEP_SUMMARY="$T/summary.md"
  run bash "$CONFORM" --annotate; assert_eq "$RC" 1
  assert_contains "$OUT" "::error::conformité [next-standalone] frontend :"
  assert_contains "$OUT" "::warning::conformité [dependabot]"
  assert_file_contains "$T/summary.md" "| ❌ | \`secrets-inherit\` |"
  assert_file_contains "$T/summary.md" "scripts/init.sh) --fix"
}

# --- init.sh -----------------------------------------------------------------
test_init_check_n_ecrit_rien_et_echoue_si_bloquant() {
  projet_non_conforme
  run bash "$INIT" --check; assert_eq "$RC" 1; assert_contains "$OUT" "erreur [secrets-inherit]"
  assert_eq "$(git status --porcelain)" ""
}
test_init_fix_json_pour_un_agent() {
  projet_non_conforme
  set +e; J="$(bash "$INIT" --fix --json 2>/dev/null)"; RC=$?; set -e
  assert_eq "$RC" 0
  assert_eq "$(jq -r '.conforme, .corriges' <<<"$J" | tr '\n' ' ')" "true 7 "    # stdout = JSON pur
}
test_init_genere_un_workflow_sans_secrets_inherit() {
  mkdir -p "$T/n/app"; cd "$T/n"; echo '{"dependencies":{"next":"16.0.0"}}' > app/package.json
  bash "$INIT" >/dev/null 2>&1
  ! grep -qE "^[[:space:]]*secrets:[[:space:]]*inherit" .github/workflows/cicd.yml || fail "secrets: inherit encore actif"
  assert_file_contains .github/workflows/cicd.yml 'DEPLOY_SSH_HOST: ${{ secrets.DEPLOY_SSH_HOST }}'
}
