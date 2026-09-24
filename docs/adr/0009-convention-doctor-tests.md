# ADR-0009 — Convention plutôt que configuration, doctor, kit à version exacte, tests

## Statut
Accepté (2026-09-21). Lève la limite « scripts toujours tirés de `main` »
d'ADR-0004.

## Contexte
Un projet portait ~200 lignes de YAML et devait connaître des détails
d'hébergement (chemins `/opt/alt/phpXY`, version PHP web, extensions…).
Chaque problème d'intégration se diagnostiquait par essais successifs sur le
serveur de production (le déploiement d'un projet a demandé une dizaine de tags du
kit, publiés en quelques heures). Par ailleurs les scripts serveur venaient de
`main` alors que le workflow venait d'un tag : les deux pouvaient diverger.

## Décision
1. **Détection** (`scripts/detect-app.sh`, job `prepare`) : `stack` (`auto`
   par défaut), PHP minimal (`require.php`), extensions PHP (`ext-*` de
   composer.json/lock), version de Node (`.nvmrc`, `engines.node`, sinon 22).
   Un input explicite l'emporte toujours.
2. **PHP du serveur résolu** (`scripts/resolve-php.sh`, action `resolve-php`) :
   `php_bin: auto`, ordre : input `php_bin` > `php_version` > PHP cPanel du
   domaine (si >= minimum) > plus basse version installée >= minimum > `php`
   du PATH ; échec explicite si inférieur au minimum de composer.json. Le
   build CI utilise la **même** version que le serveur (parité).
3. **SSH ouvert en premier** (action composite `ssh-setup`, ADR-0006) :
   échec rapide, et le PHP du serveur est connu avant le build.
4. **Workflow `doctor`** (lancement manuel, ne déploie rien) : SSH, PHP
   installés, extensions, composer/selectorctl/uapi, PHP web réellement servi,
   `.env` / `APP_DEBUG` / sauvegardes, puis bloc `with:` suggéré + résumé du
   run. Modes `CHECK_ONLY` des scripts d'extensions et de PHP web.
5. **Kit à la version exacte du workflow** : `actions/checkout` avec
   `job.workflow_repository` / `job.workflow_sha` (contextes documentés de
   GitHub, réservés aux workflows réutilisables). Workflow, scripts et actions
   ne peuvent plus diverger. `actionlint` ne connaît pas encore ces propriétés :
   exception ciblée dans `.github/actionlint.yaml`.
6. **Tests** (`tests/`, bash pur, sans dépendance, exécutés par `lint.yml`) :
   faux `uapi`, `selectorctl`, `mysqldump`, serveur PHP local. Leur première
   exécution a révélé deux bugs de `common.sh` (voir README v1.3.0).

## Conséquences
- Le minimum d'un appelant : `app_path`, `deploy_path`, `health_check_url`.
- Changement de défauts (minor, mais visible) : `stack` `auto`, `php_version`
  vide, `php_bin` `auto`, `node_version` vide (détectée, sinon 22 au lieu de 20).
  Les projets qui fixent ces valeurs ne changent pas.
- Le workflow dépend de `job.workflow_sha` : indisponible sur GitHub
  Enterprise Server.
- Hors périmètre : releases avec bascule de lien symbolique et rollback
  (ADR-0002).
