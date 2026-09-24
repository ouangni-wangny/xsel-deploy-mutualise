# scripts/lib/common.sh : healthcheck + diagnostic, sauvegarde DB
COMMON="$REPO/scripts/lib/common.sh"

start_server() { # démarre un serveur PHP de test ; $URL = base
  need_php || return $?
  mkdir -p "$T/public"
  cat > "$T/router.php" <<'P'
<?php
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$f = __DIR__ . '/public' . $p;
if (is_file($f)) { include $f; return true; }
if ($p === '/bad') { http_response_code(500); echo 'Composer detected issues'; return true; }
echo 'ok';
P
  PORT=$(( 20000 + RANDOM % 20000 )); URL="http://127.0.0.1:$PORT"
  php -S "127.0.0.1:$PORT" "$T/router.php" >/dev/null 2>&1 & SRV=$!
  trap 'kill $SRV 2>/dev/null' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$URL/up" && break; sleep 0.3; done
}

test_healthcheck_ok_renvoie_le_code_http() {
  start_server || return $?
  run bash -c "source '$COMMON'; HEALTH_RETRY_DELAY=0 health_check '$URL/up'"
  assert_eq "$RC" 0; assert_contains "$OUT" "Healthcheck OK (HTTP 200)"
}
test_healthcheck_ko_affiche_diagnostic_et_erreurs_laravel() {
  start_server || return $?
  mkdir -p "$T/logs"
  printf '[2026-09-21] production.ERROR: Class "ZipArchive" not found {"x":1}\n[2026-09-21] production.INFO: ok\n' > "$T/logs/laravel.log"
  run bash -c "source '$COMMON'; HEALTH_RETRY_DELAY=0 health_check '$URL/bad' '$T/logs'"
  assert_eq "$RC" 1
  assert_contains "$OUT" "dernier code HTTP : 500"
  assert_contains "$OUT" "Composer detected issues"
  assert_contains "$OUT" 'Class "ZipArchive" not found'
  assert_not_contains "$OUT" "production.INFO"
}
test_sonde_php_web_affiche_version_et_supprime_le_fichier() {
  start_server || return $?
  run bash -c "source '$COMMON'; DEPLOY_PATH='$T' PHP_BIN=php web_php_probe '$URL/bad'"
  assert_contains "$OUT" "PHP réellement exécuté par le serveur web : $(php -r 'echo PHP_VERSION;')"
  assert_eq "$(ls "$T/public" | wc -l | tr -d ' ')" 0
}

# --- sauvegarde DB : lecture du .env via phpdotenv (faux vendor minimal) ---
fake_dotenv() {
  mkdir -p "$1/vendor"
  cat > "$1/vendor/autoload.php" <<'P'
<?php
namespace Dotenv;
class Dotenv {
  private $d; function __construct($d) { $this->d = $d; }
  static function createArrayBacked($d) { return new self($d); }
  function safeLoad() {
    $o = [];
    foreach (file($this->d . '/.env', FILE_IGNORE_NEW_LINES) as $l) {
      if (!preg_match('/^([A-Z_]+)=(.*)$/', $l, $m)) continue;
      $v = preg_replace('/\s+#.*$/', '', $m[2]);
      $o[$m[1]] = trim($v, "'\"");
    }
    return $o;
  }
}
P
}

