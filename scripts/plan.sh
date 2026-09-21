#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — plan.sh
#
# Exécuté SUR LE RUNNER par pipeline.yml (job `plan`). Lit le manifeste
# `.xsel-deploy.yml` du projet et décide QUOI lancer selon l'événement :
#
#   push (branche de déploiement)  -> CI + déploiement des apps modifiées
#   push (autre branche)           -> CI des apps modifiées
#   pull_request                   -> CI des apps modifiées
#   workflow_dispatch              -> CI + déploiement (toutes, ou ONLY_APPS) ;
#                                     ACTION=doctor : diagnostic seul
#   schedule                       -> monitoring seul
#
# Une app est « modifiée » si un fichier sous son `path` a changé, ou si le
# manifeste / .github/ a changé (alors : toutes). Sans diff exploitable
# (première poussée, force-push) : toutes.
#
# Env  : MANIFEST (défaut .xsel-deploy.yml)  REPO_DIR (défaut .)
#        EVENT_NAME  REF  BEFORE  SHA  BASE_SHA  ACTION  ONLY_APPS (csv)
#        DEPLOY_BRANCH (défaut : valeur du manifeste, sinon main)
# Sortie : `clé=valeur` sur $GITHUB_OUTPUT (sinon stdout) : ci_apps deploy_apps
#        doctor_apps (JSON), has_ci has_deploy has_doctor has_monitor,
#        monitor_urls (JSON), environment.
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-.}"
MANIFEST="${MANIFEST:-.xsel-deploy.yml}"
EVENT="${EVENT_NAME:-push}"
REF="${REF:-}"
BEFORE="${BEFORE:-}"
SHA="${SHA:-HEAD}"
BASE_SHA="${BASE_SHA:-}"
ACTION="${ACTION:-}"
ONLY_APPS="${ONLY_APPS:-}"

die() { echo "::error::$*"; exit 1; }

[ -f "$REPO_DIR/$MANIFEST" ] || die "manifeste introuvable : ${MANIFEST} (voir templates/xsel-deploy.example.yml du kit)"

# YAML -> JSON (ruby est présent sur les runners GitHub comme sur macOS)
CFG="$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$REPO_DIR/$MANIFEST")" \
  || die "manifeste illisible (YAML invalide) : ${MANIFEST}"

[ "$(jq -r '.version // empty' <<<"$CFG")" = "1" ] || die "${MANIFEST} : « version: 1 » requis"
[ "$(jq -r '(.apps // {}) | length' <<<"$CFG")" -gt 0 ] || die "${MANIFEST} : au moins une app sous « apps: » est requise"

# Clés inconnues (fautes de frappe) : avertissement, pas d'échec.
KNOWN_APP='["path","stack","deploy","deploy_path","health_check_url","ci","database","lint","php_version","php_bin","php_extensions","composer_on_server","composer_bin","manage_web_php","build_frontend_assets","node_version","build_env","protect_paths"]'
jq -r --argjson known "$KNOWN_APP" '.apps | to_entries[] | . as $a | ($a.value | keys[]) | select(. as $k | $known | index($k) | not) | "\($a.key): clé inconnue « \(.) »"' <<<"$CFG" \
  | while read -r m; do echo "::warning::${MANIFEST} — ${m}"; done
jq -r '(keys[]) | select(. as $k | ["version","apps","environment","deploy_branch","monitor"] | index($k) | not) | "clé inconnue « \(.) »"' <<<"$CFG" \
  | while read -r m; do echo "::warning::${MANIFEST} — ${m}"; done

DEPLOY_BRANCH="${DEPLOY_BRANCH:-$(jq -r '.deploy_branch // "main"' <<<"$CFG")}"
ENVIRONMENT="$(jq -r '.environment // "production"' <<<"$CFG")"

# --- Apps normalisées (toutes les valeurs par défaut posées ici, une seule fois)
# NB jq : `false // x` vaut x (`//` traite false comme absent) → helper d() qui
# ne remplace que null, indispensable pour les booléens (deploy: false…).
APPS="$(jq -c 'def d(x): if . == null then x else . end;
  .apps | to_entries | map(.key as $n | .value as $v | {
    name: $n,
    path: ($v.path | d($n)),
    stack: ($v.stack | d("auto")),
    deploy: ($v.deploy | d(true)),
    deploy_path: ($v.deploy_path | d("")),
    health_check_url: ($v.health_check_url | d("")),
    ci: ($v.ci | d("standard")),
    database: ($v.database | d("none")),
    lint: ($v.lint | d(false)),
    php_version: (($v.php_version | d("")) | tostring),
    php_bin: ($v.php_bin | d("auto")),
    php_extensions: (($v.php_extensions | d([])) | if type=="array" then join(",") else . end),
    composer_on_server: ($v.composer_on_server | d(false)),
    composer_bin: ($v.composer_bin | d("composer")),
    manage_web_php: ($v.manage_web_php | d(true)),
    build_frontend_assets: ($v.build_frontend_assets | d(false)),
    node_version: (($v.node_version | d("")) | tostring),
    build_env: (($v.build_env | d({})) | if type=="object" then to_entries | map("\(.key)=\(.value)") | join("\n") else . end),
    protect_paths: (($v.protect_paths | d([])) | if type=="array" then join("\n") else . end)
  })' <<<"$CFG")"

