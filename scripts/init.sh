#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — init.sh
#
# Initialise le CI/CD d'un projet en UNE commande, à lancer à la racine du dépôt :
#   bash <(curl -fsSL https://raw.githubusercontent.com/ouangni-wangny/xsel-deploy-mutualise/v1/scripts/init.sh) \
#        --user monutilisateur --host serveur.example.com --port 22 --generate-key --set-secrets
#
# Ce qu'il fait : détecte les apps (Laravel / Next.js), écrit `.xsel-deploy.yml` et
# `.github/workflows/cicd.yml` (sans écraser l'existant), génère au besoin une clé
# SSH dédiée, et pose les 4 secrets GitHub avec `gh`. Il ne pose AUCUNE question
# (100 % pilotable par options) et n'écrit jamais de clé privée dans le dépôt.
#
# Conformité (règles de scripts/conform.sh, les mêmes que le pipeline, ADR-0012) :
#   init.sh --check          contrôle seul, n'écrit rien ; code 1 s'il reste une erreur bloquante
#   init.sh --fix            initialise si besoin, puis corrige tout ce qui est corrigeable
#   … --json                 rapport de conformité JSON sur stdout (le reste sur stderr) :
#                            pour un agent IA ou un outil. Même usage, dev ou agent.
#
# Options :
#   --dir DIR          racine du projet (défaut .)
#   --repo OWNER/NOM   dépôt GitHub des secrets (défaut : `gh repo view`)
#   --user U --host H --port P    cible SSH (secrets DEPLOY_SSH_USER/HOST/PORT)
#   --key-file FICHIER clé privée existante à utiliser
#   --generate-key     génère une clé ed25519 dédiée (dans $XSEL_KEY_DIR, défaut ~/.ssh)
#   --set-secrets      pose réellement les secrets (exige --user --host --port et une clé)
#   --kit-ref REF      référence du kit dans cicd.yml (défaut v1)
#   --force            écrase cicd.yml / .xsel-deploy.yml existants
#   --dry-run          n'écrit et ne pose RIEN : affiche seulement ce qui serait fait
#   --staging BRANCHE  environnement de staging : un push sur BRANCHE déploie avec
#                      .xsel-deploy.staging.yml (squelette écrit, dossiers et URLs à adapter)
#   --check | --fix | --json   voir « Conformité » ci-dessus
# =============================================================================
set -uo pipefail

DIR="."; REPO=""; SSH_USER=""; SSH_HOST=""; SSH_PORT=""; KEY_FILE=""
GEN_KEY=0; SET_SECRETS=0; KIT_REF="v1"; FORCE=0; DRY=0; CHECK=0; FIX=0; JSON=0; STAGING=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;            --repo) REPO="$2"; shift 2 ;;
    --user) SSH_USER="$2"; shift 2 ;;      --host) SSH_HOST="$2"; shift 2 ;;
    --port) SSH_PORT="$2"; shift 2 ;;      --key-file) KEY_FILE="$2"; shift 2 ;;
    --generate-key) GEN_KEY=1; shift ;;    --set-secrets) SET_SECRETS=1; shift ;;
    --kit-ref) KIT_REF="$2"; shift 2 ;;    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;             --check) CHECK=1; shift ;;
    --fix) FIX=1; shift ;;                 --json) JSON=1; shift ;;
    --staging) STAGING="$2"; shift 2 ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "option inconnue : $1 (voir --help)" >&2; exit 2 ;;
  esac
done

# Avec --json, stdout est réservé au rapport JSON : les messages passent sur stderr.
if [ "$JSON" -eq 1 ]; then exec 3>&1 1>&2; else exec 3>&1; fi
say()  { echo "$*"; }
step() { echo; echo "▶ $*"; }
act()  { if [ "$DRY" -eq 1 ]; then echo "  [dry-run] $*"; else echo "  ✓ $*"; fi; }

# conform.sh : à côté de ce script, ou téléchargé à la même version du kit
# (cas `bash <(curl …/init.sh)`, où aucun fichier voisin n'existe).
conform() {
  local c; c="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/conform.sh"
  if [ ! -f "$c" ]; then
    c="$(mktemp)"
    curl -fsSL "https://raw.githubusercontent.com/ouangni-wangny/xsel-deploy-mutualise/${KIT_REF}/scripts/conform.sh" -o "$c" \
      || { echo "conform.sh introuvable (téléchargement impossible)" >&2; return 2; }
  fi
  local args=(); [ "$JSON" -eq 1 ] && args+=(--json)
  bash "$c" ${args[@]+"${args[@]}"} "$@" >&3
}

