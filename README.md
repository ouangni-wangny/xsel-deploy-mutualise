# xsel-deploy-mutualise

Kit CI/CD réutilisable pour déployer des applications **Laravel** et **Next.js**
sur un **hébergement mutualisé cPanel**, depuis GitHub Actions, par SSH.

Un projet ne porte que **deux fichiers** : un workflow d'appel de quelques lignes
et un manifeste qui décrit ses applications. Toute la logique vit ici : tests,
build, transfert, migrations, sauvegarde de la base, redémarrage, vérification
de santé, surveillance. Une correction apportée au kit profite à tous les projets
au déploiement suivant.

- **Monorepo ou dépôt par application** : `backend/` + `frontend/` dans un même
  dépôt, ou un dépôt par app, ou une app à la racine.
- **Convention plutôt que configuration** : stack, versions de PHP et de Node,
  binaire PHP du serveur et extensions PHP sont détectés.
- **Conformité vérifiée** : le pipeline refuse de déployer un projet qui ne
  respecte pas les règles du kit, et `init.sh --fix` corrige ce qui peut l'être.
- **Sûr par défaut** : actions épinglées par SHA, jeton GitHub en lecture seule,
  clé SSH dédiée, sauvegarde avant migration, dossiers sensibles jamais effacés.

> **Avant de commencer** : lisez [`REQUIREMENTS.md`](REQUIREMENTS.md). Hébergement
> avec accès SSH par clé, outils locaux, état du projet : sans ces prérequis, le
> kit ne peut pas fonctionner.

## Sommaire

