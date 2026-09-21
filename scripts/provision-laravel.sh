#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — provision-laravel.sh
#
# Exécuté SUR LE SERVEUR (via `ssh host 'bash -s' < ce-script`) par l'action
# `provision`. Prépare UNE FOIS une app Laravel fraîche : dossiers, base MySQL +
# utilisateur dédié (API cPanel `uapi Mysql`), et un `.env` de production complet
# (APP_KEY générée, APP_DEBUG=false, identifiants DB). Remplace l'ancien
# `.env` vide à remplir à la main (bootstrap-app.sh).
#
# Sûr par construction :
#   - IDEMPOTENT : si `.env` existe déjà, RIEN n'est créé ni modifié (ni base,
#     ni utilisateur, ni .env) — on ne peut pas retrouver un mot de passe existant.
#   - Les mots de passe sont générés ici, écrits seulement dans le `.env`
#     (chmod 600), et ne sont JAMAIS affichés.
#
# Variables :
#   DEPLOY_PATH        dossier de l'app (requis)
#   ENV_EXAMPLE_B64    contenu de .env.example encodé en base64 (optionnel ; sinon .env minimal)
#   APP_URL            URL publique (ex. https://api.example.com), optionnel
#   DB_NAME            nom COURT de la base à créer (le préfixe cPanel est ajouté) ; vide = pas de base
# =============================================================================
set -uo pipefail

DEPLOY_PATH="${DEPLOY_PATH:?DEPLOY_PATH requis}"
APP_URL="${APP_URL:-}"
DB_NAME="${DB_NAME:-}"
ENV_FILE="${DEPLOY_PATH}/.env"

log()  { echo "▶ $*"; }
warn() { echo "::warning::$*"; }
die()  { echo "::error::$*"; exit 1; }

mkdir -p "$DEPLOY_PATH" "$DEPLOY_PATH/.deploy-scripts" \
         "$DEPLOY_PATH/storage/app" "$DEPLOY_PATH/storage/framework/cache" \
         "$DEPLOY_PATH/storage/framework/sessions" "$DEPLOY_PATH/storage/framework/views" \
         "$DEPLOY_PATH/storage/logs" || die "impossible de créer ${DEPLOY_PATH}"
log "dossiers prêts : ${DEPLOY_PATH}"

if [ -f "$ENV_FILE" ] && [ -s "$ENV_FILE" ]; then
  log ".env existe déjà : inchangé (ni base ni utilisateur créés — provisioning ignoré)"
  exit 0
fi

# --- utilitaires -------------------------------------------------------------
random_alnum() { # random_alnum <longueur>
  local out=""
  while [ "${#out}" -lt "$1" ]; do
    out="${out}$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1" || true)"
  done
  printf '%s' "${out:0:$1}"
}

uapi_ok() { grep -q '"status":1' <<<"$1"; }   # uapi --output=json : "status":1 = succès
uapi_err() { sed -n 's/.*"errors":\["\([^"]*\)".*/\1/p' <<<"$1" | head -n 1; }

# set_kv <clé> <valeur> : pose KEY=valeur dans $TMP (remplace ou ajoute)
set_kv() {
  local k="$1" v="$2" esc
  esc="$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')"
  if grep -q "^${k}=" "$TMP"; then sed -i.bak "s|^${k}=.*|${k}=${esc}|" "$TMP" && rm -f "$TMP.bak"
  else printf '%s=%s\n' "$k" "$v" >> "$TMP"; fi
}

TMP="$(mktemp "${DEPLOY_PATH}/.env.XXXXXX")" || die "écriture impossible dans ${DEPLOY_PATH}"
chmod 600 "$TMP"
if [ -n "${ENV_EXAMPLE_B64:-}" ]; then
  printf '%s' "$ENV_EXAMPLE_B64" | base64 -d > "$TMP" 2>/dev/null || die "ENV_EXAMPLE_B64 illisible"
else
  : > "$TMP"
fi

# --- base de production ------------------------------------------------------
set_kv APP_ENV production
set_kv APP_DEBUG false
[ -n "$APP_URL" ] && set_kv APP_URL "$APP_URL"
set_kv APP_KEY "base64:$(head -c 32 /dev/urandom | base64)"

DB_SUMMARY="aucune base demandée"
if [ -n "$DB_NAME" ]; then
  if ! command -v uapi >/dev/null 2>&1; then
    warn "uapi indisponible (hors cPanel ?) : base non créée, renseignez DB_* dans ${ENV_FILE}"
    DB_SUMMARY="non créée (uapi absent)"
  else
    R="$(uapi --output=json Mysql get_restrictions 2>/dev/null)"
    PREFIX="$(sed -n 's/.*"prefix":"\([^"]*\)".*/\1/p' <<<"$R" | head -n 1)"
    MAXU="$(sed -n 's/.*"max_username_length":\([0-9]*\).*/\1/p' <<<"$R" | head -n 1)"
    MAXU="${MAXU:-16}"
    case "$DB_NAME" in "${PREFIX}"*) FULL="$DB_NAME" ;; *) FULL="${PREFIX}${DB_NAME}" ;; esac
    USERN="${FULL:0:$MAXU}"

    R="$(uapi --output=json Mysql create_database name="$FULL" 2>/dev/null)"
    if uapi_ok "$R"; then log "base créée : ${FULL}"
    elif grep -qi 'already exists\|existe' <<<"$R"; then warn "la base ${FULL} existe déjà : réutilisée"
    else die "création de la base ${FULL} refusée : $(uapi_err "$R")"; fi

    PASS="$(random_alnum 24)"
    R="$(uapi --output=json Mysql create_user name="$USERN" password="$PASS" 2>/dev/null)"
    if uapi_ok "$R"; then
      log "utilisateur créé : ${USERN}"
      R="$(uapi --output=json Mysql set_privileges_on_database user="$USERN" database="$FULL" privileges="ALL PRIVILEGES" 2>/dev/null)"
      uapi_ok "$R" || die "droits refusés sur ${FULL} : $(uapi_err "$R")"
      set_kv DB_CONNECTION mysql; set_kv DB_HOST localhost; set_kv DB_PORT 3306
      set_kv DB_DATABASE "$FULL"; set_kv DB_USERNAME "$USERN"; set_kv DB_PASSWORD "$PASS"
      DB_SUMMARY="${FULL} (utilisateur ${USERN}, mot de passe généré, écrit dans .env)"
    else
      warn "utilisateur ${USERN} non créé ($(uapi_err "$R")) : DB_PASSWORD à renseigner dans ${ENV_FILE}"
      set_kv DB_CONNECTION mysql; set_kv DB_HOST localhost; set_kv DB_PORT 3306
      set_kv DB_DATABASE "$FULL"; set_kv DB_USERNAME "$USERN"
      DB_SUMMARY="${FULL} (utilisateur existant : DB_PASSWORD à renseigner)"
    fi
    PASS=""
  fi
fi

chmod 600 "$TMP"
mv -f "$TMP" "$ENV_FILE"
log ".env créé (chmod 600) : APP_KEY générée, APP_ENV=production, APP_DEBUG=false"
log "base : ${DB_SUMMARY}"
echo "✅ Provisioning terminé pour ${DEPLOY_PATH} — le premier déploiement peut être lancé"
exit 0