command -v jq >/dev/null || { echo "jq est requis" >&2; exit 1; }
[ -d "$DIR" ] || { echo "dossier introuvable : $DIR" >&2; exit 1; }
cd "$DIR" || exit 1

# --- Contrôle seul : rien n'est écrit ----------------------------------------
if [ "$CHECK" -eq 1 ]; then conform; exit $?; fi

# --- 1. Détection des apps ---------------------------------------------------
step "Détection des applications"
LARAVEL=(); NEXT=()
for d in . */; do
  d="${d%/}"
  case "$d" in node_modules|vendor|.git|.github) continue ;; esac
  if [ -f "$d/composer.json" ] && jq -e '(.require // {}) | has("laravel/framework")' "$d/composer.json" >/dev/null 2>&1; then LARAVEL+=("$d")
  elif [ -f "$d/package.json" ] && jq -e '((.dependencies // {}) + (.devDependencies // {})) | has("next")' "$d/package.json" >/dev/null 2>&1; then NEXT+=("$d"); fi
done
APPS=(${LARAVEL[@]+"${LARAVEL[@]}"} ${NEXT[@]+"${NEXT[@]}"})   # API avant frontend
[ "${#APPS[@]}" -gt 0 ] || { echo "aucune app détectée (ni laravel/framework, ni next)" >&2; exit 1; }
for a in "${APPS[@]}"; do say "  - $a"; done

# --- 2. Manifeste et workflow ------------------------------------------------
U="${SSH_USER:-UTILISATEUR}"
write_file() { # write_file <chemin> ; contenu sur stdin
  if [ -e "$1" ] && [ "$FORCE" -eq 0 ]; then cat >/dev/null; act "$1 existe déjà : conservé (--force pour écraser)"; return; fi
  if [ "$DRY" -eq 1 ]; then cat >/dev/null; act "écrirait $1"; else mkdir -p "$(dirname "$1")"; cat > "$1"; act "$1 écrit"; fi
}

manifest() { # manifest [suffixe-de-dossier] [branche]
  local sfx="${1:-}" branch="${2:-}"
  echo "version: 1"; echo
  if [ -n "$branch" ]; then
    echo "# Staging : un push sur « ${branch} » déploie ces apps (manifeste choisi par cicd.yml)."
    echo "deploy_branch: ${branch}"; echo "environment: staging"; echo
  fi
  echo "apps:"
  for a in "${APPS[@]}"; do
    name="$a"; [ "$a" = "." ] && name="app"
    echo "  ${name}:"
    [ "$a" = "." ] && echo "    path: ." || echo "    path: ${a}"
    echo "    deploy_path: /home/${U}/${name}${sfx}                 # À ADAPTER : dossier sur le serveur"
    echo "    health_check_url: https://${sfx:+staging.}EXEMPLE.COM              # À ADAPTER : URL publique (Laravel : …/up)"
    case " ${LARAVEL[*]-} " in *" $a "*) echo "    # database: mysql                                   # CI : conteneur MySQL pour les tests"
                                       echo "    # provision: { database: nom${sfx:+_staging} }                      # création de la base + .env (action: provision)" ;; esac
    echo
  done
}

step "Manifeste .xsel-deploy.yml"
manifest | write_file .xsel-deploy.yml
if [ -n "$STAGING" ]; then
  step "Manifeste de staging .xsel-deploy.staging.yml (branche ${STAGING})"
  manifest -staging "$STAGING" | write_file .xsel-deploy.staging.yml
fi

step "Workflow .github/workflows/cicd.yml"
BRANCHES="main"; WITH=""
if [ -n "$STAGING" ]; then
  BRANCHES="main, ${STAGING}"
  WITH="    # Branche « ${STAGING} » → manifeste de staging ; toute autre → production.
    with:
      manifest: \${{ github.ref_name == '${STAGING}' && '.xsel-deploy.staging.yml' || '.xsel-deploy.yml' }}
"
fi
cat <<Y | write_file .github/workflows/cicd.yml
name: CI/CD

on:
  push:
    branches: [${BRANCHES}]
  pull_request:
  schedule:
    - cron: '*/15 * * * *'
  workflow_dispatch:
    inputs:
      action:
        description: "Que faire ?"
        type: choice
        options: [deploy, doctor, provision]
        default: deploy
      apps:
        description: "Apps concernées (noms séparés par des virgules ; vide = toutes)"
        type: string
        required: false

permissions:
  contents: read

jobs:
  pipeline:
    uses: ouangni-wangny/xsel-deploy-mutualise/.github/workflows/pipeline.yml@${KIT_REF}
