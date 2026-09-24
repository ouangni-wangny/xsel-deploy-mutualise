#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — conform.sh
#
# Règles de conformité d'un PROJET consommateur : ce qu'il doit contenir pour que
# le pipeline fonctionne et respecte les bonnes pratiques du kit. Source unique
# des règles, utilisée par :
#   - le pipeline (policy.sh, job `plan`) : une erreur BLOQUE la CI et le déploiement ;
#   - init.sh --check / --fix : contrôle ou mise en conformité locale, par un
#     développeur ou un agent IA (non interactif, idempotent, sortie JSON possible).
#
# Chaque règle a un identifiant, un niveau (erreur | avertissement) et, quand
# c'est sûr, une correction automatique (--fix). Une règle se désactive dans le
# manifeste :  policy: { ignore: [id, …] }   (voir docs/adr/0012).
#
# Usage : conform.sh [--dir D] [--manifest M] [--fix] [--json] [--annotate] [--no-enforce]
#   --fix         applique les corrections automatiques, puis rapporte ce qui reste
#   --json        rapport JSON sur stdout (agents, outillage)
#   --annotate    format GitHub Actions (::error:: / ::warning::) + résumé du run
#   --no-enforce  les erreurs sont rapportées sans faire échouer (code 0)
# Env   : PROJECT_REPO (owner/nom, sinon déduit de `git remote`), KIT_LATEST (ex. v1.6.0)
# Codes : 0 conforme (avertissements possibles) · 1 erreur bloquante restante · 2 usage
# =============================================================================
set -uo pipefail

DIR="."; MANIFEST=".xsel-deploy.yml"; FIX=0; JSON=0; ANNOTATE=0; ENFORCE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;          --manifest) MANIFEST="$2"; shift 2 ;;
    --fix) FIX=1; shift ;;               --json) JSON=1; shift ;;
    --annotate) ANNOTATE=1; shift ;;     --no-enforce) ENFORCE=0; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "option inconnue : $1 (voir --help)" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo "jq est requis" >&2; exit 2; }
[ -d "$DIR" ] || { echo "dossier introuvable : $DIR" >&2; exit 2; }
cd "$DIR" || exit 2

KIT_REPO_NAME="xsel-deploy-mutualise"
RESULTS="$(mktemp)"; trap 'rm -f "$RESULTS"' EXIT

# --- Manifeste (facultatif : sans lui, les apps sont détectées) -------------
CFG='{}'
if [ -f "$MANIFEST" ]; then
  CFG="$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])) || {})' "$MANIFEST" 2>/dev/null)" || CFG='{}'
fi
IGNORED=" $(jq -r '(.policy.ignore // []) | join(" ")' <<<"$CFG" 2>/dev/null) "

# apps : lignes « nom<TAB>chemin<TAB>stack »
detect_stack() { # detect_stack <dossier> [stack imposée]
  local d="$1" s="${2:-auto}"
  [ "$s" != "auto" ] && { echo "$s"; return; }
  if [ -f "$d/composer.json" ] && jq -e '(.require // {}) | has("laravel/framework")' "$d/composer.json" >/dev/null 2>&1; then echo laravel
  elif [ -f "$d/package.json" ] && jq -e '((.dependencies // {}) + (.devDependencies // {})) | has("next")' "$d/package.json" >/dev/null 2>&1; then echo nextjs-passenger
  else echo inconnue; fi
}
APPS=""
if [ "$(jq -r '(.apps // {}) | length' <<<"$CFG")" -gt 0 ]; then
  while IFS=$'\t' read -r name path stack; do
    APPS="${APPS}${name}"$'\t'"${path}"$'\t'"$(detect_stack "$path" "$stack")"$'\n'
  done <<<"$(jq -r '.apps | to_entries[] | [.key, (.value.path // .key), (.value.stack // "auto")] | @tsv' <<<"$CFG")"
else
  for d in . */; do
    d="${d%/}"; case "$d" in node_modules|vendor|.git|.github) continue ;; esac
    s="$(detect_stack "$d")"; [ "$s" = inconnue ] && continue
    n="$d"; [ "$d" = "." ] && n="app"
    APPS="${APPS}${n}"$'\t'"${d}"$'\t'"${s}"$'\n'
  done
fi

