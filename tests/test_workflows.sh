# Câblage des workflows et actions (ce que les tests de scripts ne voient pas) :
# chaque test correspond à une régression réellement rencontrée ou évitée de justesse.

WF="$REPO/.github/workflows"; ACT="$REPO/.github/actions"

# step_block <fichier> <nom-de-l'étape> : texte de l'étape jusqu'à la suivante (workflow ou action)
step_block() { awk -v n="$2" '$0 ~ "- name: " n {f=1; print; next} f && /^ +- name:/ {exit} f' "$1"; }
# yaml_keys <fichier> <chemin.ruby> : clés d'un hash YAML (ex. "inputs")
yaml_keys() { ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); h=ARGV[1].split(".").inject(d){|a,k| a[k] || {}}; puts h.keys' "$1" "$2"; }

test_resolve_php_recoit_les_inputs_utilisateur_et_non_la_valeur_resolue() {
  # Régression v1.3.0 : `php_bin: ${{ env.RESOLVED_PHP_BIN }}` faisait ignorer un php_bin explicite.
  for f in "$ACT/deploy-app/action.yml" "$ACT/doctor-app/action.yml"; do
    blk="$(step_block "$f" "Résoudre le PHP du serveur")"
    [ -n "$blk" ] || fail "étape introuvable dans $f"
    assert_contains "$blk" 'php_bin: ${{ inputs.php_bin }}'
    assert_contains "$blk" 'php_version: ${{ inputs.php_version }}'
    assert_not_contains "$blk" 'RESOLVED_PHP_BIN'
  done
}
test_les_etapes_serveur_utilisent_le_php_resolu() {
  f="$ACT/deploy-app/action.yml"
  for step in "Préflight" "Vérifier et activer les extensions PHP du serveur" "Aligner la version PHP du serveur web" "Finaliser le déploiement"; do
    assert_contains "$(step_block "$f" "$step")" 'RESOLVED_PHP_BIN'
  done
}
test_les_workflows_transmettent_toutes_les_entrees_des_actions() {
  # Une entrée d'action oubliée dans le workflow = valeur par défaut silencieuse.
  for pair in "deploy-app:deploy" "doctor-app:doctor"; do
    a="${pair%%:*}"; w="${pair##*:}"
    for k in $(yaml_keys "$ACT/$a/action.yml" inputs); do
      case "$k" in ssh_host|ssh_port|ssh_user|ssh_private_key) k2="$k" ;; *) k2="$k" ;; esac
      grep -qE "^ +${k2}: \\$\\{\\{" "$WF/$w.yml" || fail "$w.yml ne transmet pas l'entrée « $k » à l'action $a"
    done
  done
}
test_le_kit_est_recupere_a_la_version_du_workflow_appele() {
  for wf in deploy doctor; do
    assert_contains "$(cat "$WF/$wf.yml")" 'ref: ${{ job.workflow_sha }}'
    assert_not_contains "$(cat "$WF/$wf.yml")" 'ref: main'
  done
}
test_toutes_les_actions_tierces_sont_epinglees_par_sha() {
  bad="$(grep -hE '^\s*-?\s*uses:' "$WF"/*.yml "$ACT"/*/action.yml | grep -vE '@[0-9a-f]{40}|uses: \./|uses: ouangni-wangny/xsel-deploy-mutualise' || true)"
  [ -z "$bad" ] || fail "actions non épinglées par SHA :"$'\n'"$bad"
}
test_les_scripts_shell_des_actions_ont_une_syntaxe_valide() {
  for f in "$ACT"/*/action.yml; do
    n=0
    while IFS= read -r idx; do
      ruby -ryaml -e 'File.write(ARGV[1], YAML.load_file(ARGV[0])["runs"]["steps"][ARGV[2].to_i]["run"])' "$f" "$T/s.sh" "$idx"
      bash -n "$T/s.sh" || fail "syntaxe shell invalide dans $f (étape $idx)"; n=$((n+1))
    done < <(ruby -ryaml -e 'YAML.load_file(ARGV[0])["runs"]["steps"].each_with_index{|s,i| puts i if s["run"]}' "$f")
    [ "$n" -gt 0 ] || fail "aucun script trouvé dans $f"
  done
}

# --- pipeline.yml <-> plan.sh <-> actions : les trois doivent parler la même langue ---
plan_keys() { # clés d'une app dans deploy_apps, produites par plan.sh
  mkdir -p "$T/p/backend"; printf 'version: 1\napps:\n  backend: {deploy_path: /a}\n' > "$T/p/.xsel-deploy.yml"
  REPO_DIR="$T/p" EVENT_NAME=workflow_dispatch REF=refs/heads/main bash "$REPO/scripts/plan.sh" 2>/dev/null \
    | sed -n 's/^deploy_apps=//p' | jq -r '.[0] | keys[]'
}
test_pipeline_n_utilise_que_des_champs_produits_par_plan() {
  produced="$(plan_keys)"; [ -n "$produced" ] || fail "plan.sh n'a rien produit"
  for k in $(grep -oE 'matrix\.app\.[a-z_]+' "$WF/pipeline.yml" | sort -u | sed 's/matrix\.app\.//'); do
    echo "$produced" | grep -qx "$k" || fail "pipeline.yml utilise matrix.app.$k, absent de la sortie de plan.sh"
  done
}
test_pipeline_transmet_toutes_les_entrees_de_deploy_app_et_ci_app() {
  for pair in "deploy-app:Déployer" "ci-app:CI" "doctor-app:Diagnostic"; do
    a="${pair%%:*}"; step="${pair##*:}"
    blk="$(awk -v a="$a" '$0 ~ "uses: ./deploy-kit/.github/actions/" a {f=1} f {print} f && /^  [a-z]+:$/ {exit}' "$WF/pipeline.yml")"
    [ -n "$blk" ] || fail "appel de l'action $a introuvable dans pipeline.yml"
    for k in $(yaml_keys "$ACT/$a/action.yml" inputs); do
      grep -qE "^ +${k}: " <<<"$blk" || fail "pipeline.yml ne transmet pas « $k » à $a"
    done
  done
}
test_pipeline_recupere_le_kit_a_la_version_du_workflow() {
  n="$(grep -c 'ref: ${{ job.workflow_sha }}' "$WF/pipeline.yml")"; [ "$n" -ge 4 ] || fail "chaque job doit récupérer le kit à job.workflow_sha ($n trouvés)"
}
test_le_deploiement_est_sequentiel_et_attend_la_ci() {
  blk="$(awk '/^  deploy:/{f=1} f' "$WF/pipeline.yml" | awk 'NR>1 && /^  [a-z]+:$/ {exit} {print}')"
  assert_contains "$blk" "max-parallel: 1"; assert_contains "$blk" "needs: [plan, ci]"; assert_contains "$blk" "needs.ci.result == 'success'"
}
