#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — common.sh
#
# Fonctions partagées par les scripts de déploiement server-side. Ce fichier
# est synchronisé vers le serveur à chaque déploiement (voir ADR-0004) : ne
# jamais le dupliquer dans un projet consommateur, toujours l'éditer ici.
#
# Attend les variables d'environnement suivantes (exportées par le script
# appelant) :
#   DEPLOY_PATH     racine de l'app sur le serveur (code déployé directement dedans)
# =============================================================================
set -euo pipefail

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# curl un healthcheck ; renvoie 1 si échec (le script appelant décide quoi
# faire — voir ADR-0002 : pas de rollback automatique, le déploiement est
# déjà en place au moment où ce check tourne).
health_check() {
  local url="$1"
  [ -n "$url" ] || return 0
  log "Healthcheck : ${url}"
  for _ in 1 2 3 4 5; do
    if curl -fsS -o /dev/null --max-time 10 "$url"; then
      ok "Healthcheck OK"
      return 0
    fi
    sleep 3
  done
  echo "❌ Healthcheck KO après 5 tentatives" >&2
  return 1
}
