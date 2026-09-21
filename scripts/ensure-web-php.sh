#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — ensure-web-php.sh
#
# Exécuté SUR LE SERVEUR (via `ssh host 'bash -s' < ce-script`) pendant le
# préflight. Le PHP en ligne de commande (php_bin) et le PHP qui sert le site
# (cPanel → MultiPHP Manager, par domaine) sont deux réglages distincts : un
# déploiement peut réussir en CLI puis renvoyer HTTP 500 parce que le domaine
# tourne encore sur une version plus ancienne (cas vécu sur SIS : composer
# platform_check « requires PHP >= 8.3 » alors que le CLI était en 8.4).
#
# Ce script aligne le PHP du domaine sur celui de php_bin, via l'API cPanel
# `uapi LangPHP` (utilisable par l'utilisateur). Il ne bloque jamais le
# déploiement : hors cPanel/uapi ou en cas d'échec, il avertit et sort en 0
# (le healthcheck post-déploiement fait foi et affiche un diagnostic).
#
# Variables d'environnement :
#   PHP_BIN   binaire PHP CLI de déploiement (requis)
#   DOMAIN    domaine/sous-domaine servi (vhost cPanel) ; vide = ignoré
# =============================================================================
set -uo pipefail

PHP_BIN="${PHP_BIN:?PHP_BIN requis}"
DOMAIN="${DOMAIN:-}"

if [ -z "$DOMAIN" ]; then
  echo "PHP web : domaine inconnu (health_check_url vide) — vérification ignorée"
  exit 0
fi
if ! command -v uapi >/dev/null 2>&1; then
  echo "PHP web : uapi indisponible (hors cPanel ?) — vérification ignorée"
  exit 0
fi

VER="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION . PHP_MINOR_VERSION;' 2>/dev/null)"
[ -n "$VER" ] || { echo "::warning::PHP web : version de ${PHP_BIN} illisible — vérification ignorée"; exit 0; }
WANT="ea-php${VER}"

# Version actuelle du vhost (JSON parsé avec le PHP du serveur : pas de jq requis).
current_version() {
  uapi --output=json LangPHP php_get_vhost_versions 2>/dev/null \
    | "$PHP_BIN" -r '$j = json_decode(stream_get_contents(STDIN), true);
        foreach (($j["result"]["data"] ?? []) as $v) {
          if (($v["vhost"] ?? "") === $argv[1]) { echo $v["version"] ?? ""; break; }
        }' "$DOMAIN" 2>/dev/null
}

HAVE="$(current_version)"
if [ -z "$HAVE" ]; then
  echo "::warning::PHP web : domaine ${DOMAIN} introuvable dans cPanel (LangPHP) — vérification ignorée"
  exit 0
fi

if [ "$HAVE" = "$WANT" ]; then
  echo "PHP web OK : ${DOMAIN} sert ${HAVE}"
  exit 0
fi

echo "PHP web : ${DOMAIN} sert ${HAVE}, attendu ${WANT} (php_bin) — alignement via cPanel MultiPHP"
uapi LangPHP php_set_vhost_versions version="$WANT" vhost="$DOMAIN" 2>&1 | sed 's/^/  uapi : /' | head -n 20

HAVE="$(current_version)"
if [ "$HAVE" = "$WANT" ]; then
  echo "PHP web OK : ${DOMAIN} sert maintenant ${HAVE}"
else
  echo "::warning::PHP web : ${DOMAIN} sert toujours '${HAVE:-?}' (attendu ${WANT}) — réglez-le dans cPanel → MultiPHP Manager, sinon HTTP 500 probable"
fi
exit 0
