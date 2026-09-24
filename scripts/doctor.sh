#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — doctor.sh
#
# Exécuté SUR LE SERVEUR par le workflow doctor, APRÈS scripts/lib/common.sh
# (concaténés : `cat common.sh doctor.sh | ssh host 'bash -s'`). Rapport de
# diagnostic sans rien déployer ni modifier durablement (seule la sonde web,
# un fichier temporaire supprimé aussitôt, écrit dans public/).
#
# Variables : PHP_BIN DEPLOY_PATH HEALTH_URL STACK
# =============================================================================
set +e
set +u

section() { echo; echo "── $* ──"; }

# Moteur par défaut du serveur MySQL/MariaDB : les mutualisés sont souvent en
# MyISAM (index limités à 1000 octets → migrations en échec, ni clés étrangères
# ni transactions). Incident Univers Gravure ; règle conform.sh « moteur-innodb ».
db_engine_check() {
  local db_conn db_host db_port db_name db_user db_pass cli engine
  read_db_env "$1"
  case "$db_conn" in mysql|mariadb) ;; *) return 0 ;; esac
  cli="$(command -v mariadb || command -v mysql)" || { echo "moteur MySQL par défaut : client mysql absent, non vérifié"; return 0; }
  engine="$(MYSQL_PWD="$db_pass" "$cli" -N -B -h "${db_host:-127.0.0.1}" -P "${db_port:-3306}" -u "$db_user" "$db_name" \
    -e 'SELECT @@default_storage_engine' 2>/dev/null)" || { echo "moteur MySQL par défaut : connexion à la base impossible (identifiants du .env ?)"; return 0; }
  echo "moteur MySQL par défaut : ${engine}"
  [ "$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')" = "INNODB" ] && return 0
  if grep -qiE "'engine'[[:space:]]*=>.*InnoDB" "$(dirname "$1")/config/database.php" 2>/dev/null; then
    echo "✓ le projet impose InnoDB (config/database.php) : sans conséquence"
  else
    echo "⚠️  les tables seraient créées en ${engine} : imposer InnoDB dans config/database.php ('engine' => env('DB_ENGINE', 'InnoDB')) — init.sh --fix le fait"
  fi
}

section "Serveur"
echo "utilisateur : $(id -un) — $(uname -sr)"
if [ -d "$DEPLOY_PATH" ]; then
  echo "deploy_path : ${DEPLOY_PATH} (existe)"
  echo "espace libre : $(df -Pm "$DEPLOY_PATH" 2>/dev/null | tail -1 | awk '{print $4}') Mo"
else
  echo "deploy_path : ${DEPLOY_PATH} — ABSENT (créé au premier déploiement ; le .env est à créer à la main : scripts/bootstrap-app.sh)"
fi
command -v rsync >/dev/null && echo "rsync : $(rsync --version | head -1)" || echo "rsync : ABSENT (requis)"
command -v curl >/dev/null && echo "curl : présent" || echo "curl : ABSENT (healthcheck impossible)"

if [ "$STACK" = "laravel" ]; then
  section "PHP installés"
  # Versions >= 8.0 seulement (les anciennes ne concernent aucun projet actuel).
  for p in /opt/alt/php8*/usr/bin/php /opt/alt/php9*/usr/bin/php /opt/cpanel/ea-php8*/root/usr/bin/php /opt/cpanel/ea-php9*/root/usr/bin/php "$(command -v php 2>/dev/null)"; do
    [ -x "$p" ] && echo "  $p → $("$p" -r 'echo PHP_VERSION;' 2>/dev/null)"
  done
  echo "retenu pour le déploiement : ${PHP_BIN}"

  section "Composer / PHP Selector"
  if command -v composer >/dev/null 2>&1; then echo "composer serveur : $(command -v composer)"; else echo "composer serveur : absent (sans importance : le CI construit vendor/, composer_on_server: false)"; fi
  if command -v selectorctl >/dev/null 2>&1; then echo "selectorctl : disponible (extensions activables automatiquement)"; else echo "selectorctl : absent (extensions à activer côté hébergeur si manquantes)"; fi
  command -v uapi >/dev/null 2>&1 && echo "uapi (cPanel) : disponible" || echo "uapi (cPanel) : absent (manage_web_php sans effet)"

  if [ -f "${DEPLOY_PATH}/.env" ]; then
    section "Application (${DEPLOY_PATH})"
    echo ".env : présent"
    grep -q '^APP_KEY=.\+' "${DEPLOY_PATH}/.env" && echo "APP_KEY : défini" || echo "APP_KEY : ABSENT ou vide → php artisan key:generate"
    dbg="$(grep -m1 '^APP_DEBUG=' "${DEPLOY_PATH}/.env" | cut -d= -f2-)"
    env_="$(grep -m1 '^APP_ENV=' "${DEPLOY_PATH}/.env" | cut -d= -f2-)"
    echo "APP_ENV=${env_:-?}  APP_DEBUG=${dbg:-?}"
    case "$dbg" in true|TRUE|1) echo "⚠️  APP_DEBUG actif : à désactiver en production (fuite de configuration dans les erreurs)";; esac
    [ -f "${DEPLOY_PATH}/vendor/autoload.php" ] && echo "vendor/ : présent" || echo "vendor/ : absent (livré au déploiement)"
    [ -w "${DEPLOY_PATH}/storage" ] && echo "storage/ : inscriptible" || echo "storage/ : NON inscriptible"
    db_engine_check "${DEPLOY_PATH}/.env"
    newest="$(ls -t "${DEPLOY_PATH}"/.backups/db/*.gz 2>/dev/null | head -n 1)"
    [ -n "$newest" ] && echo "dernière sauvegarde DB : ${newest##*/}" || echo "sauvegardes DB : aucune"
  fi
fi

if [ -n "$HEALTH_URL" ]; then
  section "Site (${HEALTH_URL})"
  echo "HTTP : $(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" 2>&1)"
  if [ "$STACK" = "laravel" ] && [ -d "${DEPLOY_PATH}/public" ]; then
    web_php_evidence "$HEALTH_URL"
  fi
fi
exit 0
