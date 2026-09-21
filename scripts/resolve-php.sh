#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — resolve-php.sh
#
# Exécuté SUR LE SERVEUR (via `ssh host 'bash -s' < ce-script`). Détermine quel
# binaire PHP CLI utiliser pour le déploiement, sans que le projet ait à
# connaître les chemins CloudLinux/cPanel (/opt/alt/phpXY, /opt/cpanel/ea-phpXY).
#
# Ordre de décision :
#   1. PHP_BIN_INPUT explicite (≠ auto) : utilisé tel quel.
#   2. PHP_VERSION_INPUT (ex. 8.4) : binaire de cette version.
#   3. Version cPanel MultiPHP du domaine (uapi), si >= MIN_PHP : le CLI suit le web.
#   4. La plus basse version installée >= MIN_PHP (la plus mature qui convient).
#   5. `php` du PATH.
# Puis : erreur si la version obtenue est inférieure à MIN_PHP (composer.json).
#
# Variables : PHP_BIN_INPUT PHP_VERSION_INPUT MIN_PHP DOMAIN
#             ALT_PHP_ROOT (défaut /opt/alt)  EA_PHP_ROOT (défaut /opt/cpanel)   [tests]
# Sortie    : `php_bin=<chemin>` et `php_version=<X.Y>` (+ ligne d'information).
# =============================================================================
set -uo pipefail

IN_BIN="${PHP_BIN_INPUT:-auto}"
IN_VER="${PHP_VERSION_INPUT:-}"
MIN="${MIN_PHP:-}"
DOMAIN="${DOMAIN:-}"
ALT="${ALT_PHP_ROOT:-/opt/alt}"
EA="${EA_PHP_ROOT:-/opt/cpanel}"

num() { local a="${1%%.*}" b="${1#*.}"; b="${b%%.*}"; echo $(( a * 100 + b )); }   # 8.4 -> 804
bin_version() { "$1" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null; }

# Binaires candidats pour une version "X.Y" (CloudLinux alt-php d'abord : c'est
# lui que pilote le PHP Selector / selectorctl).
candidates_for() {
  local nn="${1/./}"
  echo "${ALT}/php${nn}/usr/bin/php"
  echo "${EA}/ea-php${nn}/root/usr/bin/php"
}

# Versions installées ("X.Y"), triées croissant.
installed_versions() {
  { for p in "${ALT}"/php[0-9][0-9]/usr/bin/php "${EA}"/ea-php[0-9][0-9]/root/usr/bin/php; do
      [ -x "$p" ] || continue
      nn="$(echo "$p" | grep -oE '(alt/php|ea-php|/php)[0-9]{2}' | grep -oE '[0-9]{2}$')"
      echo "${nn:0:1}.${nn:1:1}"
    done; } | sort -u -t. -k1,1n -k2,2n
}

find_bin() {
  local c
  while read -r c; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done < <(candidates_for "$1")
  # php du PATH si c'est bien cette version
  if command -v php >/dev/null 2>&1 && [ "$(bin_version php)" = "$1" ]; then command -v php; return 0; fi
  return 1
}

# N'importe quel PHP suffit pour lire le JSON d'uapi (le `php` du PATH peut
# être absent sous CageFS).
any_php() {
  command -v php 2>/dev/null && return 0
  local p
  for p in "${ALT}"/php[0-9][0-9]/usr/bin/php "${EA}"/ea-php[0-9][0-9]/root/usr/bin/php; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

SOURCE=""
BIN=""
if [ -n "$IN_BIN" ] && [ "$IN_BIN" != "auto" ]; then
  BIN="$(command -v "$IN_BIN" 2>/dev/null || true)"
  SOURCE="input php_bin"
  [ -n "$BIN" ] || { echo "::error::php_bin introuvable : ${IN_BIN}"; exit 1; }
else
  WANT="$IN_VER"; [ -n "$WANT" ] && SOURCE="input php_version"
  if [ -z "$WANT" ] && [ -n "$DOMAIN" ] && command -v uapi >/dev/null 2>&1; then
    V="$(uapi --output=json LangPHP php_get_vhost_versions 2>/dev/null \
        | "$(any_php || echo php)" -r '$j = json_decode(stream_get_contents(STDIN), true);
            foreach (($j["result"]["data"] ?? []) as $v) { if (($v["vhost"] ?? "") === $argv[1]) { echo $v["version"] ?? ""; break; } }' "$DOMAIN" 2>/dev/null \
        | grep -oE '[0-9]{2}$' || true)"
    if [ -n "$V" ]; then
      cand="${V:0:1}.${V:1:1}"
      if [ -z "$MIN" ] || [ "$(num "$cand")" -ge "$(num "$MIN")" ]; then WANT="$cand"; SOURCE="PHP cPanel du domaine ${DOMAIN}"; fi
    fi
  fi
  if [ -z "$WANT" ] && [ -n "$MIN" ]; then
    while read -r v; do
      [ -n "$v" ] && [ "$(num "$v")" -ge "$(num "$MIN")" ] && { WANT="$v"; SOURCE="plus basse version installée >= ${MIN} (composer.json)"; break; }
    done < <(installed_versions)
  fi
  if [ -z "$WANT" ] && command -v php >/dev/null 2>&1; then
    WANT="$(bin_version php)"; SOURCE="php du PATH"
  fi
  [ -n "$WANT" ] || { echo "::error::aucun PHP détecté sur le serveur (ni alt-php, ni ea-php, ni php dans le PATH)"; exit 1; }
  BIN="$(find_bin "$WANT" || true)"
  if [ -z "$BIN" ]; then
    echo "::error::PHP ${WANT} introuvable sur le serveur. Versions installées : $(installed_versions | tr '\n' ' ')"
    exit 1
  fi
fi

VER="$(bin_version "$BIN")"
[ -n "$VER" ] || { echo "::error::impossible de lire la version de ${BIN}"; exit 1; }

if [ -n "$MIN" ] && [ "$(num "$VER")" -lt "$(num "$MIN")" ]; then
  echo "::error::PHP ${VER} (${BIN}) < ${MIN} exigé par composer.json — choisissez une version plus récente (input php_version)"
  exit 1
fi

echo "PHP serveur : ${BIN} (${VER}) — ${SOURCE}"
echo "php_bin=${BIN}"
echo "php_version=${VER}"
