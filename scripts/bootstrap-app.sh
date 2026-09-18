#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — bootstrap-app.sh
#
# Prépare UNE FOIS le dossier d'une app avant son premier déploiement
# automatisé (voir README, section Onboarding). Déploiement direct, sans
# releases/ (voir ADR-0002).
#
# Usage (sur le serveur, via SSH) :
#   DEPLOY_PATH=/home/user/api.peci.org STACK=laravel bash bootstrap-app.sh
#   DEPLOY_PATH=/home/user/peci.org     STACK=nextjs-passenger bash bootstrap-app.sh
# =============================================================================
set -euo pipefail

[ -n "${DEPLOY_PATH:-}" ] || { echo "❌ DEPLOY_PATH requis" >&2; exit 1; }
STACK="${STACK:-}"

mkdir -p "${DEPLOY_PATH}"
echo "✅ ${DEPLOY_PATH} prêt"

if [ "$STACK" = "laravel" ]; then
  mkdir -p "${DEPLOY_PATH}/storage"/{app,framework,logs}
  mkdir -p "${DEPLOY_PATH}/storage/framework"/{cache,sessions,views}
  echo "✅ ${DEPLOY_PATH}/storage créé"

  if [ ! -f "${DEPLOY_PATH}/.env" ]; then
    touch "${DEPLOY_PATH}/.env"
    chmod 600 "${DEPLOY_PATH}/.env"
    echo "⚠️  ${DEPLOY_PATH}/.env créé VIDE — à remplir manuellement avant le premier déploiement (le script de déploiement refusera de continuer sinon)."
  else
    echo "ℹ️  ${DEPLOY_PATH}/.env existe déjà, inchangé."
  fi
fi

echo "✅ Bootstrap terminé pour ${DEPLOY_PATH}"