test_sauvegarde_transmet_le_vrai_mot_de_passe() {
  need_php || return $?
  fake_dotenv "$T"
  printf "DB_CONNECTION=mysql\nDB_HOST=localhost\nDB_PORT=3306\nDB_DATABASE=site_db\nDB_USERNAME=site_user\nDB_PASSWORD='p@ss#w\$rd\"x' # commentaire\n" > "$T/.env"
  mkstub mysqldump '[ "$1" = "--help" ] && { echo "  --no-tablespaces"; exit 0; }
    { echo "args: $*"; echo "pwd=[$MYSQL_PWD]"; } > "$STUB_OUT"; echo "-- dump"'
  export STUB_OUT="$T/out" PHP_BIN="$(command -v php)"
  run bash -c "source '$COMMON'; backup_database '$T/.env' '$T/bk' 5"
  assert_contains "$OUT" "Sauvegarde DB effectuée"
  assert_file_contains "$T/out" 'pwd=[p@ss#w$rd"x]'
  assert_file_contains "$T/out" "--no-tablespaces"
  assert_file_contains "$T/out" "-u site_user site_db"
}
test_sauvegarde_affiche_l_erreur_mysqldump() {
  need_php || return $?
  fake_dotenv "$T"; printf "DB_CONNECTION=mysql\nDB_USERNAME=u\nDB_DATABASE=d\nDB_PASSWORD=x\n" > "$T/.env"
  mkstub mysqldump '[ "$1" = "--help" ] && exit 0; echo "mysqldump: Got error: 1045: Access denied" >&2; exit 2'
  export PHP_BIN="$(command -v php)"
  run bash -c "source '$COMMON'; backup_database '$T/.env' '$T/bk' 5"
  assert_contains "$OUT" "Sauvegarde DB échouée"; assert_contains "$OUT" "Access denied"
}
test_sauvegarde_ignoree_pour_un_moteur_inconnu() {
  mkstub mysqldump 'exit 0'; printf 'DB_CONNECTION=sqlsrv\n' > "$T/.env"
  run bash -c "source '$COMMON'; PHP_BIN=/nonexistent backup_database '$T/.env' '$T/bk' 5"
  assert_contains "$OUT" "sauvegarde ignorée"
}
test_doctor_alerte_si_le_moteur_mysql_par_defaut_n_est_pas_innodb() {
  # Incident vécu : MariaDB mutualisée en MyISAM, migrations en échec.
  mkdir -p "$T/app/storage"; printf 'APP_KEY=base64:x\nDB_CONNECTION=mysql\nDB_DATABASE=site\nDB_USERNAME=u\nDB_PASSWORD=p\n' > "$T/app/.env"
  for c in mysql mariadb; do mkstub "$c" 'echo "${ENGINE:-MyISAM}"'; done
  run bash -c "cat '$COMMON' '$REPO/scripts/doctor.sh' | STACK=laravel DEPLOY_PATH='$T/app' PHP_BIN=/nonexistent bash -s"
  assert_contains "$OUT" "moteur MySQL par défaut : MyISAM"
  assert_contains "$OUT" "imposer InnoDB dans config/database.php"
  mkdir -p "$T/app/config"; echo "'engine' => env('DB_ENGINE', 'InnoDB')," > "$T/app/config/database.php"
  run bash -c "cat '$COMMON' '$REPO/scripts/doctor.sh' | STACK=laravel DEPLOY_PATH='$T/app' PHP_BIN=/nonexistent bash -s"
  assert_contains "$OUT" "le projet impose InnoDB"; assert_not_contains "$OUT" "imposer InnoDB dans"
  run bash -c "cat '$COMMON' '$REPO/scripts/doctor.sh' | ENGINE=InnoDB STACK=laravel DEPLOY_PATH='$T/app' PHP_BIN=/nonexistent bash -s"
  assert_contains "$OUT" "moteur MySQL par défaut : InnoDB"; assert_not_contains "$OUT" "imposer InnoDB"
}
test_sauvegarde_sqlite_relative_a_l_app() {
  mkdir -p "$T/app/database"
  if command -v sqlite3 >/dev/null; then sqlite3 "$T/app/database/database.sqlite" "CREATE TABLE t(x); INSERT INTO t VALUES ('contenu');"
  else printf 'SQLite format 3\000contenu' > "$T/app/database/database.sqlite"; fi
  printf 'DB_CONNECTION=sqlite\n' > "$T/app/.env"
  run bash -c "source '$COMMON'; PHP_BIN=/nonexistent backup_database '$T/app/.env' '$T/bk' 5"
  assert_contains "$OUT" "Sauvegarde DB effectuée"
  f="$(ls "$T"/bk/*.sqlite.gz)"; [ -n "$f" ] || fail "aucune sauvegarde .sqlite.gz"
  assert_contains "$(gzip -dc "$f" | tr -d '\000')" "SQLite format 3"
}
test_sauvegarde_sqlite_absente_est_ignoree() {
  printf 'DB_CONNECTION=sqlite\nDB_DATABASE=/nulle/part.sqlite\n' > "$T/.env"
  run bash -c "source '$COMMON'; PHP_BIN=/nonexistent backup_database '$T/.env' '$T/bk' 5"
  assert_eq "$RC" 0; assert_contains "$OUT" "base SQLite introuvable"
}
test_sauvegarde_postgresql_transmet_identifiants() {
  printf 'DB_CONNECTION=pgsql\nDB_HOST=db\nDB_PORT=5433\nDB_DATABASE=site\nDB_USERNAME=u\nDB_PASSWORD=s3cret\n' > "$T/.env"
  mkstub pg_dump '{ echo "args: $*"; echo "pwd=[$PGPASSWORD]"; } > "$STUB_OUT"; echo "-- pg dump"'
  export STUB_OUT="$T/out"
  run bash -c "source '$COMMON'; PHP_BIN=/nonexistent backup_database '$T/.env' '$T/bk' 5"
  assert_contains "$OUT" "Sauvegarde DB effectuée"
  assert_file_contains "$T/out" "-h db -p 5433 -U u site"; assert_file_contains "$T/out" "pwd=[s3cret]"
  assert_eq "$(gzip -dc "$T"/bk/*.sql.gz)" "-- pg dump"
}
test_sauvegarde_postgresql_en_echec_ne_bloque_pas() {
  printf 'DB_CONNECTION=pgsql\nDB_DATABASE=site\nDB_USERNAME=u\n' > "$T/.env"
  mkstub pg_dump 'echo "pg_dump: error: connection refused" >&2; exit 1'
  run bash -c "source '$COMMON'; PHP_BIN=/nonexistent backup_database '$T/.env' '$T/bk' 5"
  assert_eq "$RC" 0; assert_contains "$OUT" "Sauvegarde DB échouée"; assert_contains "$OUT" "pg_dump : pg_dump: error"
  [ -z "$(ls "$T"/bk 2>/dev/null)" ] || fail "fichier partiel conservé"
}