${WITH}    # Secrets passés un par un : « secrets: inherit » ne transmet rien à un
    # workflow réutilisable d'un autre propriétaire.
    secrets:
      DEPLOY_SSH_HOST: \${{ secrets.DEPLOY_SSH_HOST }}
      DEPLOY_SSH_PORT: \${{ secrets.DEPLOY_SSH_PORT }}
      DEPLOY_SSH_USER: \${{ secrets.DEPLOY_SSH_USER }}
      DEPLOY_SSH_PRIVATE_KEY: \${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}
      NOTIFY_WEBHOOK_URL: \${{ secrets.NOTIFY_WEBHOOK_URL }}
      TELEGRAM_BOT_TOKEN: \${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID: \${{ secrets.TELEGRAM_CHAT_ID }}
Y

# --- 3. Clé SSH ---------------------------------------------------------------
KEY_PATH="$KEY_FILE"
if [ "$GEN_KEY" -eq 1 ] && [ -z "$KEY_FILE" ]; then
  step "Clé SSH dédiée"
  KD="${XSEL_KEY_DIR:-$HOME/.ssh}"; name="xsel-deploy-$(basename "$(pwd)")"
  if [ "$DRY" -eq 1 ]; then act "générerait ${KD}/${name} (ed25519, sans passphrase)"; KEY_PATH="${KD}/${name}"
  else
    mkdir -p "$KD"; chmod 700 "$KD"
    [ -e "${KD}/${name}" ] && { echo "  ${KD}/${name} existe déjà : réutilisée"; } \
      || ssh-keygen -q -t ed25519 -N "" -C "github-actions-deploy@$(basename "$(pwd)")" -f "${KD}/${name}"
    KEY_PATH="${KD}/${name}"; act "clé privée : ${KEY_PATH} (hors dépôt, à ne jamais commiter)"
    say "  Clé PUBLIQUE à autoriser dans cPanel (SSH Access → Manage SSH Keys → Import Key → Authorize) :"
    sed 's/^/    /' "${KEY_PATH}.pub"
  fi
fi

# --- 4. Secrets GitHub --------------------------------------------------------
if [ "$SET_SECRETS" -eq 1 ]; then
  step "Secrets GitHub"
  [ -n "$SSH_USER" ] && [ -n "$SSH_HOST" ] && [ -n "$SSH_PORT" ] || { echo "--set-secrets exige --user, --host et --port" >&2; exit 1; }
  [ -n "$KEY_PATH" ] || { echo "--set-secrets exige --key-file ou --generate-key" >&2; exit 1; }
  [ "$DRY" -eq 1 ] || [ -f "$KEY_PATH" ] || { echo "clé introuvable : $KEY_PATH" >&2; exit 1; }
  if [ -z "$REPO" ]; then REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"; fi
  [ -n "$REPO" ] || { echo "dépôt introuvable : passez --repo OWNER/NOM (ou connectez gh)" >&2; exit 1; }
  set_secret() { # set_secret <NOM> <valeur|@fichier>
    if [ "$DRY" -eq 1 ]; then act "poserait le secret $1 sur $REPO"; return; fi
    if [ "${2#@}" != "$2" ]; then gh secret set "$1" --repo "$REPO" < "${2#@}" >/dev/null && act "secret $1 posé"
    else printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null && act "secret $1 posé"; fi
  }
  set_secret DEPLOY_SSH_HOST "$SSH_HOST"; set_secret DEPLOY_SSH_PORT "$SSH_PORT"
  set_secret DEPLOY_SSH_USER "$SSH_USER"; set_secret DEPLOY_SSH_PRIVATE_KEY "@${KEY_PATH}"
fi

# --- 5. Conformité -------------------------------------------------------------
step "Conformité du projet"
RC=0
if [ "$FIX" -eq 1 ] && [ "$DRY" -eq 0 ]; then conform --fix; RC=$?
else conform --no-enforce; fi   # simple information, sauf avec --fix

# --- 6. Suite -------------------------------------------------------------------
step "Prochaines étapes"
cat <<N
  1. Adaptez .xsel-deploy.yml (deploy_path, health_check_url).
  2. Autorisez la clé publique dans cPanel si ce n'est pas fait, et vérifiez les 4 secrets
     (DEPLOY_SSH_HOST / PORT / USER / PRIVATE_KEY).
  3. Commitez .xsel-deploy.yml et .github/workflows/cicd.yml, poussez.
  4. Actions → CI/CD → Run workflow → action: doctor   (diagnostic du serveur, ne déploie rien)
  5. Nouvelle app ? action: provision (base + .env), puis un push sur main déploie.
  Conformité : « init.sh --check » (contrôle) · « init.sh --fix » (corrige) — le pipeline
  refuse de déployer tant qu'une erreur bloquante reste.
N
exit "$RC"
