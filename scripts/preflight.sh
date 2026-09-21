#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — preflight.sh
#
# Exécuté SUR LE SERVEUR (via `ssh host 'bash -s' < ce-script`) avant tout
# transfert : échoue vite et clairement plutôt qu'au milieu du déploiement
# (cas vécus : rsync trop ancien, php_bin introuvable, disque plein).
#
# Variables : STACK (laravel|nextjs-passenger)  DEPLOY_PATH
#             PHP_BIN  COMPOSER_ON_SERVER (true|false)  COMPOSER_BIN
# Sortie    : `COMPOSER_FALLBACK=1` si composer_on_server et composer introuvable
#             (le workflow enverra alors le composer.phar du runner).
# =============================================================================
set -uo pipefail

STACK="${STACK:?STACK requis}"
DEPLOY_PATH="${DEPLOY_PATH:?DEPLOY_PATH requis}"

command -v rsync >/dev/null || { echo "::error::rsync introuvable sur le serveur"; exit 1; }
echo "rsync (serveur) : $(rsync --version | head -1)"

# Si un chemin est faux, on liste ce qui existe réellement sur le serveur :
# évite un aller-retour manuel en SSH pour le trouver.
diag_bins() {
  echo "binaires trouvés sur le serveur :"
  for c in $(command -v php composer 2>/dev/null) /opt/alt/php*/usr/bin/php /opt/alt/php*/usr/bin/composer \
           /opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/composer/bin/composer /usr/local/bin/composer \
           "$HOME/bin/composer" "$HOME/.local/bin/composer"; do
    [ -x "$c" ] && echo "  - $c"
  done
}

if [ "$STACK" = "laravel" ]; then
  PHP_BIN="${PHP_BIN:?PHP_BIN requis pour laravel}"
  command -v "$PHP_BIN" >/dev/null || { echo "::error::php_bin introuvable : ${PHP_BIN}"; diag_bins; exit 1; }
  echo "php_bin : $("$PHP_BIN" -v | head -1)"
  if [ "${COMPOSER_ON_SERVER:-false}" = "true" ]; then
    command -v "${COMPOSER_BIN:-composer}" >/dev/null || echo "COMPOSER_FALLBACK=1"
  fi
fi

FREE_MB="$(df -Pm "$DEPLOY_PATH" 2>/dev/null | tail -1 | awk '{print $4}')"
echo "espace disque libre : ${FREE_MB:-?} Mo"
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 100 ]; then
  echo "::error::moins de 100 Mo disponibles sur le serveur"
  exit 1
fi
exit 0