# --- Enregistrement des résultats --------------------------------------------
# report <niveau> <id> <app> <message> <correction manuelle> [auto]
#   auto : nom d'une fonction fix_* ; appelée si --fix, sinon signalée comme corrigeable.
report() {
  local level="$1" id="$2" app="$3" msg="$4" hint="$5" fixer="${6:-}" status="a_corriger" auto=false
  case "$IGNORED" in *" $id "*) status="ignore" ;; esac
  if [ -n "$fixer" ]; then auto=true; fi
  if [ "$status" = "a_corriger" ] && [ "$FIX" -eq 1 ] && [ -n "$fixer" ]; then
    if "$fixer"; then status="corrige"; else hint="correction automatique impossible : ${hint}"; fi
  fi
  jq -nc --arg n "$level" --arg i "$id" --arg a "$app" --arg s "$status" --arg m "$msg" --arg h "$hint" --argjson auto "$auto" \
    '{niveau:$n, id:$i, app:$a, statut:$s, message:$m, correction:$h, auto:$auto}' >> "$RESULTS"
}
in_git() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
tracked() { in_git && [ -n "$(git ls-files -- "$1" 2>/dev/null | head -n 1)" ]; }
# perl -i : identique sous macOS et Linux (contrairement à sed -i)
edit() { perl -0pi -e "$1" "$2"; }

# =============================================================================
# Règles — projet
# =============================================================================

# dependabot : met à jour les actions épinglées (et le kit) par pull request.
if [ ! -f .github/dependabot.yml ] && [ ! -f .github/dependabot.yaml ]; then
  fix_dependabot() { mkdir -p .github && cat > .github/dependabot.yml <<'Y'
version: 2
updates:
  # Met à jour les actions épinglées par SHA (et le kit xsel-deploy-mutualise)
  # via des pull requests hebdomadaires.
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
Y
  }
  report avertissement dependabot "" ".github/dependabot.yml absent : les actions épinglées et le kit ne reçoivent pas les correctifs de sécurité" \
    "créer .github/dependabot.yml (package-ecosystem: github-actions)" fix_dependabot
fi

# Workflows qui appellent le kit : référence et transmission des secrets.
PROJECT_OWNER="${PROJECT_REPO:-}"
if [ -z "$PROJECT_OWNER" ] && in_git; then
  PROJECT_OWNER="$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')"
