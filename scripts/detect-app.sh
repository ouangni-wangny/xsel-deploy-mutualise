#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — detect-app.sh
#
# Exécuté SUR LE RUNNER (checkout du projet appelant). Déduit ce que le projet
# n'a pas besoin de déclarer : stack, PHP minimal, extensions PHP exigées,
# version de Node. Convention plutôt que configuration : un input explicite du
# workflow appelant l'emporte toujours.
#
# Usage : detect-app.sh <dossier_de_l_app>
# Env   : STACK_INPUT   auto | laravel | nextjs-passenger        (défaut auto)
#         EXTRA_EXTS    extensions PHP supplémentaires, séparées par des virgules
#         NODE_INPUT    version de Node imposée (sinon détectée)
# Sortie: lignes `clé=valeur` sur stdout (stack, min_php, required_exts,
#         node_version) ; diagnostics `::error::` sur stdout, code 1 si échec.
# =============================================================================
set -euo pipefail

DIR="${1:?usage: detect-app.sh <dossier>}"
STACK="${STACK_INPUT:-auto}"

[ -d "$DIR" ] || { echo "::error::dossier de l'app introuvable : ${DIR}"; exit 1; }

has_dep() { # has_dep <fichier.json> <jq-objet> <paquet>
  [ -f "$1" ] && jq -e --arg p "$3" "(${2}) | has(\$p)" "$1" >/dev/null 2>&1
}

if [ "$STACK" = "auto" ]; then
  if has_dep "$DIR/composer.json" '.require // {}' 'laravel/framework'; then
    STACK="laravel"
  elif has_dep "$DIR/package.json" '(.dependencies // {}) + (.devDependencies // {})' 'next'; then
    STACK="nextjs-passenger"
  else
    echo "::error::stack indétectable dans ${DIR} (ni laravel/framework dans composer.json, ni next dans package.json) — renseignez l'input stack"
    exit 1
  fi
fi

case "$STACK" in
  laravel|nextjs-passenger) ;;
  *) echo "::error::stack invalide : '${STACK}' (attendu : auto | laravel | nextjs-passenger)"; exit 1 ;;
esac

MIN_PHP=""
REQUIRED_EXTS=""
if [ "$STACK" = "laravel" ]; then
  # PHP minimal : premier « X.Y » de require.php (ex. "^8.3", ">=8.2 <8.5" -> 8.3 / 8.2).
  if [ -f "$DIR/composer.json" ]; then
    MIN_PHP="$(jq -r '.require.php // ""' "$DIR/composer.json" | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)"
  fi
  # Extensions : require de composer.json + des paquets du lock (prod, hors dev).
  REQUIRED_EXTS="$(
    {
      [ -f "$DIR/composer.json" ] && jq -r '(.require // {}) | keys[]' "$DIR/composer.json" 2>/dev/null
      [ -f "$DIR/composer.lock" ] && jq -r '(.packages // [])[] | (.require // {}) | keys[]' "$DIR/composer.lock" 2>/dev/null
      printf '%s\n' "${EXTRA_EXTS:-}" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d;s/^/ext-/'
    } | { grep '^ext-' || true; } | sed 's/^ext-//' | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ' '
  )"
  REQUIRED_EXTS="${REQUIRED_EXTS% }"
fi

# Node : Next.js toujours ; Laravel aussi (assets Vite) — même règle de détection.
NODE_VERSION="${NODE_INPUT:-}"
if [ -z "$NODE_VERSION" ]; then
  for f in "$DIR/.nvmrc" "$DIR/.node-version"; do
    [ -f "$f" ] && NODE_VERSION="$(grep -oE '[0-9]+' "$f" | head -n 1 || true)" && [ -n "$NODE_VERSION" ] && break
  done
fi
if [ -z "$NODE_VERSION" ] && [ -f "$DIR/package.json" ]; then
  NODE_VERSION="$(jq -r '.engines.node // ""' "$DIR/package.json" | grep -oE '[0-9]+' | head -n 1 || true)"
fi
NODE_VERSION="${NODE_VERSION:-22}"

echo "stack=${STACK}"
echo "min_php=${MIN_PHP}"
echo "required_exts=${REQUIRED_EXTS}"
echo "node_version=${NODE_VERSION}"
