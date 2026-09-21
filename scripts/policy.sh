#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — policy.sh
#
# Exécuté SUR LE RUNNER (job `plan`). Vérifie les bonnes pratiques du PROJET et
# les signale par des avertissements (::warning::) — il ne bloque jamais ;
# seules les erreurs dangereuses de manifeste sont bloquantes, dans plan.sh.
#
# Contrôles :
#   - un fichier `.env` versionné dans git (secrets dans l'historique)
#   - health_check_url en http:// (le monitoring et les sessions devraient être en TLS)
#   - le kit référencé par une branche (@main…) au lieu d'un tag (@v1, @v1.4.0) ou d'un SHA
#   - le kit épinglé sur une version X.Y.Z plus ancienne que la dernière (KIT_LATEST)
#
# Env : REPO_DIR (défaut .)  MANIFEST (défaut .xsel-deploy.yml)  KIT_LATEST (ex. v1.5.0, optionnel)
# =============================================================================
set -uo pipefail

REPO_DIR="${REPO_DIR:-.}"
MANIFEST="${MANIFEST:-.xsel-deploy.yml}"
KIT_LATEST="${KIT_LATEST:-}"

warn() { echo "::warning::politique — $*"; }

[ -f "$REPO_DIR/$MANIFEST" ] || exit 0
CFG="$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$REPO_DIR/$MANIFEST" 2>/dev/null)" || exit 0

# .env versionné (dans le dossier de chaque app, ou à la racine)
for p in $(jq -r '.apps | to_entries[] | (.value.path // .key)' <<<"$CFG"); do
  f="$p/.env"; [ "$p" = "." ] && f=".env"
  if git -C "$REPO_DIR" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    warn "${f} est versionné dans git : des secrets sont dans l'historique. Le retirer (git rm --cached), l'ajouter au .gitignore et changer les mots de passe concernés"
  fi
done

# health_check_url non TLS
jq -r '.apps | to_entries[] | select((.value.health_check_url // "") | startswith("http://")) | .key' <<<"$CFG" \
  | while read -r app; do warn "l'app « ${app} » a une health_check_url en http:// : préférez https://"; done

# Référence du kit dans les workflows du projet
if [ -d "$REPO_DIR/.github/workflows" ]; then
  grep -hoE 'xsel-deploy-mutualise/\.github/workflows/[a-z-]+\.yml@[^ #]+' "$REPO_DIR"/.github/workflows/*.yml 2>/dev/null | sort -u \
    | while read -r ref; do
        v="${ref##*@}"
        if [[ "$v" =~ ^[0-9a-f]{40}$ ]] || [[ "$v" =~ ^v[0-9]+$ ]]; then continue; fi   # SHA ou tag flottant vN : OK
        if [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          if [ -n "$KIT_LATEST" ] && [ "$v" != "$KIT_LATEST" ] \
             && [ "$(printf '%s\n%s\n' "${v#v}" "${KIT_LATEST#v}" | sort -V | tail -n 1)" = "${KIT_LATEST#v}" ]; then
            warn "le kit est épinglé sur ${v} alors que ${KIT_LATEST} est disponible (ou passer à @${KIT_LATEST%%.*} pour suivre automatiquement)"
          fi
        else
          warn "le kit est référencé par « @${v} » (une branche) : utilisez un tag flottant (@v1), un tag précis (@v1.5.0) ou un SHA pour des déploiements reproductibles"
        fi
      done
fi
exit 0
