# xsel-deploy-mutualise

Source de vérité unique pour le déploiement CI/CD des projets XSEL vers un
hébergement mutualisé cPanel (SSH par clé, `Setup Node.js App` / Passenger
pour Node). Un projet consommateur appelle un workflow réutilisable de ce
repo — build, transfert, install/migrations, sauvegarde, redémarrage,
healthcheck. Rien de tout ça n'est jamais dupliqué dans un projet.

Fonctionne aussi bien pour un **monorepo** (un repo, plusieurs apps, comme
PECI : `backend/` + `frontend/`) que pour un **repo par app** (backend et
frontend chacun dans leur propre dépôt) — voir
[« Organiser un projet »](#organiser-un-projet-monorepo-ou-multi-repo).

Décisions d'architecture détaillées dans [`docs/adr/`](docs/adr/) :
[ADR-0001](docs/adr/0001-ssh-rsync-transport.md) (transport SSH),
[ADR-0002](docs/adr/0002-releases-symlink-zero-downtime.md) (déploiement
direct), [ADR-0003](docs/adr/0003-nextjs-passenger.md) (Next.js/Passenger),
[ADR-0004](docs/adr/0004-central-reusable-workflow.md) (repo central),
[ADR-0005](docs/adr/0005-ci-cd-separation.md) (CI/CD séparés).

## Comment ça marche, en une phrase

Push sur `main` → la CI du projet tourne (tests) → si elle passe, un
workflow appelant (quelques lignes, dans le projet) invoque
`deploy.yml` de ce repo → build, transfert SSH/rsync, install/migrations
côté serveur, healthcheck.

---

## Référence — `deploy.yml`

### Inputs

| Input | Requis | Défaut | Description |
|---|---|---|---|
| `stack` | **oui** | — | `laravel` ou `nextjs-passenger` |
| `deploy_path` | **oui** | — | Chemin absolu sur le serveur où le code est déployé directement (pas de `releases/`, voir ADR-0002) |
| `app_path` | non | `.` | Sous-dossier du repo appelant contenant cette app. Laisser `.` si le repo entier est l'app (cas multi-repo) |
| `health_check_url` | non | `""` | URL publique vérifiée après déploiement. Fortement recommandé — sans ça, un déploiement cassé ne se signale nulle part |
| `php_version` | non | `8.3` | Version PHP utilisée pour le **build CI** (Vite), pas forcément celle du serveur |
| `node_version` | non | `20` | Version Node utilisée pour le build CI |
| `build_frontend_assets` | non | `true` | Stack `laravel` uniquement : lance `npm run build` (Vite) avant déploiement |
| `php_bin` | non | `php` | Stack `laravel` : chemin du binaire PHP **côté serveur** (voir [CloudLinux](#cloudlinux--cagefs)) |
| `composer_bin` | non | `composer` | Stack `laravel` : chemin du binaire composer côté serveur |
| `build_env` | non | `""` | Variables exposées pendant le build, une par ligne `KEY=VALUE`. **Obligatoire** pour tout `NEXT_PUBLIC_*` (figé au build, jamais relu au runtime) |
| `protect_paths` | non | `""` | Chemins relatifs à `deploy_path` à protéger de `rsync --delete`, un par ligne — voir [Organiser un projet](#organiser-un-projet-monorepo-ou-multi-repo) |

### Secrets

Tous requis, tous liés à la connexion SSH (voir
[Onboarding, étapes 1-4](#onboarding-dun-nouveau-projet)) :

| Secret | Description |
|---|---|
| `SSH_HOST` | Hôte ou IP du serveur |
| `SSH_PORT` | Port SSH (souvent non-standard sur du mutualisé, ex. `21098`) |
| `SSH_USER` | Utilisateur cPanel |
| `SSH_PRIVATE_KEY` | Clé privée dédiée, **sans passphrase** (voir étape 3) |

### Ce que le workflow protège automatiquement (sans configuration)

Ces exclusions de `rsync --delete` sont câblées en dur, pas besoin de les
déclarer :

| Chemin | Stack | Pourquoi |
|---|---|---|
| `.deploy-scripts/` | toutes | Scripts serveur synchronisés à chaque déploiement (ADR-0004) |
| `.backups/` | toutes | Sauvegardes DB (voir [Sauvegardes](#sauvegardes)) |
| `.env`, `storage/` | `laravel` | Config et fichiers persistants — jamais dans le paquet source de toute façon |
| `.htaccess`, `tmp/` | `nextjs-passenger` | Générés par cPanel *Setup Node.js App*, pas reproductibles depuis le repo |

## Référence — `monitor.yml`

| Input | Requis | Description |
|---|---|---|
| `urls` | **oui** | URLs à vérifier, une par ligne |

Réutilisable, indépendant des déploiements — voir
[`templates/monitor-caller.example.yml`](templates/monitor-caller.example.yml).
Échoue (et GitHub envoie un email au propriétaire du repo) si une URL ne
répond pas en 2xx/3xx sous 15s, après 5 tentatives.

---

## Stacks supportées

| `stack` | Build (CI) | Serveur |
|---|---|---|
| `laravel` | `composer` (tests, via la CI du projet), `npm run build` (Vite, optionnel) | `composer install --no-dev`, sauvegarde DB, migrations, cache Laravel |
| `nextjs-passenger` | `next build` (`output: "standalone"` **requis** dans `next.config`) | Aucune install serveur — le build standalone embarque ses dépendances |

> **CloudLinux (CageFS)** — `php`/`composer` par défaut peuvent être la
> mauvaise version. Sur les hébergeurs utilisant CloudLinux (reconnaissable
> à `~/.cagefs`), le `php` du `PATH` correspond à une version différente de
> celle réellement sélectionnée pour le compte, et `composer` est souvent
> absent du `PATH` alors qu'il existe déjà. Vérifier avant le premier
> déploiement :
> ```bash
> ls -d /opt/alt/php*/usr/bin/php   # ex. /opt/alt/php83/usr/bin/php
> ls /opt/alt/php83/usr/bin/composer
> ```
> Puis renseigner `php_bin` / `composer_bin` avec les chemins trouvés.

---

## Organiser un projet : monorepo ou multi-repo

### Multi-repo (un repo par app) — cas le plus simple

Chaque repo appelle le workflow avec `app_path: .` (le défaut — pas besoin
de le préciser). `protect_paths` n'est généralement pas nécessaire, sauf
si les deux repos partagent quand même un `deploy_path` imbriqué côté
serveur (rare hors monorepo, mais possible si les deux apps sont
volontairement rangées sous le même dossier cPanel).

```yaml
with:
  stack: laravel
  deploy_path: /home/user/api.example.com
```

### Monorepo (un repo, plusieurs apps) — cas PECI

Chaque app a son propre workflow appelant dans le même repo
(`deploy-backend.yml`, `deploy-frontend.yml`), chacun avec son `app_path`
et des `paths:` de déclenchement distincts pour ne réagir qu'aux
changements qui la concernent.

**Point d'attention spécifique au monorepo** : sur cPanel, un sous-domaine
(ex. `api.example.com`) vit souvent *physiquement* dans un sous-dossier du
domaine principal (`example.com/api`) — donc dans le `deploy_path` de
l'autre app. Sans `protect_paths`, le déploiement de l'app parente
supprimerait ce sous-dossier via `rsync --delete` (incident réel, voir
[ADR-0002](docs/adr/0002-releases-symlink-zero-downtime.md)) :

```yaml
# workflow de l'app "parente" (ex. frontend, deploy_path: /home/user/example.com)
with:
  protect_paths: |
    api
```

---

## Onboarding d'un nouveau projet

### 1. Générer et autoriser une clé SSH dédiée au déploiement

cPanel → *SSH Access* → *Manage SSH Keys* → **Generate a New Key**.
- Nom : `github-actions-deploy` (ou similaire).
- **Passphrase** : certaines versions de cPanel l'exigent (min. 5
  caractères, force ≥ 80) — utiliser **Password Generator**, noter le
  mot de passe temporairement (nécessaire une seule fois, à l'étape 3).
- **Generate Key**, puis dans la liste *Private Keys*, cliquer **Manage**
  sur cette clé → **Authorize** (sans ça, la connexion SSH sera refusée
  même avec la bonne clé).

### 2. Récupérer host / port / utilisateur SSH

Écran principal **cPanel → SSH Access** (pas le sous-écran "Manage
Keys"). Exemple de commande affichée :

```
ssh moncpaneluser@monserveur.exemple.com -p 21098
```

`moncpaneluser` → `SSH_USER` · `monserveur.exemple.com` → `SSH_HOST`
(peut être une IP) · `21098` → `SSH_PORT` (souvent différent de 22 —
vérifier, ne pas supposer).

### 3. Télécharger la clé privée et retirer sa passphrase

*Manage SSH Keys* → sur la clé créée → **View/Download** → télécharger
le fichier de clé privée (pas la `.pub`), ex. `~/Downloads/github-actions-deploy`.

```bash
ssh-keygen -p -f ~/Downloads/github-actions-deploy
```

Ancienne passphrase (celle du Password Generator), puis nouvelle **vide**
(Entrée) aux deux invites suivantes — GitHub Actions ne peut pas saisir
de passphrase à la connexion.

### 4. Ajouter les 4 secrets GitHub Actions

```bash
gh secret set SSH_HOST --repo <owner>/<repo> --body "monserveur.exemple.com"
gh secret set SSH_PORT --repo <owner>/<repo> --body "21098"
gh secret set SSH_USER --repo <owner>/<repo> --body "moncpaneluser"
gh secret set SSH_PRIVATE_KEY --repo <owner>/<repo> < ~/Downloads/github-actions-deploy
```

(La dernière commande lit le fichier directement plutôt que de coller la
clé en argument — évite qu'elle traîne dans un historique de shell.)

### 5. Créer le dossier de base sur le serveur (une fois par app)

Copier [`scripts/bootstrap-app.sh`](scripts/bootstrap-app.sh) sur le
serveur, puis :
```bash
ssh <user>@<host> -p <port>
DEPLOY_PATH=/home/<user>/<app> STACK=laravel bash bootstrap-app.sh
# ou : STACK=nextjs-passenger

# Laravel uniquement : remplir le .env de prod (créé vide par le script)
nano /home/<user>/<app>/.env
```

### 6. Configurer cPanel pour servir l'app

- **Laravel** — deux options :
  - **Recommandé, sans manip cPanel** : copier
    [`templates/laravel.htaccess.example`](templates/laravel.htaccess.example)
    à la racine du projet **dans le repo** (`.htaccess`, committé — donc
    redéployé automatiquement à chaque fois ; pas `public/.htaccess`, qui
    a le sien). Fonctionne avec le document root par défaut de cPanel pour
    un nouveau (sous-)domaine.
  - **Alternative** : cPanel → *Domains* → changer le document root vers
    `<deploy_path>/public` — dans ce cas, pas besoin du `.htaccess` racine.
- **Next.js** : cPanel → *Setup Node.js App* → *Create Application*,
  Application root = `<deploy_path>`, fichier de démarrage `server.js` —
  détail dans
  [`templates/passenger-nextjs-notes.md`](templates/passenger-nextjs-notes.md).
  cPanel génère lui-même un `.htaccess` à cette étape — ne jamais le
  committer ni le modifier à la main, le workflow le protège déjà.

### 7. Ajouter le workflow appelant

Copier [`templates/caller-workflow.example.yml`](templates/caller-workflow.example.yml),
adapter selon la [référence des inputs](#inputs) ci-dessus.

### 8. Ajouter le monitoring (recommandé)

Copier [`templates/monitor-caller.example.yml`](templates/monitor-caller.example.yml)
vers `.github/workflows/monitor.yml`, adapter les URLs.

### 9. Premier déploiement

Push sur `main` → déploiement automatique. Pas de rollback automatisé
(voir ADR-0002) : en cas de problème, revert le commit fautif et repush,
ou corrige directement sur le serveur.

---

## Sauvegardes

- **Base de données** (`laravel` uniquement, MySQL/MariaDB) :
  `mysqldump` avant chaque `migrate --force`, dans
  `<deploy_path>/.backups/db/` (5 dumps compressés conservés, purge
  automatique). Ne bloque jamais le déploiement si `mysqldump` échoue ou
  est absent — c'est un filet, pas un pré-requis.
- **`.env` de prod** : n'existe que sur le serveur par défaut, aucune
  copie automatique. Recommandé, une fois rempli (étape 5) :
  ```bash
  gh secret set PROD_ENV_BACKUP --repo <owner>/<repo> < .env
  ```
  comme copie de secours — à remettre à jour manuellement si le `.env`
  change. Ce secret n'est lu par aucun workflow, c'est une sauvegarde pure.

## Qualité du kit lui-même

[`lint.yml`](.github/workflows/lint.yml) valide ce repo à chaque push :
`actionlint` sur les workflows, `shellcheck` sur les scripts serveur. Tout
projet consommateur hérite d'un changement ici dès son prochain
déploiement (voir ADR-0004) — ce lint est la seule protection avant que
ce repo ne casse tout le monde en même temps.

---

## Ce qui manque / limites connues

- **Pas de rollback automatisé.** Décision explicite (ADR-0002) en
  échange de la simplicité — pas de `releases/`/symlink. Un futur projet
  qui en a vraiment besoin peut réintroduire ce schéma (voir l'historique
  git de l'ADR et des scripts).
- **Les scripts serveur sont toujours tirés de `main`**, même si le
  projet appelant épingle ce workflow sur un tag (`@v1.0.1`) — limitation
  GitHub Actions documentée en détail dans
  [ADR-0004](docs/adr/0004-central-reusable-workflow.md).
- **Sauvegarde DB : MySQL/MariaDB uniquement.** PostgreSQL, SQLite ou
  autre → `backup_database()` s'auto-désactive proprement (pas d'échec),
  mais aucune sauvegarde n'a lieu.
- **Provisioning cPanel toujours manuel** : création de la base de
  données, réglage du document root, création de l'app Node — aucune
  automatisation via l'API cPanel (UAPI) pour l'instant, malgré son
  accessibilité prouvée en SSH (`uapi Mysql ...` fonctionne).
- **Hébergeurs sans SSH non supportés** (FTP uniquement, déploiement Git
  natif cPanel) — voir les limites de
  [ADR-0001](docs/adr/0001-ssh-rsync-transport.md).
- **`protect_paths` est manuel** : aucune détection automatique des
  `deploy_path` imbriqués entre apps d'un même projet — à identifier et
  déclarer soi-même à l'onboarding.
- **Connexions SSH limitées par l'hébergeur** : le kit n'ouvre que 2
  connexions (ADR-0006), mais un pare-feu plus strict que ça reste
  bloquant — symptôme : `Connection timed out` (pas `Permission denied`)
  dès l'étape « Configurer la clé SSH ». À faire lever côté hébergeur.
- **Pas de runbook de rotation de secrets** (clé SSH, mot de passe DB) —
  à faire à la main si compromission ou changement d'équipe.
- **Pas d'environnement de staging** — tout push sur `main` part en
  production, seule la CI (tests) fait office de filet avant déploiement.

## Statut

Conçu par ADR, validé en conditions réelles sur PECI (plusieurs incidents
rencontrés et corrigés en direct — voir les ADR et l'historique des
commits). Versions taguées :

- **`v1.0.4`** (courant) — hébergeurs sans composer : le workflow envoie
  le `composer.phar` du runner, exécuté avec `php_bin` (le préflight ne
  bloque plus sur `composer_bin` introuvable).
- **`v1.0.3`** — le préflight liste les binaires php/composer
  réellement présents sur le serveur quand `php_bin`/`composer_bin` est faux.
- **`v1.0.2`** — une seule connexion SSH par déploiement
  (`ControlMaster`), `ConnectTimeout` et retry : corrige les blocages
  « `ssh: connect … Connection timed out` » sur les hébergeurs qui limitent
  les connexions par IP ([ADR-0006](docs/adr/0006-ssh-connection-multiplexing.md)).
- **`v1.0.1`** — protège `.htaccess`/`tmp` générés par cPanel
  (`nextjs-passenger`) de `rsync --delete`.
- **`v1.0.0`** — première version stable : sauvegarde DB, `--delete`
  sécurisé (`protect_paths`), préflight, lint, monitoring périodique.

Épingler un projet consommateur sur la dernière version taguée plutôt
que sur `@main` (voir [Onboarding, étape 7](#7-ajouter-le-workflow-appelant)
et le [template](templates/caller-workflow.example.yml)).