# build_frontend_assets : false par défaut. Le squelette Laravel embarque toujours
# un package.json avec `vite build`, même pour une API JSON : le détecter comme
# « assets à compiler » serait un faux positif fréquent → activation explicite.

# --- Fichiers modifiés
ALL=false
CHANGED=""
range_from=""
case "$EVENT" in
  pull_request) range_from="$BASE_SHA" ;;
  push)         range_from="$BEFORE" ;;
esac
if [ -n "$range_from" ] && ! [[ "$range_from" =~ ^0+$ ]] \
   && CHANGED="$(git -C "$REPO_DIR" diff --name-only "$range_from" "$SHA" 2>/dev/null)"; then
  :
else
  ALL=true
fi
# Manifeste ou automatisation modifiés : tout est concerné.
if [ "$ALL" = false ] && grep -qE "^(${MANIFEST//./\\.}|\.github/)" <<<"$CHANGED"; then ALL=true; fi

select_changed() { # stdin: apps JSON ; sortie : apps dont le path a changé (ou toutes)
  if [ "$ALL" = true ]; then cat; return; fi
  local paths; paths="$(jq -R -s -c 'split("\n") | map(select(length>0))' <<<"$CHANGED")"
  jq -c --argjson f "$paths" '[ .[] | select(.path as $p | any($f[]; (. == $p) or startswith(($p | sub("/$";"")) + "/") or $p == ".")) ]'
}
select_only() { # filtre ONLY_APPS (csv de noms) s'il est fourni
  if [ -z "$ONLY_APPS" ]; then cat; return; fi
  jq -c --arg o "$ONLY_APPS" '($o | split(",") | map(gsub("^\\s+|\\s+$";""))) as $names | [ .[] | select(.name as $n | $names | index($n)) ]'
}

ON_DEPLOY_BRANCH=false
[ "$REF" = "refs/heads/${DEPLOY_BRANCH}" ] && ON_DEPLOY_BRANCH=true

CI_APPS="[]"; DEPLOY_APPS="[]"; DOCTOR_APPS="[]"; MONITOR="[]"

case "$EVENT" in
  schedule)
    MONITOR="$(jq -c --argjson cfg "$CFG" '
      ($cfg.monitor.urls // ([.[] | select(.health_check_url != "") | .health_check_url])) | if type=="array" then . else [.] end' <<<"$APPS")"
    ;;
  workflow_dispatch)
    SEL="$(select_only <<<"$APPS")"
    if [ "$ACTION" = "doctor" ]; then
      DOCTOR_APPS="$(jq -c '[ .[] | select(.deploy_path != "") ]' <<<"$SEL")"
    else
      CI_APPS="$(jq -c '[ .[] | select(.ci != "none") ]' <<<"$SEL")"
      DEPLOY_APPS="$(jq -c '[ .[] | select(.deploy and .deploy_path != "") ]' <<<"$SEL")"
    fi
    ;;
  push|pull_request)
    SEL="$(select_changed <<<"$APPS")"
    CI_APPS="$(jq -c '[ .[] | select(.ci != "none") ]' <<<"$SEL")"
    if [ "$EVENT" = "push" ] && [ "$ON_DEPLOY_BRANCH" = true ]; then
      DEPLOY_APPS="$(jq -c '[ .[] | select(.deploy and .deploy_path != "") ]' <<<"$SEL")"
    fi
    ;;
esac

# Déployer sans health_check_url est permis mais déconseillé.
jq -r '.[] | select(.health_check_url == "") | "\(.name): pas de health_check_url — un déploiement cassé ne se signalerait nulle part"' <<<"$DEPLOY_APPS" \
  | while read -r m; do echo "::warning::${MANIFEST} — ${m}"; done

has() { [ "$(jq 'length' <<<"$1")" -gt 0 ] && echo true || echo false; }

emit() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; else echo "$1=$2"; fi; }
emit ci_apps "$CI_APPS"
emit deploy_apps "$DEPLOY_APPS"
emit doctor_apps "$DOCTOR_APPS"
emit monitor_urls "$MONITOR"
emit has_ci "$(has "$CI_APPS")"
emit has_deploy "$(has "$DEPLOY_APPS")"
emit has_doctor "$(has "$DOCTOR_APPS")"
emit has_monitor "$(has "$MONITOR")"
emit environment "$ENVIRONMENT"

# Résumé lisible dans le log
echo "plan — événement=${EVENT} branche_deploiement=${DEPLOY_BRANCH} sur_branche_deploiement=${ON_DEPLOY_BRANCH} tout=${ALL}" >&2
echo "  CI      : $(jq -r 'map(.name) | join(", ") | if .=="" then "(aucune)" else . end' <<<"$CI_APPS")" >&2
echo "  deploy  : $(jq -r 'map(.name) | join(", ") | if .=="" then "(aucune)" else . end' <<<"$DEPLOY_APPS")" >&2
echo "  doctor  : $(jq -r 'map(.name) | join(", ") | if .=="" then "(aucune)" else . end' <<<"$DOCTOR_APPS")" >&2
echo "  monitor : $(jq -r 'length' <<<"$MONITOR") URL(s)" >&2
