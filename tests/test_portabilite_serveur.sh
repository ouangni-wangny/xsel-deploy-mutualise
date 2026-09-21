# Contraintes des scripts exécutés sur les serveurs mutualisés (leçons vécues)

test_pas_de_substitution_de_processus() {
  # /dev/fd est absent sous CageFS (CloudLinux) : `< <(cmd)` y échoue avec
  # « /dev/fd/63: No such file or directory » (cas vécu : resolve-php.sh).
  hits="$(grep -nE '<\(' "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh | grep -vE '^[^:]+:[0-9]+:\s*#' || true)"
  [ -z "$hits" ] || fail "substitution de processus interdite dans les scripts serveur :"$'\n'"$hits"
}
test_scripts_serveur_passent_bash_n() {
  for f in "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh; do bash -n "$f" || fail "erreur de syntaxe : $f"; done
}
