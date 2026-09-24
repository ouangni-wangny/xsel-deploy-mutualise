#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — provision-nextjs.sh
#
# Exécuté SUR LE SERVEUR (via `ssh host 'bash -s' < ce-script`) par l'action
# `provision`. Prépare UNE FOIS une app Next.js (Passenger) : crée le dossier et
# déclare l'application Node — ce qui se faisait à la main dans cPanel → Setup
# Node.js App :
#   - CloudLinux : `cloudlinux-selector create` (version de Node choisie) ;
#   - cPanel sans CloudLinux  : `uapi PassengerApps register_application` (Node du système) ;
#   - ni l'un ni l'autre      : instructions pour le faire dans cPanel.
#
# IDEMPOTENT : si une app Node existe déjà pour ce dossier, rien n'est modifié
# (sa version, ses variables d'environnement et son domaine sont conservés).
#
# Variables :
#   DEPLOY_PATH   dossier de l'app, sous le dossier personnel (requis)
#   DOMAIN        (sous-)domaine servi par l'app (requis, ex. example.com)
#   NODE_MAJOR    version majeure de Node (défaut 22 ; même règle que le build CI)
#   APP_URI       chemin de l'app sur le domaine (défaut /)
# =============================================================================
set -uo pipefail

DEPLOY_PATH="${DEPLOY_PATH:?DEPLOY_PATH requis}"
DOMAIN="${DOMAIN:-}"
NODE_MAJOR="${NODE_MAJOR:-22}"
APP_URI="${APP_URI:-/}"

log()  { echo "▶ $*"; }
warn() { echo "::warning::$*"; }
die()  { echo "::error::$*"; exit 1; }
manual() {
  warn "$1 — déclarez l'app dans cPanel → Setup Node.js App : Node ${NODE_MAJOR}, mode Production, racine ${DEPLOY_PATH}, domaine ${DOMAIN:-?}, fichier de démarrage server.js"
  exit 0
}

mkdir -p "$DEPLOY_PATH" || die "impossible de créer ${DEPLOY_PATH}"
log "dossier prêt : ${DEPLOY_PATH}"
[ -n "$DOMAIN" ] || manual "domaine inconnu (health_check_url absente du manifeste)"

HOME_DIR="${HOME%/}"
case "$DEPLOY_PATH" in
  "$HOME_DIR"/*) APP_ROOT="${DEPLOY_PATH#"$HOME_DIR"/}"; APP_ROOT="${APP_ROOT%/}" ;;
  *) manual "${DEPLOY_PATH} n'est pas sous ${HOME_DIR} : racine d'app non déclarable automatiquement" ;;
esac

if command -v cloudlinux-selector >/dev/null 2>&1; then
  LIST="$(cloudlinux-selector get --json --interpreter=nodejs 2>/dev/null || true)"
  # Les apps sont indexées par leur racine relative au dossier personnel.
  if grep -qF "\"${APP_ROOT}\": {\"app_mode\"" <<<"$LIST"; then
    log "app Node déjà déclarée pour ${APP_ROOT} : inchangée"
    exit 0
  fi
  VERSION="$(grep -oE "\"${NODE_MAJOR}\.[0-9.]+\": \{\"base_dir\"[^}]*\"status\": \"enabled\"" <<<"$LIST" | head -n 1 | cut -d'"' -f2)"
  if [ -z "$VERSION" ]; then
    AVAIL="$(grep -oE '"[0-9]+\.[0-9.]+": \{"base_dir"' <<<"$LIST" | cut -d'"' -f2 | cut -d. -f1 | sort -un | tr '\n' ' ')"
    die "Node ${NODE_MAJOR} indisponible sur ce serveur (disponibles : ${AVAIL:-?}) — ajustez .nvmrc / node_version"
  fi
  OUT="$(cloudlinux-selector create --json --interpreter=nodejs --version="$VERSION" --app-root="$APP_ROOT" \
          --domain="$DOMAIN" --app-uri="$APP_URI" --app-mode=production --startup-file=server.js 2>&1)"
  grep -q '"result": *"success"' <<<"$OUT" \
    || die "cloudlinux-selector a refusé la création : $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-300)"
  log "app Node déclarée : ${DOMAIN}${APP_URI} → ${APP_ROOT} (Node ${VERSION}, server.js, production)"
  echo "✅ Variables d'environnement serveur (hors NEXT_PUBLIC_*) : cPanel → Setup Node.js App → ${DOMAIN}"
  exit 0
fi

if command -v uapi >/dev/null 2>&1 && uapi --output=json PassengerApps list_applications 2>/dev/null | grep -q '"status":1'; then
  if uapi --output=json PassengerApps list_applications 2>/dev/null | grep -qF "\"path\":\"${DEPLOY_PATH}\""; then
    log "app Passenger déjà déclarée pour ${DEPLOY_PATH} : inchangée"
    exit 0
  fi
  NAME="$(printf '%s' "$APP_ROOT" | tr -c 'A-Za-z0-9\n' '-')"
  OUT="$(uapi --output=json PassengerApps register_application name="$NAME" path="$DEPLOY_PATH" domain="$DOMAIN" \
          base_uri="$APP_URI" deployment_mode=production enabled=1 2>&1)"
  grep -q '"status":1' <<<"$OUT" \
    || die "uapi PassengerApps a refusé la création : $(sed -n 's/.*"errors":\["\([^"]*\)".*/\1/p' <<<"$OUT" | head -n 1)"
  log "app Passenger déclarée : ${DOMAIN}${APP_URI} → ${DEPLOY_PATH} (Node du système, server.js)"
  exit 0
fi

manual "ni cloudlinux-selector ni uapi PassengerApps sur ce serveur"
