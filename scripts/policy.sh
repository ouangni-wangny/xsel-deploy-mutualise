#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — policy.sh
#
# Exécuté SUR LE RUNNER (job `plan`). Applique les règles de conformité du
# projet (scripts/conform.sh, source unique des règles) au format GitHub :
#   - erreur        → ::error::, le job `plan` échoue : ni CI ni déploiement ;
#   - avertissement → ::warning::, sans effet sur le run.
# Chaque problème est aussi listé dans le résumé du run, avec la commande qui
# le corrige (init.sh --fix). Règles et désactivation : docs/adr/0012.
#
# Env : REPO_DIR (défaut .)  MANIFEST (défaut .xsel-deploy.yml)  KIT_LATEST (ex. v1.6.0)
#       PROJECT_REPO (owner/nom)  ENFORCE (true par défaut ; false = erreurs non bloquantes,
#       pour les actions doctor/provision qui ne déploient rien)
# =============================================================================
set -uo pipefail

REPO_DIR="${REPO_DIR:-.}"
MANIFEST="${MANIFEST:-.xsel-deploy.yml}"
ARGS=(--dir "$REPO_DIR" --manifest "$MANIFEST" --annotate)
[ "${ENFORCE:-true}" = "false" ] && ARGS+=(--no-enforce)

exec bash "$(dirname "${BASH_SOURCE[0]}")/conform.sh" "${ARGS[@]}"
