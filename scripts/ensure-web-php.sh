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
# `uapi LangPHP` (utilisable par l'utilisateur) ET en garantissant le bloc
# « cPanel-generated handler » dans le .htaccess du document root : c'est ce
# bloc que MultiPHP écrit pour appliquer la version, et un déploiement rsync
# qui écrase le .htaccess (versionné dans le repo) le supprime — le domaine
# retombe alors sur le PHP hérité du dossier parent (cas SIS : uapi annonçait
# ea-php84 mais le site tournait en 8.1 hérité de public_html/.htaccess).
# À exécuter APRÈS le transfert du code, à chaque déploiement (idempotent).
#
# Il ne bloque jamais le déploiement : hors cPanel/uapi ou en cas d'échec, il
# avertit et sort en 0 (le healthcheck post-déploiement fait foi et affiche un
# diagnostic).
#
# Variables d'environnement :
#   PHP_BIN   binaire PHP CLI de déploiement (requis)
#   DOMAIN    domaine/sous-domaine servi (vhost cPanel) ; vide = ignoré
#   CHECK_ONLY "1" : diagnostic seul (ne modifie ni cPanel ni .htaccess) — workflow doctor
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

# Fiche du vhost (JSON parsé avec le PHP du serveur : pas de jq requis).
# $1 = champ à extraire (version | documentroot).
vhost_field() {
  uapi --output=json LangPHP php_get_vhost_versions 2>/dev/null \
    | "$PHP_BIN" -r '$j = json_decode(stream_get_contents(STDIN), true);
        foreach (($j["result"]["data"] ?? []) as $v) {
          if (($v["vhost"] ?? "") === $argv[1]) { echo $v[$argv[2]] ?? ""; break; }
        }' "$DOMAIN" "$1" 2>/dev/null
}

HAVE="$(vhost_field version)"
if [ -z "$HAVE" ]; then
  echo "::warning::PHP web : domaine ${DOMAIN} introuvable dans cPanel (LangPHP) — vérification ignorée"
  exit 0
fi

# 1) Réglage cPanel (userdata du vhost).
if [ "${CHECK_ONLY:-}" = "1" ]; then
  DOCROOT="$(vhost_field documentroot)"
  echo "PHP web : ${DOMAIN} déclaré ${HAVE} dans cPanel (attendu ${WANT}) — docroot ${DOCROOT:-?}"
  if [ -f "${DOCROOT}/.htaccess" ] && grep -q "application/x-httpd-${WANT} " "${DOCROOT}/.htaccess" 2>/dev/null; then
    echo "  .htaccess : handler ${WANT} présent"
  else
    echo "  .htaccess : handler ${WANT} ABSENT — un déploiement le (ré)installera"
  fi
  exit 0
fi
if [ "$HAVE" != "$WANT" ]; then
  echo "PHP web : ${DOMAIN} déclaré ${HAVE}, attendu ${WANT} (php_bin) — alignement via cPanel MultiPHP"
  uapi LangPHP php_set_vhost_versions version="$WANT" vhost="$DOMAIN" 2>&1 | sed 's/^/  uapi : /' | head -n 20
  HAVE="$(vhost_field version)"
  if [ "$HAVE" = "$WANT" ]; then
    echo "PHP web : ${DOMAIN} déclaré ${HAVE}"
  else
    echo "::warning::PHP web : ${DOMAIN} toujours déclaré '${HAVE:-?}' (attendu ${WANT}) — réglez-le dans cPanel → MultiPHP Manager"
  fi
else
  echo "PHP web : ${DOMAIN} déclaré ${HAVE} (cPanel)"
fi

# 2) Bloc handler dans le .htaccess du document root (ce qui s'applique vraiment).
DOCROOT="$(vhost_field documentroot)"
if [ -z "$DOCROOT" ] || [ ! -d "$DOCROOT" ]; then
  echo "::warning::PHP web : document root de ${DOMAIN} introuvable ('${DOCROOT:-?}') — .htaccess non vérifié"
  exit 0
fi
HT="${DOCROOT}/.htaccess"
BEGIN='# php -- BEGIN cPanel-generated handler, do not edit'
END='# php -- END cPanel-generated handler, do not edit'

if [ -f "$HT" ] && grep -q "application/x-httpd-${WANT} " "$HT" 2>/dev/null; then
  echo "PHP web OK : ${HT} contient déjà le handler ${WANT}"
  exit 0
fi

TMP="$(mktemp "${DOCROOT}/.htaccess.XXXXXX")" || { echo "::warning::PHP web : écriture impossible dans ${DOCROOT}"; exit 0; }
{
  printf '%s\n' "$BEGIN"
  printf '# Set the "%s" package as the default "PHP" programming language.\n' "$WANT"
  printf '<IfModule mime_module>\n  AddHandler application/x-httpd-%s .php .php8 .phtml\n</IfModule>\n' "$WANT"
  printf '%s\n' "$END"
  # Reprend l'existant en retirant un ancien bloc handler (autre version).
  if [ -f "$HT" ]; then
    awk -v b="$BEGIN" -v e="$END" '$0 == b {skip=1} !skip {print} $0 == e {skip=0}' "$HT"
  fi
} > "$TMP"
[ -f "$HT" ] && chmod --reference="$HT" "$TMP" 2>/dev/null
[ -f "$HT" ] || chmod 644 "$TMP"
mv -f "$TMP" "$HT"
echo "PHP web : handler ${WANT} (ré)installé dans ${HT}"
exit 0
