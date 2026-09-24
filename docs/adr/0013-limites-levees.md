# ADR-0013 — Limites levées : app Node, apps imbriquées, sauvegardes, staging, rotation

## Statut
Accepté (2026-09-24). Complète ADR-0002, ADR-0011 et ADR-0012.

## Contexte
La section « limites connues » du README listait des manques devenus coûteux à
l'usage (nouveaux projets) ou déjà corrigés sans être retirés.

## Décision
1. **Retirés de la liste** : le rollback automatisé — fonctionnalité **non souhaitée**
   (ADR-0002 reste valable : pas de `releases/`/symlink ; on revient en arrière par
   un revert, avec la sauvegarde de base prise avant les migrations) ; « scripts
   serveur tirés de `main` » — corrigé depuis `v1.3.0` (`job.workflow_sha`).
2. **App Node déclarée par `provision`** (`scripts/provision-nextjs.sh`) :
   `cloudlinux-selector create` (version de Node = celle du build : `.nvmrc`,
   `node_version`, sinon 22 ; refus explicite si indisponible), sinon
   `uapi PassengerApps register_application`, sinon instructions. Domaine = hôte de
   `health_check_url`. Idempotent : une app existante n'est jamais modifiée.
   Format de `cloudlinux-selector get --json` relevé sur un serveur CloudLinux réel.
3. **`protect_paths` automatique** (`plan.sh`) : une app dont le `deploy_path` est
   sous celui d'une autre est ajoutée aux `protect_paths` de la parente (ordre
   conservé, sans doublon, affiché dans les logs).
4. **Sauvegardes PostgreSQL (`pg_dump`) et SQLite (`sqlite3 .backup`, sinon copie)**
   en plus de MySQL/MariaDB ; même rotation (5), même règle : ne bloque jamais.
5. **Staging** : second manifeste (`deploy_branch`, `environment: staging`) choisi
   par `cicd.yml` selon la branche (`init.sh --staging BRANCHE`). Garde-fou associé :
   un déploiement **manuel** n'est accepté que depuis la branche de déploiement du
   manifeste (avant : « Run workflow » depuis n'importe quelle branche partait en
   production).
6. **Rotation des secrets** : runbook `docs/runbooks/rotation-secrets.md`.

## Restent des limites (hors de portée du kit)
- Hébergeur sans SSH : décision maintenue (ADR-0001), pas de mode FTP.
- Pare-feu SSH par IP chez l'hébergeur : à lever chez lui.
