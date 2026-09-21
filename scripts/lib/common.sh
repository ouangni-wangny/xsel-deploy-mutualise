#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — common.sh
#
# Fonctions partagées par les scripts de déploiement server-side. Ce fichier
# est synchronisé vers le serveur à chaque déploiement (voir ADR-0004) : ne
# jamais le dupliquer dans un projet consommateur, toujours l'éditer ici.
#
# Attend les variables d'environnement suivantes (exportées par le script
# appelant) :
#   DEPLOY_PATH     racine de l'app sur le serveur (code déployé directement dedans)
# =============================================================================
set -euo pipefail

# Dossier de ce fichier (pour retrouver read-db-env.php à côté).
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# curl un healthcheck ; renvoie 1 si échec (le script appelant décide quoi
# faire — voir ADR-0002 : pas de rollback automatique, le déploiement est
# déjà en place au moment où ce check tourne).
health_check() {
  local url="$1" log_dir="${2:-}"
  [ -n "$url" ] || return 0
  log "Healthcheck : ${url}"
  local code=""
  for _ in 1 2 3 4 5; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
    case "$code" in
      2??|3??)
        ok "Healthcheck OK (HTTP ${code})"
        return 0
        ;;
    esac
    sleep 3
  done
  echo "❌ Healthcheck KO après 5 tentatives (dernier code HTTP : ${code:-aucun})" >&2
  health_diagnose "$url" "$log_dir" >&2
  return 1
}

# Diagnostic après un healthcheck KO : début de la réponse et dernières
# erreurs applicatives Laravel (lignes ".ERROR:" seulement, tronquées — pas
# de trace complète : ces logs CI sont lisibles par les collaborateurs).
health_diagnose() {
  local url="$1" log_dir="$2" latest
  echo "--- diagnostic ---"
  echo "réponse (300 premiers caractères) :"
  curl -sS --max-time 10 "$url" 2>&1 | head -c 300 | tr -d '\r' | sed 's/^/  /' || true
  echo
  if [ -n "$log_dir" ] && [ -d "$log_dir" ]; then
    latest="$(ls -t "$log_dir"/*.log 2>/dev/null | head -n 1 || true)"
    if [ -n "$latest" ]; then
      echo "dernières erreurs applicatives (${latest##*/}) :"
      grep -h '\.ERROR:' "$latest" 2>/dev/null | tail -n 3 | cut -c1-400 | sed 's/^/  /' || true
    else
      echo "aucun fichier de log dans ${log_dir}"
    fi
  fi
  web_php_evidence "$url"
  echo "------------------"
}

# Preuves sur la version de PHP réellement servie (sans rien modifier) :
# en-têtes de réponse, directives PHP des .htaccess déployés, version choisie
# dans le PHP Selector CloudLinux et fiche cPanel (MultiPHP) du vhost.
web_php_evidence() {
  local url="$1" host
  host="${url#*://}"; host="${host%%[/:?]*}"
  echo "en-têtes de réponse :"
  curl -sSI --max-time 10 "$url" 2>/dev/null | grep -iE '^(HTTP|server|x-powered-by|x-litespeed)' | tr -d '\r' | sed 's/^/  /' || true
  if [ -n "${DEPLOY_PATH:-}" ]; then
    echo ".htaccess : directives PHP :"
    # Le dossier parent compte aussi : un sous-domaine sous public_html/ hérite
    # du .htaccess du domaine principal (handler PHP d'un autre domaine).
    grep -nHiE 'AddHandler|SetHandler|AddType.*php|php_value|suPHP|FcgidWrapper|alt-php|ea-php' \
      "${DEPLOY_PATH}/.htaccess" "${DEPLOY_PATH}/public/.htaccess" \
      "$(dirname "${DEPLOY_PATH}")/.htaccess" "$(dirname "$(dirname "${DEPLOY_PATH}")")/.htaccess" \
      2>/dev/null | cut -c1-200 | head -n 8 | sed 's/^/  /' || true
    [ -f "${DEPLOY_PATH}/.htaccess" ] || echo "  (pas de ${DEPLOY_PATH}/.htaccess)"
    web_php_probe "$url"
  fi
  if command -v selectorctl >/dev/null 2>&1; then
    echo "PHP Selector (selectorctl --user-summary) :"
    selectorctl --user-summary 2>&1 | head -n 12 | sed 's/^/  /' || true
  fi
  if command -v uapi >/dev/null 2>&1 && [ -n "$host" ]; then
    echo "cPanel MultiPHP (${host}) :"
    uapi --output=json LangPHP php_get_vhost_versions 2>/dev/null \
      | "${PHP_BIN:-php}" -r '$j = json_decode(stream_get_contents(STDIN), true);
          foreach (($j["result"]["data"] ?? []) as $v) {
            if (($v["vhost"] ?? "") === $argv[1]) {
              echo "  version=", $v["version"] ?? "?", " php_fpm=", (int) ($v["php_fpm"] ?? 0),
                   " source=", json_encode($v["phpversion_source"] ?? null), "\n";
            }
          }' "$host" 2>/dev/null || true
  fi
}

