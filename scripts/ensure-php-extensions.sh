#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — ensure-php-extensions.sh
#
# Exécuté SUR LE SERVEUR (via `ssh host 'bash -s' < ce-script`) pendant le
# préflight. Vérifie que le PHP CLI de déploiement expose toutes les
# extensions requises par l'application (déduites de composer.json/lock par
# le workflow) et tente de combler les manquantes via le PHP Selector de
# CloudLinux (`selectorctl`, utilisable par l'utilisateur lui-même) — ce qui
# évite l'étape manuelle « cPanel → Select PHP Version → cocher l'extension ».
#
# Variables d'environnement :
#   PHP_BIN          binaire PHP CLI de déploiement (requis)
#   REQUIRED_EXTS    extensions requises, séparées par des espaces (peut être vide)
#   CHECK_ONLY       "1" : diagnostic seul (aucune activation, sort toujours en 0) —
#                    utilisé par le workflow doctor
#
# Codes de sortie : 0 = tout est présent (éventuellement après activation),
#                   1 = il manque encore des extensions (message explicite).
# Ne modifie rien si tout est déjà présent (idempotent).
# =============================================================================
set -uo pipefail

PHP_BIN="${PHP_BIN:?PHP_BIN requis}"
REQUIRED_EXTS="${REQUIRED_EXTS:-}"

# Liste normalisée (minuscules, espaces -> _) des modules chargés par un PHP.
php_modules() {
  "$1" -m 2>/dev/null | tr '[:upper:] ' '[:lower:]_'
}

# Affiche, séparées par des espaces, les extensions de $2.. absentes du PHP $1.
missing_exts() {
  local php="$1" mods e out=""
  shift
  mods="$(php_modules "$php")"
  for e in "$@"; do
    printf '%s\n' "$mods" | grep -qx -- "$e" || out="$out $e"
  done
  printf '%s' "${out# }"
}

# shellcheck disable=SC2086  # découpage volontaire de la liste
set -- $REQUIRED_EXTS
if [ "$#" -eq 0 ]; then
  echo "extensions PHP : aucune extension requise détectée"
  exit 0
fi

MISSING="$(missing_exts "$PHP_BIN" "$@")"

if [ -n "$MISSING" ] && [ "${CHECK_ONLY:-}" = "1" ]; then
  echo "extensions PHP manquantes pour ${PHP_BIN} : ${MISSING} (diagnostic : rien n'est activé ; un déploiement tentera selectorctl)"
  exit 0
fi

if [ -n "$MISSING" ]; then
  VER="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)"
  if command -v selectorctl >/dev/null 2>&1 && [ -n "$VER" ]; then
    echo "extensions PHP manquantes : ${MISSING} — activation via CloudLinux PHP Selector (PHP ${VER})"
    selectorctl --enable-user-extensions="${MISSING// /,}" --version="$VER" 2>&1 | sed 's/^/  selectorctl : /'
    # Le selector écrit alt_php.ini immédiatement : on revérifie.
    # shellcheck disable=SC2086
    MISSING="$(missing_exts "$PHP_BIN" $MISSING)"
  else
    echo "extensions PHP manquantes : ${MISSING} (selectorctl indisponible : activation automatique impossible)"
  fi
fi

if [ -n "$MISSING" ]; then
  echo "::error::extensions PHP manquantes pour ${PHP_BIN} : ${MISSING} — activez-les côté hébergeur (cPanel → Select PHP Version → Extensions) ou retirez la dépendance"
  exit 1
fi

echo "extensions PHP OK ($#) : $*"

# Parité avec le PHP du serveur web (MultiPHP ea-phpXY) : le selector ne pilote
# que alt-php (CLI). Si ea-php existe pour la même version, on signale (sans
# bloquer) les extensions qui y manquent — c'est ce PHP qui sert les requêtes.
VER="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION . PHP_MINOR_VERSION;' 2>/dev/null)"
EA_PHP="/opt/cpanel/ea-php${VER}/root/usr/bin/php"
if [ -n "$VER" ] && [ -x "$EA_PHP" ] && [ "$EA_PHP" != "$PHP_BIN" ]; then
  WEB_MISSING="$(missing_exts "$EA_PHP" "$@")"
  if [ -n "$WEB_MISSING" ]; then
    echo "::warning::le PHP web ${EA_PHP} n'a pas : ${WEB_MISSING} — à vérifier si l'app les utilise à l'exécution (le déploiement continue)"
  else
    echo "parité PHP web (${EA_PHP}) : OK"
  fi
fi
exit 0