- [Démarrage rapide](#démarrage-rapide)
- [Comment ça marche](#comment-ça-marche)
- [Le manifeste `.xsel-deploy.yml`](#le-manifeste-xsel-deployyml)
- [Le workflow d'appel `cicd.yml`](#le-workflow-dappel-cicdyml)
- [Ce que fait un déploiement](#ce-que-fait-un-déploiement)
- [Organiser un projet](#organiser-un-projet)
- [Conformité du projet](#conformité-du-projet)
- [Environnements : production et staging](#environnements--production-et-staging)
- [Sauvegardes et retour arrière](#sauvegardes-et-retour-arrière)
- [Surveillance et notifications](#surveillance-et-notifications)
- [Sécurité](#sécurité)
- [Versions du kit](#versions-du-kit)
- [Dépannage](#dépannage)
- [Limites connues](#limites-connues)
- [Documentation complémentaire](#documentation-complémentaire)

---

## Démarrage rapide

À la racine du projet (voir [`REQUIREMENTS.md`](REQUIREMENTS.md) pour les outils) :

```bash
K=https://raw.githubusercontent.com/ouangni-wangny/xsel-deploy-mutualise/v1/scripts/init.sh
bash <(curl -fsSL "$K") --user UTILISATEUR_CPANEL --host HOTE_SSH --port PORT_SSH \
     --generate-key --set-secrets --fix
```

`init.sh` ne pose aucune question. Il :

1. détecte les applications (Laravel : `laravel/framework` dans `composer.json` ;
   Next.js : `next` dans `package.json`) ;
2. écrit `.xsel-deploy.yml` et `.github/workflows/cicd.yml` sans rien écraser
   (`--force` pour écraser) ;
3. génère une clé SSH ed25519 **dédiée**, hors du dépôt (`~/.ssh/xsel-deploy-<projet>`),
   et affiche la clé **publique** à autoriser dans cPanel ;
4. pose les 4 secrets GitHub avec `gh`, valeurs lues sur l'entrée standard
   (jamais en argument de commande) ;
5. met le projet en conformité (`--fix`), puis affiche les étapes suivantes.

`--dry-run` montre ce qui serait fait sans rien écrire.

Ensuite :

1. **Autoriser la clé publique** : cPanel → *SSH Access* → *Manage SSH Keys* →
   *Import Key*, puis *Manage* → **Authorize**.
2. **Adapter le manifeste** : `deploy_path` (dossier sur le serveur) et
   `health_check_url` (URL publique) de chaque app.
3. **Relire et commiter** : `git diff`, puis commit et push des fichiers générés.
4. **Diagnostiquer** : *Actions → CI/CD → Run workflow → `action: doctor`*. Rien
   n'est déployé ; le rapport vérifie SSH, PHP, extensions, `.env`, base de données.
5. **Préparer une app neuve** (optionnel) : `action: provision`. Ça crée la base
   MySQL, son utilisateur et le `.env` de production pour Laravel, et déclare
   l'app Node pour Next.js. Aucun effet sur une app déjà en place.
6. **Déployer** : un push sur `main`.

## Comment ça marche

```
push / pull request / Run workflow / cron
                 │
                 ▼
        ┌──────────────────┐   lit .xsel-deploy.yml, détecte les apps modifiées,
        │ plan             │   vérifie la conformité du projet (bloquant)
        └────────┬─────────┘
       ┌─────────┼──────────────┬──────────────┬──────────────┐
       ▼         ▼              ▼              ▼              ▼
     CI        deploy         doctor        provision      monitor
  (par app)  (une app à la   (diagnostic)  (app neuve)   (URLs + TLS)
             fois, dans l'ordre
             du manifeste)
```

| Événement | Ce qui tourne |
|---|---|
| `pull_request` | CI des apps dont les fichiers ont changé |
| `push` sur la branche de déploiement (`main` par défaut) | CI des apps modifiées, **puis** déploiement de ces apps, une à la fois, dans l'ordre du manifeste |
| `push` sur une autre branche | CI seulement (si le workflow d'appel écoute cette branche) |
| *Run workflow*, `action: deploy` | CI puis déploiement de toutes les apps (ou de la liste `apps`) ; **seulement depuis la branche de déploiement** |
| *Run workflow*, `action: doctor` | diagnostic du serveur, sans rien modifier |
| *Run workflow*, `action: provision` | préparation d'une app neuve (idempotent) |
| cron (toutes les 15 min) | disponibilité des URLs et validité des certificats TLS |

Si le manifeste ou un fichier sous `.github/` change, toutes les apps sont
concernées. La CI d'une app : Laravel → `composer install`, Pint (si `lint`),
`php artisan test` (avec un MySQL 8 éphémère si `database: mysql`) ; Next.js →
`npm ci`, `npm run lint` (si `lint`), `npm test` (si défini), `npm run build`.

## Le manifeste `.xsel-deploy.yml`

Tout ce qui est propre au projet. Modèle commenté :
[`templates/xsel-deploy.example.yml`](templates/xsel-deploy.example.yml).

```yaml
version: 1

apps:
  # L'ordre compte : les apps se déploient dans cet ordre (l'API avant le frontend).
  backend:
    deploy_path: /home/UTILISATEUR/example.com/api
    health_check_url: https://api.example.com/up
    database: mysql
    provision: { database: monapp }
  frontend:
    deploy_path: /home/UTILISATEUR/example.com
    health_check_url: https://example.com
    build_env:
      NEXT_PUBLIC_API_URL: https://api.example.com/api/v1
```

### Clés de premier niveau

| Clé | Défaut | Rôle |
|---|---|---|
| `version` | — (requis) | Toujours `1` |
| `apps` | — (requis) | Les applications, par nom. L'ordre est l'ordre de déploiement |
| `deploy_branch` | `main` | Branche dont un push déploie |
| `environment` | `production` | *Environment* GitHub des jobs `deploy` et `provision` (approbations : *Settings → Environments*) |
| `monitor` | URLs `health_check_url` | `{ urls: [...] }` : URLs surveillées par le cron |
| `policy` | — | `{ ignore: [id, ...] }` : règles de conformité à ne pas appliquer ([ADR-0012](docs/adr/0012-conformite-projet-bloquante.md)) |

### Clés d'une application

| Clé | Défaut | Rôle |
|---|---|---|
| `path` | nom de l'app | Dossier de l'app dans le dépôt (`.` pour la racine) |
| `deploy_path` | — (requis pour déployer) | Chemin **absolu** sur le serveur, sans `..`. Le code y est écrit directement |
| `health_check_url` | — | URL vérifiée après déploiement et surveillée (Laravel : `/up`). Fortement recommandée |
| `stack` | `auto` | `laravel` ou `nextjs-passenger` ; `auto` = détectée |
| `deploy` | `true` | `false` : CI seulement |
| `ci` | `standard` | `none` : pas de CI pour cette app |
| `database` | `none` | Laravel : `mysql` = conteneur MySQL 8 pour les tests |
| `lint` | `false` | `true` : Pint (Laravel) / `npm run lint` (Next.js) bloquants en CI |
| `php_version` | détectée | Laravel : version PHP du build **et** du serveur. Par défaut : PHP du domaine dans cPanel s'il convient, sinon la plus basse version installée compatible avec `composer.json` |
| `php_bin` | `auto` | Laravel : binaire PHP **du serveur**. À n'imposer qu'en cas d'ambiguïté |
| `php_extensions` | — | Laravel : extensions PHP à exiger en plus de celles de `composer.lock` (`[intl, gd]`) ; activées sur le serveur si possible |
| `manage_web_php` | `true` | Laravel : aligne la version PHP du domaine (MultiPHP) sur celle du déploiement |
| `composer_on_server` | `false` | Laravel : `false` = `vendor/` construit en CI et livré (recommandé) ; `true` = `composer install` sur le serveur |
| `composer_bin` | `composer` | Laravel, avec `composer_on_server: true` : binaire composer du serveur |
| `build_frontend_assets` | `false` | Laravel avec Blade + Vite : compile les assets (`npm run build`) avant déploiement |
| `node_version` | détectée | Version de Node : `.nvmrc`, `.node-version`, `engines.node`, sinon 22 |
| `build_env` | — | Variables du build (`NEXT_PUBLIC_*` : **obligatoire ici**, elles sont figées au build) |
| `protect_paths` | — | Chemins (relatifs à `deploy_path`) que le déploiement ne doit jamais effacer |
| `provision` | `false` | `true` ou `{ database: nom }` : l'app est préparée par `action: provision` |

Une clé inconnue produit un avertissement (faute de frappe probable).

## Le workflow d'appel `cicd.yml`

Généré par `init.sh`, modèle : [`templates/cicd-caller.example.yml`](templates/cicd-caller.example.yml).
Il ne change pratiquement jamais.

```yaml
jobs:
  pipeline:
    uses: ouangni-wangny/xsel-deploy-mutualise/.github/workflows/pipeline.yml@v1
    secrets:
      DEPLOY_SSH_HOST: ${{ secrets.DEPLOY_SSH_HOST }}
      DEPLOY_SSH_PORT: ${{ secrets.DEPLOY_SSH_PORT }}
      DEPLOY_SSH_USER: ${{ secrets.DEPLOY_SSH_USER }}
      DEPLOY_SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}
      NOTIFY_WEBHOOK_URL: ${{ secrets.NOTIFY_WEBHOOK_URL }}
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
```

Les secrets sont passés **un par un**. `secrets: inherit` ne transmet rien à un
workflow réutilisable d'un autre propriétaire : si le dépôt du projet
n'appartient pas au même compte que le kit, les secrets arriveraient vides. La
conformité le bloque.

| Secret | Requis | Contenu |
|---|---|---|
| `DEPLOY_SSH_HOST` | oui | Hôte ou IP SSH du serveur |
| `DEPLOY_SSH_PORT` | oui | Port SSH (souvent différent de 22 en mutualisé) |
| `DEPLOY_SSH_USER` | oui | Utilisateur cPanel |
| `DEPLOY_SSH_PRIVATE_KEY` | oui | Clé privée **dédiée**, sans passphrase |
| `NOTIFY_WEBHOOK_URL` | non | Webhook Slack ou Discord pour les échecs |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | non | Notifications Telegram des échecs |

Entrée du workflow réutilisable : `manifest` (défaut `.xsel-deploy.yml`), utile
pour le [staging](#environnements--production-et-staging). Lancement manuel :
`action` (`deploy`, `doctor`, `provision`) et `apps` (noms séparés par des
virgules ; vide = toutes).

## Ce que fait un déploiement

Le code est écrit **directement** dans `deploy_path` (pas de dossier `releases/`,
[ADR-0002](docs/adr/0002-releases-symlink-zero-downtime.md)), par une seule
connexion SSH partagée ([ADR-0006](docs/adr/0006-ssh-connection-multiplexing.md)).

**Laravel**

1. Sur le runner : `composer install --no-dev` (le `vendor/` est livré avec le
   code), `npm run build` si `build_frontend_assets`.
2. Préflight serveur : `rsync`, binaire PHP, espace disque. Extensions PHP
   vérifiées et activées si possible (`selectorctl`). Version PHP du domaine alignée.
3. Transfert `rsync --delete` (voir les [chemins protégés](#sécurité)).
4. Sur le serveur : `package:discover`, **sauvegarde de la base**, `migrate --force`,
   `config:cache`, `route:cache`, `view:cache`, `storage:link`.
5. Vérification de `health_check_url`. En cas d'échec, diagnostic : code HTTP
   et dernières erreurs de `storage/logs`.

**Next.js (Passenger)**

1. Sur le runner : `npm ci`, `next build` avec `build_env`. `output: "standalone"`
   est requis : le serveur n'installe rien.
2. Transfert du build autonome (`server.js`, `.next/static`, `public/`).
3. Redémarrage Passenger (`tmp/restart.txt`), puis vérification de santé.

L'app Node doit exister dans cPanel (*Setup Node.js App*, fichier de démarrage
`server.js`). `action: provision` la déclare : `cloudlinux-selector` sur
CloudLinux, sinon `uapi PassengerApps`. Les variables d'environnement serveur
(hors `NEXT_PUBLIC_*`) se règlent dans cPanel → *Setup Node.js App*. Détails :
[`templates/passenger-nextjs-notes.md`](templates/passenger-nextjs-notes.md).

**Document root Laravel** : un `.htaccess` à la racine de l'app (dans le dépôt,
[modèle](templates/laravel.htaccess.example)) redirige vers `public/`. Le
document root cPanel par défaut suffit. Autre solution : pointer le document
root sur `<deploy_path>/public`.

## Organiser un projet

| Organisation | Manifeste |
|---|---|
| Une app à la racine du dépôt | une app avec `path: .` |
| Monorepo `backend/` + `frontend/` | une app par dossier (le nom de l'app = son dossier par défaut) |
| Un dépôt par app | un manifeste par dépôt, une app avec `path: .` |

**Apps imbriquées sur le serveur.** Sur cPanel, un sous-domaine vit souvent
dans le dossier du domaine principal (`example.com/api`). Le `rsync --delete` de
l'app parente l'effacerait. Le kit le détecte et protège automatiquement toute
app dont le `deploy_path` est à l'intérieur de celui d'une autre (visible dans
les logs du job `plan`). `protect_paths` reste nécessaire pour ce qui n'est pas
une app du manifeste : dossier d'un autre dépôt, fichiers déposés à la main,
uploads écrits hors de `storage/`.

## Conformité du projet

Le kit vérifie que le projet contient ce qu'il faut pour être déployé
correctement. Une **erreur** bloque le pipeline : ni CI, ni déploiement. Le
résumé du run liste chaque problème et sa correction. Un **avertissement**
n'empêche rien.

```bash
K=https://raw.githubusercontent.com/ouangni-wangny/xsel-deploy-mutualise/v1/scripts/init.sh
bash <(curl -fsSL "$K") --check          # contrôle seul, n'écrit rien (code 1 si bloquant)
bash <(curl -fsSL "$K") --fix            # corrige ce qui peut l'être, puis : git diff, commit
bash <(curl -fsSL "$K") --fix --json     # idem, rapport JSON sur stdout (outillage, agents IA)
```

Non interactif, idempotent, codes de sortie stables (0 conforme, 1 erreur
restante, 2 usage). Le pipeline ne modifie jamais le code : les corrections se
font en local et passent par une relecture.

| Règle | Niveau | Correction auto |
|---|---|---|
| `secrets-inherit` : `secrets: inherit` vers un kit d'un autre propriétaire | erreur | oui |
| `env-versionne` : `.env` suivi par git | erreur | oui (changer les secrets reste à faire) |
| `next-standalone` : `output: "standalone"` absent | erreur | oui |
| `phpunit-dossier` : suite PHPUnit vers un dossier absent du dépôt | erreur | oui |
| `composer-lock`, `npm-lock` : lockfile absent | erreur | non |
| `app-introuvable` : `path` du manifeste inexistant | erreur | non |
| `moteur-innodb` : moteur MySQL non imposé (MariaDB mutualisée souvent en MyISAM) | avertissement | oui |
| `laravel-htaccess` : `.htaccess` racine absent | avertissement | oui |
| `version-node` : version de Node non déclarée | avertissement | oui |
| `dependabot` : `.github/dependabot.yml` absent | avertissement | oui |
| `health-http` : `health_check_url` en `http://` | avertissement | non |
| `kit-branche`, `kit-en-retard` : référence du kit | avertissement | non |

Une règle se désactive explicitement, de façon visible en revue de code :
`policy: { ignore: [laravel-htaccess] }`. Pour `doctor` et `provision`, les
erreurs sont signalées sans bloquer.

## Environnements : production et staging

```bash
bash <(curl -fsSL "$K") --staging staging
```

Ça écrit `.xsel-deploy.staging.yml` (`deploy_branch: staging`,
`environment: staging`, dossiers et URLs à adapter) et un `cicd.yml` qui choisit
le manifeste selon la branche. Un push sur `staging` déploie la préproduction,
un push sur `main` la production. Chaque environnement a ses propres dossiers,
URLs, base de données (`provision`) et règles d'approbation (*Settings →
Environments* : relecteurs obligatoires, délai, branches autorisées).

Un déploiement **manuel** n'est accepté que depuis la branche de déploiement
du manifeste : « Run workflow » sur une branche de travail ne peut pas partir
en production.

## Sauvegardes et retour arrière

- **Base de données** (Laravel), avant chaque migration, dans
  `<deploy_path>/.backups/db/` (5 sauvegardes compressées conservées) :
  MySQL/MariaDB (`mysqldump`), PostgreSQL (`pg_dump`), SQLite (`sqlite3 .backup`,
  sinon copie du fichier). Un échec de sauvegarde ne bloque pas le déploiement :
  il est signalé dans le log.
- **`.env` de production** : il n'existe que sur le serveur. Gardez-en une copie
  de secours en secret GitHub (lu par aucun workflow) :
  `ssh … "cat <deploy_path>/.env" | gh secret set PROD_ENV_BACKUP --repo OWNER/REPO`.
- **Retour arrière** : `git revert` du commit fautif, puis push. Le pipeline
  redéploie la version précédente. Si une migration doit être annulée, restaurer
  la sauvegarde prise juste avant (`gunzip -c … | mysql …`).

## Surveillance et notifications

- **Cron toutes les 15 minutes** : chaque URL doit répondre en 2xx/3xx (5
  tentatives, 15 s). Le certificat TLS déclenche un avertissement à moins de 21
  jours de son expiration, et un échec à moins de 7 jours.
- **Échec d'un run** hors pull request : notification si `NOTIFY_WEBHOOK_URL` ou
  `TELEGRAM_*` sont définis. Sinon, GitHub prévient le propriétaire du dépôt par e-mail.
- **Résumé** dans chaque run (apps déployées, version, URL). L'URL du site
  apparaît dans l'historique des déploiements GitHub.

Tant qu'un site n'est pas en ligne, ne pas renseigner `health_check_url` (ou
`monitor.urls: []`) : sinon le cron échoue et alerte toutes les 15 minutes.

## Sécurité

- **Clé SSH dédiée au déploiement**, sans passphrase, autorisée seulement dans
  le compte cPanel concerné, jamais commitée. La rotation se fait pas à pas avec le
  [runbook](docs/runbooks/rotation-secrets.md).
- **Actions tierces épinglées par SHA**, mises à jour par Dependabot ; jeton
  GitHub en `contents: read` ([ADR-0008](docs/adr/0008-supply-chain-hardening.md)).
- **Secrets jamais en argument de commande** : ni visibles dans `ps`, ni dans
  les logs. Les mots de passe générés par `provision` ne sont jamais affichés.
- **Chemins jamais effacés** par `rsync --delete` : `.deploy-scripts/`,
  `.backups/`, `/.well-known` (validation des certificats), `/cgi-bin` ; Laravel :
  `.env`, `storage/`, `public/storage` ; Next.js : `.htaccess` et `tmp/` générés
  par cPanel ; plus les apps imbriquées et les `protect_paths`.
- **`deploy_path` validé** : un chemin relatif ou contenant `..` est refusé.
- **Approbation manuelle** possible avant tout déploiement ou provisioning :
  *Settings → Environments → production → Required reviewers*.
- Le kit doit rester **public** : GitHub n'autorise l'appel d'un workflow
  réutilisable d'un autre compte personnel que s'il est public. Il ne contient
  aucun secret ni aucune donnée de projet
  ([ADR-0004](docs/adr/0004-central-reusable-workflow.md)).

## Versions du kit

- `@v1` : tag **flottant**, déplacé sur chaque version `1.x.y` dont les tests ont
  passé. Les projets reçoivent les corrections sans rien modifier. Recommandé.
- `@v1.7.0` (ou un SHA) : version figée, mise à jour par Dependabot.
- Historique : [`CHANGELOG.md`](CHANGELOG.md). Un changement incompatible
  impose une nouvelle version majeure (`v2`).

## Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `Connection timed out` dès « Configurer la clé SSH » | Port SSH faux, SSH fermé, ou pare-feu de l'hébergeur filtrant les IP | Vérifier le port dans cPanel → *SSH Access* ; demander à l'hébergeur d'ouvrir SSH par clé sans liste d'IP |
| `Permission denied (publickey)` | Clé non autorisée dans cPanel, mauvais utilisateur, ou passphrase | *Manage SSH Keys* → *Authorize* ; `ssh-keygen -p -f cle` pour retirer la passphrase |
| `host key introuvable sur :` (hôte et port vides) | Secrets non transmis (`secrets: inherit` avec un autre propriétaire) ou absents | Passer les secrets un par un (`init.sh --fix`) ; vérifier *Settings → Secrets* |
| Échec au job `plan`, étape « Conformité du projet » | Règle bloquante non respectée | Lire le résumé du run ; `init.sh --fix` |
| `Test directory "…" not found` en CI | Suite PHPUnit vers un dossier non versionné | `init.sh --fix` (règle `phpunit-dossier`) |
| `Specified key was too long; max key length is 1000 bytes` | Tables créées en MyISAM | Imposer InnoDB (`init.sh --fix`, règle `moteur-innodb`) ; vider la base partiellement migrée (`php artisan db:wipe --force`) si elle est neuve |
| `.env manquant` au déploiement | App jamais préparée | `action: provision`, ou créer le `.env` à la main |
| Healthcheck en HTTP 500 après déploiement | Erreur applicative ou PHP web ≠ PHP du déploiement | Le log du job affiche les dernières erreurs Laravel ; `action: doctor` compare les versions PHP |
| Next.js : 503 / page Passenger | App Node absente ou mauvais fichier de démarrage | `action: provision` ; vérifier `server.js` dans *Setup Node.js App* |
| « déploiement manuel refusé depuis … » | Run workflow lancé hors de la branche de déploiement | Lancer depuis `main` (ou la branche du manifeste de staging) |
| Le cron échoue toutes les 15 minutes | URL surveillée hors ligne ou pas encore publiée | Corriger le site, ou retirer l'URL du manifeste tant qu'il n'est pas en ligne |

## Limites connues

- **SSH obligatoire.** Les hébergeurs qui ne proposent que le FTP ne sont pas
  pris en charge : sans SSH, ni migrations, ni caches, ni sauvegarde de base ne
  sont possibles proprement ([ADR-0001](docs/adr/0001-ssh-rsync-transport.md)).
  Demander l'activation de SSH à l'hébergeur.
- **Pare-feu SSH par IP.** Les runners GitHub ont des IP variables : un
  hébergeur qui n'ouvre SSH qu'à une liste d'IP bloque le déploiement. Le kit
  n'ouvre que 2 connexions par déploiement, mais la règle doit être levée chez
  l'hébergeur.
- **Rotation des secrets manuelle**, documentée pas à pas dans le
  [runbook](docs/runbooks/rotation-secrets.md).

## Documentation complémentaire

- [`REQUIREMENTS.md`](REQUIREMENTS.md) : prérequis (hébergement, GitHub, poste, projet).
- [`CONTRIBUTING.md`](CONTRIBUTING.md) : faire évoluer le kit (tests, règles, releases).
- [`CHANGELOG.md`](CHANGELOG.md) : historique des versions.
- [`docs/adr/`](docs/adr/) : décisions d'architecture (transport SSH, déploiement
  direct, Passenger, workflow central, pipeline et manifeste, conformité…).
- [`docs/runbooks/`](docs/runbooks/) : procédures d'exploitation.
- [`templates/`](templates/) : fichiers à copier dans un projet.

### Workflows individuels (usage avancé)

`deploy.yml`, `doctor.yml` et `monitor.yml` restent appelables séparément pour
des cas particuliers ; ils partagent la logique du pipeline (actions composites
`deploy-app`, `doctor-app`). Leurs secrets s'appellent `SSH_HOST`, `SSH_PORT`,
`SSH_USER`, `SSH_PRIVATE_KEY`. Exemples :
[`caller-workflow`](templates/caller-workflow.example.yml),
[`doctor-caller`](templates/doctor-caller.example.yml),
[`monitor-caller`](templates/monitor-caller.example.yml). Pour un nouveau
projet, préférez toujours le pipeline (`cicd.yml` + manifeste).
