# Câblage des workflows (ce que les tests de scripts ne voient pas) : leçons vécues

# step_block <fichier> <nom-de-l'étape> : texte de l'étape jusqu'à la suivante
step_block() { awk -v n="$2" '$0 ~ "- name: " n {f=1; print; next} f && /^      - name:/ {exit} f' "$1"; }

test_resolve_php_recoit_les_inputs_utilisateur_et_non_la_valeur_resolue() {
  # Régression v1.3.0 : `php_bin: ${{ env.RESOLVED_PHP_BIN }}` faisait ignorer
  # un php_bin explicite (traité comme "auto").
  for wf in deploy doctor; do
    blk="$(step_block "$REPO/.github/workflows/$wf.yml" "Résoudre le PHP du serveur")"
    [ -n "$blk" ] || fail "étape introuvable dans $wf.yml"
    assert_contains "$blk" 'php_bin: ${{ inputs.php_bin }}'
    assert_contains "$blk" 'php_version: ${{ inputs.php_version }}'
    assert_not_contains "$blk" 'RESOLVED_PHP_BIN'
  done
}
test_les_etapes_serveur_utilisent_le_php_resolu() {
  wf="$REPO/.github/workflows/deploy.yml"
  for step in "Vérifier et activer les extensions PHP du serveur" "Aligner la version PHP du serveur web"; do
    assert_contains "$(step_block "$wf" "$step")" 'env.RESOLVED_PHP_BIN'
  done
  assert_contains "$(step_block "$wf" "Finaliser le déploiement")" 'PHP_BIN='"'"'${{ env.RESOLVED_PHP_BIN }}'"'"
}
test_le_kit_est_recupere_a_la_version_du_workflow_appele() {
  for wf in deploy doctor; do
    assert_contains "$(cat "$REPO/.github/workflows/$wf.yml")" 'ref: ${{ job.workflow_sha }}'
    assert_not_contains "$(cat "$REPO/.github/workflows/$wf.yml")" 'ref: main'
  done
}
test_toutes_les_actions_tierces_sont_epinglees_par_sha() {
  bad="$(grep -hE '^\s*-?\s*uses:' "$REPO"/.github/workflows/*.yml | grep -vE '@[0-9a-f]{40}|uses: \./|uses: ouangni-wangny/xsel-deploy-mutualise' || true)"
  [ -z "$bad" ] || fail "actions non épinglées par SHA :"$'\n'"$bad"
}
