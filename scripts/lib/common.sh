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

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# curl un healthcheck ; renvoie 1 si échec (le script appelant décide quoi
# faire — voir ADR-0002 : pas de rollback automatique, le déploiement est
# déjà en place au moment où ce check tourne).
health_check() {
  local url="$1"
  [ -n "$url" ] || return 0
  log "Healthcheck : ${url}"
  for _ in 1 2 3 4 5; do
    if curl -fsS -o /dev/null --max-time 10 "$url"; then
      ok "Healthcheck OK"
      return 0
    fi
    sleep 3
  done
  echo "❌ Healthcheck KO après 5 tentatives" >&2
  return 1
}

# Dump la base MySQL/MariaDB décrite par un .env Laravel avant une migration.
# N'échoue jamais le déploiement si la sauvegarde échoue (mysqldump absent,
# etc.) — la migration reste l'objectif principal, la sauvegarde est un
# filet de sécurité, pas un pré-requis bloquant.
backup_database() {
  local env_file="$1" backup_dir="$2" keep="${3:-5}"

  command -v mysqldump >/dev/null 2>&1 || { log "mysqldump indisponible, sauvegarde DB ignorée"; return 0; }
  [ -f "$env_file" ] || { log ".env introuvable, sauvegarde DB ignorée"; return 0; }

  local db_conn
  db_conn="$(grep -m1 '^DB_CONNECTION=' "$env_file" | cut -d= -f2-)"
  case "$db_conn" in
    mysql|mariadb) ;;
    *) log "DB_CONNECTION=${db_conn:-?}, sauvegarde ignorée (mysql/mariadb uniquement)"; return 0 ;;
  esac

  local db_host db_port db_name db_user db_pass
  db_host="$(grep -m1 '^DB_HOST=' "$env_file" | cut -d= -f2-)"
  db_port="$(grep -m1 '^DB_PORT=' "$env_file" | cut -d= -f2-)"
  db_name="$(grep -m1 '^DB_DATABASE=' "$env_file" | cut -d= -f2-)"
  db_user="$(grep -m1 '^DB_USERNAME=' "$env_file" | cut -d= -f2-)"
  db_pass="$(grep -m1 '^DB_PASSWORD=' "$env_file" | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/')"

  mkdir -p "$backup_dir"
  local file
  file="${backup_dir}/$(date -u +%Y%m%d%H%M%S).sql.gz"

  log "Sauvegarde DB -> ${file}"
  if MYSQL_PWD="$db_pass" mysqldump --single-transaction --quick \
      -h "${db_host:-127.0.0.1}" -P "${db_port:-3306}" -u "$db_user" "$db_name" 2>/dev/null \
      | gzip > "$file"; then
    find "${backup_dir}" -maxdepth 1 -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- | xargs -r rm -f
    ok "Sauvegarde DB effectuée (${keep} conservées)"
  else
    log "⚠️  Sauvegarde DB échouée, déploiement poursuivi quand même"
    rm -f "$file"
  fi
}
