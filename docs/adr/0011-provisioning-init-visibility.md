# ADR-0011 — Provisioning par uapi, commande d'init, visibilité et garde-fous

## Statut
Accepté (2026-09-21). Complète ADR-0010.

## Contexte
Après le pipeline unique, restaient des étapes manuelles à chaque nouvelle app :
créer la base et l'utilisateur MySQL dans cPanel, écrire un `.env` de production
(l'ancien `bootstrap-app.sh` en créait un **vide**), générer la clé SSH, poser les
4 secrets. Côté exploitation : un site pouvait tomber sur un certificat expiré
sans alerte, et un échec de déploiement ne prévenait personne.

## Décision
1. **Provisioning** (`scripts/provision-laravel.sh`, action `provision-app`,
   `action: provision` du pipeline) : dossiers, base + utilisateur via
   `uapi Mysql` (préfixe cPanel et longueur maximale lus dans `get_restrictions`),
   `.env` construit depuis `.env.example` du projet avec `APP_KEY` générée,
   `APP_ENV=production`, `APP_DEBUG=false`, identifiants DB. **Idempotent et
   prudent par construction** : si `.env` existe, rien n'est créé ni modifié (un
   mot de passe existant est irrécupérable) ; les mots de passe sont générés
   sur le serveur, écrits en `chmod 600`, jamais affichés. Le job s'exécute dans
   l'Environment de production (mêmes approbations que le déploiement).
   L'enregistrement d'une app Node (Passenger) reste manuel : non validé via `uapi`.
2. **`init.sh`** : détecte les apps, écrit manifeste et workflow sans écraser,
   génère une clé ed25519 dédiée **hors du dépôt**, pose les 4 secrets par stdin
   (jamais en argument de commande). Aucune question interactive ; `--dry-run`.
3. **Monitoring TLS** (`check-cert.sh`) : avertissement < 21 jours, échec < 7 jours.
4. **Notifications** (`notify.sh`, job `notify`) : webhook Slack/Discord
   (`text` + `content`) et/ou Telegram, via secrets optionnels ; uniquement si un
   job a échoué, hors `pull_request` ; un échec d'envoi n'échoue jamais le job ;
   URL et jetons jamais affichés.
5. **Politiques** (`policy.sh`, avertissements seulement — *remplacé par
   [ADR-0012](0012-conformite-projet-bloquante.md) : conformité bloquante et corrigeable*) : `.env` versionné,
   `health_check_url` en http, kit référencé par une branche ou épinglé sur une
   version en retard. Seul un `deploy_path` dangereux (relatif ou avec `..`) est
   bloquant, car `rsync --delete` en dépend.
6. **Visibilité** : résumé de déploiement (`$GITHUB_STEP_SUMMARY`) et URL du site
   sur l'historique des déploiements.

## Conséquences
- Une app Laravel neuve se met en service sans SSH manuel : `init`, `doctor`,
  `provision`, puis push. Le premier `.env` n'est plus à composer à la main.
- `provision` suppose un cPanel avec `uapi` (validé sur le serveur LiteSpeed/CloudLinux
  de SIS) ; ailleurs il avertit et crée le `.env` sans base.
- Les notifications ne sont pas validées sur un vrai canal (tests sur récepteur local).
- La clé privée générée par `init.sh` vit dans `~/.ssh` de la machine du développeur.
