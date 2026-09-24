#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — deploy-nextjs-passenger.sh
#
# Exécuté SUR LE SERVEUR (via ssh), une fois que le workflow a déjà rsync
# le build Next.js standalone directement dans DEPLOY_PATH (voir ADR-0002 :
# déploiement direct, sans releases/) :
#   DEPLOY_PATH/
#   ├── server.js          (.next/standalone/server.js)
#   ├── node_modules/       (minimal, tracé par Next — pas d'install serveur)
#   ├── .next/static/
#   └── public/
#
# Voir ADR-0003 : les variables d'environnement runtime sont configurées une
# fois pour toutes dans l'interface cPanel "Setup Node.js App", pas ici.
#
# Variables d'environnement requises :
#   DEPLOY_PATH        racine de l'app (code déployé directement dedans)
#   HEALTH_CHECK_URL         (optionnel)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-}"

[ -f "${DEPLOY_PATH}/server.js" ] || die "server.js absent — vérifiez next.config (output: 'standalone')."

log "Redémarrage Passenger (touch tmp/restart.txt)"
mkdir -p "${DEPLOY_PATH}/tmp"
touch "${DEPLOY_PATH}/tmp/restart.txt"

# Passenger ne relance le process qu'au prochain hit HTTP entrant ; le
# healthcheck ci-dessous (contre le domaine public) sert aussi de premier hit.
sleep 2

if [ -n "$HEALTH_CHECK_URL" ]; then
  health_check "$HEALTH_CHECK_URL" || die "Déploiement terminé mais healthcheck KO — le code est en place, vérifiez le log ci-dessus ; pour revenir en arrière : git revert du commit fautif, puis push."
fi

ok "Déploiement Next.js terminé : ${DEPLOY_PATH}"