fi
PROJECT_OWNER="${PROJECT_OWNER%%/*}"
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  refs="$(grep -oE "[A-Za-z0-9_.-]+/${KIT_REPO_NAME}/\.github/workflows/[a-z-]+\.yml@[^ #\"']+" "$wf" | sort -u)"
  [ -n "$refs" ] || continue

  while read -r ref; do
    v="${ref##*@}"
    if [[ "$v" =~ ^[0-9a-f]{40}$ ]] || [[ "$v" =~ ^v[0-9]+$ ]]; then continue; fi
    if [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      if [ -n "${KIT_LATEST:-}" ] && [ "$v" != "$KIT_LATEST" ] \
         && [ "$(printf '%s\n%s\n' "${v#v}" "${KIT_LATEST#v}" | sort -V | tail -n 1)" = "${KIT_LATEST#v}" ]; then
        report avertissement kit-en-retard "" "${wf} : le kit est épinglé sur ${v} alors que ${KIT_LATEST} est disponible" \
          "passer à @${KIT_LATEST} (ou @${KIT_LATEST%%.*} pour suivre automatiquement)"
      fi
    else
      report avertissement kit-branche "" "${wf} : le kit est référencé par « @${v} » (une branche) : déploiements non reproductibles" \
        "utiliser un tag flottant (@v1), un tag précis (@v1.6.0) ou un SHA"
    fi
  done <<<"$refs"

  # secrets: inherit ne transmet RIEN à un workflow réutilisable d'un autre
  # propriétaire (incident vécu : secrets SSH vides au déploiement).
  kit_owner="$(head -n 1 <<<"$refs" | cut -d/ -f1)"
  if grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*$' "$wf" \
     && [ -n "$PROJECT_OWNER" ] && [ "$PROJECT_OWNER" != "$kit_owner" ]; then
    fixer=""
    if grep -q "${KIT_REPO_NAME}/\.github/workflows/pipeline\.yml@" "$wf"; then
      WF_TO_FIX="$wf"
      fix_secrets_inherit() {
        edit 's/^([ \t]*)secrets:[ \t]*inherit[ \t]*$/$1# Secrets passés un par un : « secrets: inherit » ne transmet rien à un\n$1# workflow réutilisable d\x27un autre propriétaire.\n$1secrets:\n$1  DEPLOY_SSH_HOST: \${{ secrets.DEPLOY_SSH_HOST }}\n$1  DEPLOY_SSH_PORT: \${{ secrets.DEPLOY_SSH_PORT }}\n$1  DEPLOY_SSH_USER: \${{ secrets.DEPLOY_SSH_USER }}\n$1  DEPLOY_SSH_PRIVATE_KEY: \${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}\n$1  NOTIFY_WEBHOOK_URL: \${{ secrets.NOTIFY_WEBHOOK_URL }}\n$1  TELEGRAM_BOT_TOKEN: \${{ secrets.TELEGRAM_BOT_TOKEN }}\n$1  TELEGRAM_CHAT_ID: \${{ secrets.TELEGRAM_CHAT_ID }}/m' "$WF_TO_FIX"
      }
      fixer=fix_secrets_inherit
    fi
    report erreur secrets-inherit "" "${wf} : « secrets: inherit » avec un kit d'un autre propriétaire (${kit_owner} ≠ ${PROJECT_OWNER}) : les secrets arriveraient vides" \
      "remplacer par « secrets: » et une ligne par secret (DEPLOY_SSH_HOST: \${{ secrets.DEPLOY_SSH_HOST }}, …)" "$fixer"
  fi
done

# health_check_url non TLS
while read -r app; do
  [ -n "$app" ] && report avertissement health-http "$app" "health_check_url en http:// : le monitoring TLS et les sessions sécurisées supposent https://" \
    "passer health_check_url en https://"
done <<<"$(jq -r '(.apps // {}) | to_entries[] | select((.value.health_check_url // "") | startswith("http://")) | .key' <<<"$CFG")"

# =============================================================================
# Règles — par application
# =============================================================================
while IFS=$'\t' read -r APP P STACK; do
  [ -n "$APP" ] || continue
  [ -d "$P" ] || { report erreur app-introuvable "$APP" "dossier « ${P} » introuvable" "corriger « path » dans ${MANIFEST}"; continue; }
  pre="$P/"; [ "$P" = "." ] && pre=""

  # .env versionné : secrets dans l'historique git.
  if tracked "${pre}.env"; then
    ENV_FILE="${pre}.env"
    fix_env_versionne() {
      git rm -q --cached -- "$ENV_FILE" || return 1
      grep -qxF "/.env" "${pre}.gitignore" 2>/dev/null || grep -qxF ".env" "${pre}.gitignore" 2>/dev/null || echo ".env" >> "${pre}.gitignore"
    }
    report erreur env-versionne "$APP" "${ENV_FILE} est versionné dans git : des secrets sont dans l'historique" \
      "git rm --cached ${ENV_FILE}, l'ajouter au .gitignore, puis CHANGER les mots de passe et clés concernés" fix_env_versionne
  fi

  case "$STACK" in
  laravel)
    [ -f "${pre}composer.lock" ] || report erreur composer-lock "$APP" "composer.lock absent : le build n'est pas reproductible (versions différentes à chaque déploiement)" \
      "lancer « composer install » dans ${P} et commiter composer.lock"

    # Suites PHPUnit : un dossier absent du dépôt fait échouer « php artisan test »
    # en CI (« Test directory … not found ») alors que tout passe en local.
    for x in phpunit.xml phpunit.xml.dist; do
      [ -f "${pre}${x}" ] || continue
      while read -r tdir; do
        [ -n "$tdir" ] || continue
        if { in_git && ! tracked "${pre}${tdir}"; } || { ! in_git && [ ! -d "${pre}${tdir}" ]; }; then
          TDIR="${pre}${tdir}"
          fix_phpunit_dir() { mkdir -p "$TDIR" && touch "$TDIR/.gitkeep"; }
          report erreur phpunit-dossier "$APP" "${x} déclare la suite « ${tdir} », absente du dépôt : php artisan test échouera en CI" \
            "créer ${TDIR}/.gitkeep (ou retirer la suite de ${x})" fix_phpunit_dir
        fi
      done <<<"$(perl -0ne 'if (/<testsuites>(.*?)<\/testsuites>/s) { my $b = $1; print "$1\n" while $b =~ /<directory[^>]*>\s*([^<]+?)\s*<\/directory>/g }' "${pre}${x}" 2>/dev/null)"
      break
    done

    # Moteur MySQL : les MariaDB mutualisées créent des tables MyISAM par défaut
    # (index limités à 1000 octets, ni clés étrangères ni transactions).
    DBCFG="${pre}config/database.php"
    if [ -f "$DBCFG" ] && grep -qE "'engine'[[:space:]]*=>[[:space:]]*null" "$DBCFG"; then
      fix_db_engine() { edit "s/'engine'(\s*)=>(\s*)null,/'engine'\$1=>\$2env('DB_ENGINE', 'InnoDB'), \/\/ MariaDB mutualisée : MyISAM par défaut/g" "$DBCFG"; }
      report avertissement moteur-innodb "$APP" "config/database.php laisse le moteur MySQL par défaut : en mutualisé (MariaDB) c'est souvent MyISAM, et les migrations échouent (« Specified key was too long »)" \
        "dans config/database.php : 'engine' => env('DB_ENGINE', 'InnoDB')" fix_db_engine
    fi

    # Document root : sans .htaccess racine, cPanel sert la racine du projet.
    if [ ! -f "${pre}.htaccess" ]; then
      HT="${pre}.htaccess"
      fix_htaccess() { cat > "$HT" <<'H'
# Redirige vers public/ : le document root cPanel reste la racine du projet
# (xsel-deploy-mutualise, templates/laravel.htaccess.example).
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteBase /
    RewriteRule ^(.*)$ public/$1 [L]
</IfModule>
H
      }
      report avertissement laravel-htaccess "$APP" ".htaccess racine absent : à moins d'avoir pointé le document root cPanel sur public/, le site servira la racine du projet" \
        "ajouter ${HT} (templates/laravel.htaccess.example), ou ignorer la règle si le document root est déjà public/" fix_htaccess
    fi
    ;;

  nextjs-passenger)
    [ -f "${pre}package-lock.json" ] || report erreur npm-lock "$APP" "package-lock.json absent : « npm ci » (CI et build de déploiement) échouera" \
      "lancer « npm install » dans ${P} et commiter package-lock.json"

    NC=""; for c in next.config.ts next.config.mjs next.config.js; do [ -f "${pre}${c}" ] && { NC="${pre}${c}"; break; }; done
    if [ -z "$NC" ]; then
      report erreur next-standalone "$APP" "next.config.* absent : output: \"standalone\" est requis pour Passenger" \
        "créer ${pre}next.config.ts avec « output: \"standalone\" »"
    elif grep -qE "output[\"']?[[:space:]]*:[[:space:]]*[\"']standalone[\"']" "$NC"; then
      :
    elif grep -qE "(^|[[:space:],{])output[\"']?[[:space:]]*:" "$NC"; then
      report erreur next-standalone "$APP" "${NC} définit un autre « output » : Passenger exige output: \"standalone\"" "remplacer par output: \"standalone\""
    else
      NCF="$NC"
      fix_next_standalone() {
        grep -qE '(const|let|var)[[:space:]]+[A-Za-z_]+[^=]*=[[:space:]]*\{|module\.exports[[:space:]]*=[[:space:]]*\{|export default[[:space:]]*\{' "$NCF" || return 1
        edit 's/((?:const|let|var)\s+\w+[^=\n]*=\s*\{|module\.exports\s*=\s*\{|export default\s*\{)[ \t]*\n/$1\n  \/\/ Build autonome pour Passenger (cPanel Setup Node.js App) — xsel-deploy-mutualise.\n  output: "standalone",\n/' "$NCF"
      }
      report erreur next-standalone "$APP" "${NC} sans output: \"standalone\" : le serveur ne trouvera pas server.js" \
        "ajouter « output: \"standalone\" » dans la config de ${NC}" fix_next_standalone
    fi

    if [ ! -f "${pre}.nvmrc" ] && [ ! -f "${pre}.node-version" ] \
       && [ -z "$(jq -r '.engines.node // ""' "${pre}package.json" 2>/dev/null)" ] \
       && [ -z "$(jq -r --arg a "$APP" '.apps[$a].node_version // "" | tostring' <<<"$CFG" 2>/dev/null)" ]; then
      NV="${pre}.nvmrc"
      fix_nvmrc() { echo 22 > "$NV"; }
      report avertissement version-node "$APP" "version de Node non déclarée : le build prend Node 22 par défaut, qui peut différer de l'app cPanel" \
        "ajouter ${NV} (ex. 22) et choisir la même version dans Setup Node.js App" fix_nvmrc
    fi
    ;;
  esac
done <<<"$APPS"

# =============================================================================
# Rapport
# =============================================================================
ALL="$(jq -s '.' "$RESULTS")"
ERR="$(jq '[.[] | select(.niveau=="erreur" and .statut=="a_corriger")] | length' <<<"$ALL")"
WARN="$(jq '[.[] | select(.niveau=="avertissement" and .statut=="a_corriger")] | length' <<<"$ALL")"
FIXED="$(jq '[.[] | select(.statut=="corrige")] | length' <<<"$ALL")"
FIXABLE="$(jq '[.[] | select(.statut=="a_corriger" and .auto)] | length' <<<"$ALL")"

label() { jq -r 'if .app == "" then "" else "\(.app) : " end' <<<"$1"; }
if [ "$JSON" -eq 1 ]; then
  jq -n --argjson r "$ALL" --argjson e "$ERR" --argjson w "$WARN" --argjson f "$FIXED" --argjson c "$FIXABLE" \
    '{conforme: ($e == 0), erreurs: $e, avertissements: $w, corriges: $f, corrigeables: $c, regles: $r}'
elif [ "$ANNOTATE" -eq 1 ]; then
  jq -r --argjson enf "$ENFORCE" '.[] | select(.statut=="a_corriger")
    | "::\(if .niveau=="erreur" and $enf==1 then "error" else "warning" end)::conformité [\(.id)] \(if .app=="" then "" else .app+" : " end)\(.message) → \(.correction)\(if .auto then " (corrigeable : init.sh --fix)" else "" end)"' <<<"$ALL"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$((ERR + WARN))" -gt 0 ]; then
    {
      echo "### Conformité du projet"; echo
      echo "| | Règle | App | Problème | Correction |"; echo "|---|---|---|---|---|"
      jq -r '.[] | select(.statut=="a_corriger") | "| \(if .niveau=="erreur" then "❌" else "⚠️" end) | `\(.id)` | \(.app) | \(.message) | \(.correction)\(if .auto then " — `init.sh --fix`" else "" end) |"' <<<"$ALL"
      echo; echo "Corriger automatiquement, à la racine du projet :"
      echo '```bash'
      printf 'bash %s(curl -fsSL https://raw.githubusercontent.com/ouangni-wangny/%s/v1/scripts/init.sh) --fix\n' '<' "$KIT_REPO_NAME"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
else
  echo "Conformité du projet (${KIT_REPO_NAME})"
  if [ "$(jq 'length' <<<"$ALL")" -eq 0 ]; then echo "  ✓ aucune remarque"; fi
  jq -c '.[]' <<<"$ALL" | while read -r r; do
    st="$(jq -r .statut <<<"$r")"; lv="$(jq -r .niveau <<<"$r")"
    case "$st" in
      corrige) icon="✓ corrigé" ;;
      ignore)  icon="· ignoré" ;;
      *)       [ "$lv" = erreur ] && icon="✗ erreur" || icon="⚠ avertissement" ;;
    esac
    echo "  ${icon} [$(jq -r .id <<<"$r")] $(label "$r")$(jq -r .message <<<"$r")"
    [ "$st" = a_corriger ] && echo "      → $(jq -r .correction <<<"$r")$(jq -r 'if .auto then " (corrigeable : --fix)" else "" end' <<<"$r")"
  done
  echo
  echo "Résultat : ${ERR} erreur(s) bloquante(s), ${WARN} avertissement(s), ${FIXED} corrigé(s)."
  [ "$FIXABLE" -gt 0 ] && echo "${FIXABLE} point(s) corrigeable(s) automatiquement : relancer avec --fix."
  [ "$FIXED" -gt 0 ] && echo "Relisez le diff (git diff) puis commitez les corrections."
fi

[ "$ERR" -gt 0 ] && [ "$ENFORCE" -eq 1 ] && exit 1
exit 0
