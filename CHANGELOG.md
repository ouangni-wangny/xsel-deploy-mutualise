# Historique des versions

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/), versionnage
[sémantique](https://semver.org/lang/fr/). `@v1` suit toujours la dernière version
`1.x.y` publiée (voir [CONTRIBUTING.md](CONTRIBUTING.md#publier-une-version)).

## Non publié

## v1.7.1 — 2026-09-24

- `REQUIREMENTS.md` (prérequis), `CONTRIBUTING.md`, ce `CHANGELOG.md` ; README réécrit
  comme référence générale (manifeste complet, fonctionnement, sécurité, dépannage).
- Templates des workflows individuels mis à jour (`@v1`, exemples génériques).
- `actions/checkout` v7.0.1 dans tous les workflows (Dependabot).
- Message d'échec du healthcheck : indique comment revenir en arrière (`git revert`).

## v1.7.0 — 2026-09-24

- `action: provision` déclare l'app Node (Passenger) : `cloudlinux-selector`
  (version de Node du build), sinon `uapi PassengerApps` ; idempotent.
- `protect_paths` automatique pour une app dont le `deploy_path` est dans celui d'une autre.
- Sauvegarde avant migration : PostgreSQL (`pg_dump`) et SQLite, en plus de MySQL/MariaDB.
- Environnement de staging : manifeste par branche (`init.sh --staging BRANCHE`).
- Un déploiement manuel est refusé hors de la branche de déploiement du manifeste.
- Runbook de rotation des secrets. [ADR-0013](docs/adr/0013-limites-levees.md).

## v1.6.1 — 2026-09-24

- `doctor` : pas d'alerte MyISAM quand le projet impose déjà InnoDB.

## v1.6.0 — 2026-09-24

- **Conformité du projet bloquante** : `scripts/conform.sh`, source unique des
  règles ; le job `plan` échoue sur une erreur, avec la liste des corrections
  dans le résumé du run ; `policy: { ignore: [...] }`.
- `init.sh --check`, `--fix`, `--json` (développeurs et agents IA) ; `cicd.yml`
  généré sans `secrets: inherit`.
- `/.well-known` et `/cgi-bin` protégés au déploiement ; base de test de la CI
  prioritaire sur `phpunit.xml` ; `doctor` affiche le moteur MySQL par défaut.
  [ADR-0012](docs/adr/0012-conformite-projet-bloquante.md).

## v1.5.0 — 2026-09-21

- `action: provision` : base MySQL, utilisateur et `.env` de production via `uapi`, idempotent.
- `init.sh` : manifeste, workflow, clé SSH dédiée, secrets, en une commande.
- Surveillance du certificat TLS, notifications d'échec (webhook, Telegram),
  résumé de déploiement, politiques (avertissements), validation de `deploy_path`.
  [ADR-0011](docs/adr/0011-provisioning-init-visibility.md).

## v1.4.0 — 2026-09-21

- Point d'entrée unique `pipeline.yml` et manifeste `.xsel-deploy.yml` : CI
  standard, déploiement séquentiel des apps modifiées, diagnostic, surveillance.
- Logique en actions composites ; tag flottant `v1` géré par `release.yml`.
  [ADR-0010](docs/adr/0010-pipeline-manifest-composite-actions.md).

## v1.3.1 — 2026-09-21

- Correctif : un `php_bin` explicite était ignoré en `v1.3.0` (ne pas utiliser `v1.3.0`).

## v1.3.0 — 2026-09-21

- Convention plutôt que configuration : stack, PHP, binaire PHP, Node et
  extensions détectés ; workflow `doctor` ; kit récupéré à la version exacte du
  workflow appelé (`job.workflow_sha`) ; suite de tests en CI.
  [ADR-0009](docs/adr/0009-convention-doctor-tests.md).

## v1.2.0 — 2026-09-21

- Actions épinglées par SHA et Dependabot, `permissions: contents: read`, entrée
  `environment` pour l'approbation manuelle. [ADR-0008](docs/adr/0008-supply-chain-hardening.md).

## v1.1.2 — 2026-09-21

- Le bloc PHP du domaine est rétabli dans `.htaccess` après chaque transfert
  (le site tournait sinon avec le PHP du domaine parent).

## v1.1.1 — 2026-09-21

- Alignement de la version PHP du domaine (`manage_web_php`), diagnostic du
  healthcheck, lecture du `.env` par phpdotenv pour la sauvegarde.

## v1.1.0 — 2026-09-21

- *Build once* : `vendor/` construit en CI et livré (`composer_on_server: false`) ;
  extensions PHP déduites de `composer.lock`, vérifiées et activées avant transfert.
  [ADR-0007](docs/adr/0007-build-once-and-php-extensions.md).

## v1.0.4 — 2026-09-21

- Serveur sans composer : `composer.phar` du runner exécuté avec `php_bin`.

## v1.0.3 — 2026-09-21

- Le préflight liste les binaires PHP et composer présents quand un chemin est faux.

## v1.0.2 — 2026-09-21

- Une seule connexion SSH par déploiement (`ControlMaster`), délai et nouvelles
  tentatives. [ADR-0006](docs/adr/0006-ssh-connection-multiplexing.md).

## v1.0.1 — 2026-09-18

- `.htaccess` et `tmp/` générés par cPanel (Next.js) protégés de `rsync --delete`.

## v1.0.0 — 2026-09-18

- Première version stable : déploiement direct par SSH/rsync, sauvegarde de la
  base, `--delete` sécurisé (`protect_paths`), préflight, lint, surveillance.
