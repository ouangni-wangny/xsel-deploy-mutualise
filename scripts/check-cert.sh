#!/usr/bin/env bash
# =============================================================================
# xsel-deploy-mutualise — check-cert.sh
#
# Exécuté SUR LE RUNNER. Affiche le nombre de jours avant l'expiration du
# certificat TLS d'un hôte (entier, négatif si expiré). Code 1 (rien sur stdout)
# si le certificat est illisible/injoignable.
# Usage : check-cert.sh <hôte> [port=443]
# =============================================================================
set -uo pipefail

HOST="${1:?usage: check-cert.sh <hôte> [port]}"
PORT="${2:-443}"

END="$(echo | openssl s_client -servername "$HOST" -connect "${HOST}:${PORT}" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
[ -n "$END" ] || exit 1

# GNU date (Linux/runners) puis BSD date (macOS)
if EXP="$(date -u -d "$END" +%s 2>/dev/null)"; then :
elif EXP="$(date -u -j -f "%b %e %T %Y %Z" "$END" +%s 2>/dev/null)"; then :
else exit 1; fi

echo $(( (EXP - $(date -u +%s)) / 86400 ))