# Dump la base MySQL/MariaDB décrite par un .env Laravel avant une migration.
# N'échoue jamais le déploiement si la sauvegarde échoue (mysqldump absent,
# etc.) — la migration reste l'objectif principal, la sauvegarde est un
# filet de sécurité, pas un pré-requis bloquant.
backup_database() {
  local env_file="$1" backup_dir="$2" keep="${3:-5}"

  command -v mysqldump >/dev/null 2>&1 || { log "mysqldump indisponible, sauvegarde DB ignorée"; return 0; }
  [ -f "$env_file" ] || { log ".env introuvable, sauvegarde DB ignorée"; return 0; }

  local db_conn db_host db_port db_name db_user db_pass fields
  # Lecture via phpdotenv (fidèle au parsing de Laravel) ; repli grep/cut si
  # vendor/ ou PHP indisponible.
  if fields="$("${PHP_BIN:-php}" "${COMMON_LIB_DIR}/read-db-env.php" "$(dirname "$env_file")" 2>/dev/null)" \
      && [ "$(printf '%s\n' "$fields" | wc -l | tr -d ' ')" -eq 6 ]; then
    { read -r db_conn; read -r db_host; read -r db_port; read -r db_name; read -r db_user; read -r db_pass; } <<< "$fields"
    for v in db_conn db_host db_port db_name db_user db_pass; do
      printf -v "$v" '%s' "$(printf '%s' "${!v}" | base64 -d 2>/dev/null || true)"
    done
  else
    db_conn="$(grep -m1 '^DB_CONNECTION=' "$env_file" | cut -d= -f2-)"
    db_host="$(grep -m1 '^DB_HOST=' "$env_file" | cut -d= -f2-)"
    db_port="$(grep -m1 '^DB_PORT=' "$env_file" | cut -d= -f2-)"
    db_name="$(grep -m1 '^DB_DATABASE=' "$env_file" | cut -d= -f2-)"
    db_user="$(grep -m1 '^DB_USERNAME=' "$env_file" | cut -d= -f2-)"
    db_pass="$(grep -m1 '^DB_PASSWORD=' "$env_file" | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/')"
  fi
  case "$db_conn" in
    mysql|mariadb) ;;
    *) log "DB_CONNECTION=${db_conn:-?}, sauvegarde ignorée (mysql/mariadb uniquement)"; return 0 ;;
  esac

  mkdir -p "$backup_dir"
  local file
  file="${backup_dir}/$(date -u +%Y%m%d%H%M%S).sql.gz"

  log "Sauvegarde DB -> ${file}"
  # MySQL 8 exige le privilège PROCESS pour les tablespaces : rarement accordé
  # en mutualisé, et inutile pour une sauvegarde applicative.
  local extra=() err
  mysqldump --help 2>/dev/null | grep -q -- '--no-tablespaces' && extra+=(--no-tablespaces)
  err="$(mktemp)"
  if MYSQL_PWD="$db_pass" mysqldump --single-transaction --quick "${extra[@]}" \
      -h "${db_host:-127.0.0.1}" -P "${db_port:-3306}" -u "$db_user" "$db_name" 2>"$err" \
      | gzip > "$file"; then
    find "${backup_dir}" -maxdepth 1 -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- | xargs -r rm -f
    ok "Sauvegarde DB effectuée (${keep} conservées)"
  else
    log "⚠️  Sauvegarde DB échouée, déploiement poursuivi quand même"
    [ -s "$err" ] && head -n 3 "$err" | cut -c1-300 | sed 's/^/    mysqldump : /'
    rm -f "$file"
  fi
  rm -f "$err"
}

# Sonde : la version de PHP réellement exécutée par le serveur web. Composer
# masque « You are running X » dans sa page d'erreur web, et le PHP CLI peut
# différer du PHP web. Crée un fichier public/ au nom aléatoire qui n'affiche
# que PHP_VERSION et le SAPI, l'appelle depuis le serveur, puis le supprime
# aussitôt (uniquement appelé sur healthcheck KO).
web_php_probe() {
  local url="$1" base name file out
  base="${url%%://*}://$(printf '%s' "${url#*://}" | cut -d/ -f1)"
  name="kit-probe-$(date +%s)-${RANDOM}${RANDOM}.php"
  file="${DEPLOY_PATH}/public/${name}"
  [ -d "${DEPLOY_PATH}/public" ] || return 0
  printf '<?php echo PHP_VERSION, " ", PHP_SAPI;' > "$file" 2>/dev/null || return 0
  out="$(curl -sS --max-time 10 "${base}/${name}" 2>&1 | head -c 120 | tr -d '\r' || true)"
  rm -f "$file"
  echo "PHP réellement exécuté par le serveur web : ${out:-aucune réponse}"
}
