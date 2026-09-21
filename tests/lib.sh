#!/usr/bin/env bash
# Mini-cadre de test sans dépendance (bash pur) : fonctionne à l'identique en
# local (macOS/Linux) et en CI. Chaque fonction `test_*` d'un fichier tests/*.sh
# tourne dans un sous-shell avec un dossier temporaire $T et des faux binaires
# dans $T/bin (en tête du PATH).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# mkstub <nom> <script> : crée un faux exécutable dans $T/bin
mkstub() { printf '%s\n' "#!/usr/bin/env bash" "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }

fail() { echo "    ✗ $*" >&2; return 1; }
assert_contains()     { case "$1" in *"$2"*) ;; *) fail "attendu « $2 » dans :"$'\n'"$1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "« $2 » ne devrait pas apparaître dans :"$'\n'"$1" ;; esac; }
assert_eq()           { [ "$1" = "$2" ] || fail "attendu « $2 », obtenu « $1 »"; }
assert_file_contains(){ grep -qF -- "$2" "$1" || fail "attendu « $2 » dans $1 :"$'\n'"$(cat "$1")"; }
need_php()            { command -v php >/dev/null 2>&1 || { echo "SKIP"; return 99; }; }

# run <cmd…> : exécute, capture stdout+stderr dans $OUT et le code dans $RC (sans faire échouer le test)
run() { set +e; OUT="$("$@" 2>&1)"; RC=$?; set -e; }
