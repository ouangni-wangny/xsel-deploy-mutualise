#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — deploy-laravel.sh
#
# Exécuté SUR LE SERVEUR (via ssh), une fois que le workflow a déjà rsync
# le code source directement dans DEPLOY_PATH (sans vendor/, sans .env,
# sans storage/ — voir ADR-0002 : déploiement direct, sans releases/).
#
# Variables d'environnement requises :
#   DEPLOY_PATH        racine de l'app (code déployé directement dedans)
#   PHP_BIN              (défaut: php)
#   COMPOSER_BIN          (défaut: composer) — si introuvable, repli sur
#                         .deploy-scripts/composer.phar (envoyé par le workflow)
#                         exécuté avec PHP_BIN
#   HEALTH_CHECK_URL         (optionnel — si vide, pas de vérification post-deploy)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-}"

[ -d "$DEPLOY_PATH" ] || die "Dossier introuvable : $DEPLOY_PATH"
[ -f "${DEPLOY_PATH}/.env" ] || die "${DEPLOY_PATH}/.env manquant — créez-le une fois manuellement avant le premier déploiement."

mkdir -p "${DEPLOY_PATH}/storage"/{app,framework,logs}
mkdir -p "${DEPLOY_PATH}/storage/framework"/{cache,sessions,views}

cd "$DEPLOY_PATH"

# Hébergeurs sans composer : le workflow envoie le composer.phar du runner
# (voir « Envoyer les scripts »), exécuté avec PHP_BIN pour garantir la bonne
# version de PHP.
if command -v "$COMPOSER_BIN" >/dev/null 2>&1; then
  COMPOSER_CMD=("$COMPOSER_BIN")
elif [ -f "${SCRIPT_DIR}/composer.phar" ]; then
  log "composer introuvable (${COMPOSER_BIN}) — composer.phar du workflow exécuté avec ${PHP_BIN}"
  COMPOSER_CMD=("$PHP_BIN" "${SCRIPT_DIR}/composer.phar")
else
  die "composer introuvable : ${COMPOSER_BIN} (et pas de composer.phar fourni par le workflow)"
fi

log "composer install --no-dev"
"${COMPOSER_CMD[@]}" install --no-dev --optimize-autoloader --no-interaction --no-progress

log "artisan config:cache / route:cache / view:cache"
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan route:cache
"$PHP_BIN" artisan view:cache

backup_database "${DEPLOY_PATH}/.env" "${DEPLOY_PATH}/.backups/db" 5

log "artisan migrate --force"
"$PHP_BIN" artisan migrate --force

log "artisan storage:link"
"$PHP_BIN" artisan storage:link --force || true

if [ -n "$HEALTH_CHECK_URL" ]; then
  health_check "$HEALTH_CHECK_URL" || die "Déploiement terminé mais healthcheck KO — le code est en place, vérifiez manuellement (pas de rollback automatique, voir ADR-0002)."
fi

ok "Déploiement Laravel terminé : ${DEPLOY_PATH}"
