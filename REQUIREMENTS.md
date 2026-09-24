# Prérequis

Tout ce qui doit être en place **avant** d'utiliser le kit. Vérifiez chaque point :
un seul manque suffit à bloquer un déploiement, souvent tard et de façon peu
lisible. La [checklist](#checklist) en fin de page reprend l'essentiel.

## 1. Hébergement

### Obligatoire

| Élément | Pourquoi | Comment vérifier |
|---|---|---|
| **cPanel** (mutualisé ou VPS) | Chemins, PHP multi-versions, API `uapi` | Accès à l'interface cPanel |
| **Accès SSH par clé** pour le compte | Tout passe par SSH : transfert, migrations, caches, sauvegardes | cPanel → *SSH Access* existe ; la commande `ssh utilisateur@hôte -p PORT` affichée fonctionne |
| **Port SSH joignable depuis Internet, sans liste d'IP autorisées** | Les runners GitHub ont des IP qui changent à chaque run | Depuis un autre réseau : `nc -z HOTE PORT` ; en cas de doute, demander à l'hébergeur |
| **`rsync`, `bash`, `curl`, `gzip`** sur le serveur | Transfert, scripts, vérification de santé, sauvegardes | `ssh … 'command -v rsync bash curl gzip'` ; `action: doctor` le vérifie |
| **≥ 100 Mo libres** dans le compte | Transfert et sauvegardes | `action: doctor` affiche l'espace libre |

Hébergement **sans SSH** (FTP seulement) : non pris en charge. Demandez
l'activation de SSH à l'hébergeur (souvent une simple option du forfait).

### Laravel

| Élément | Détail |
|---|---|
| **PHP CLI** dans la version exigée par `composer.json` (`require.php`) | Sur CloudLinux, les versions sont dans `/opt/alt/phpXY/usr/bin/php` : le kit les trouve seul (`php_bin: auto`) |
| **Extensions PHP** exigées par `composer.lock` | Vérifiées avant transfert, activées via `selectorctl` (PHP Selector) quand il existe, sinon à activer dans cPanel |
| **Base de données** MySQL / MariaDB (ou PostgreSQL, SQLite) | `action: provision` crée base et utilisateur via `uapi Mysql` ; sinon, les créer dans cPanel → *MySQL Databases* |
| **Domaine ou sous-domaine** pointant vers `deploy_path` | cPanel → *Domains* ; le `.htaccess` racine du projet redirige vers `public/` |
| `mysqldump` / `pg_dump` / `sqlite3` | Facultatif : sans eux, pas de sauvegarde avant migration (signalé, non bloquant) |

### Next.js

| Élément | Détail |
|---|---|
| **Setup Node.js App** (Passenger) | cPanel → *Setup Node.js App*. Sur CloudLinux, `cloudlinux-selector` permet à `action: provision` de déclarer l'app |
| **Version de Node disponible** égale à celle du build (`.nvmrc`, `node_version`, sinon 22) | Visible dans *Setup Node.js App* ; `provision` refuse une version absente |
| **Domaine** servi par l'app | Le même que l'hôte de `health_check_url` |

## 2. GitHub

| Élément | Pourquoi |
|---|---|
| **Dépôt GitHub** du projet, GitHub Actions activé | Le pipeline tourne dans Actions (*Settings → Actions → General → Allow all actions* ou au moins celles de GitHub et `ouangni-wangny/xsel-deploy-mutualise`) |
| **Droit de gérer les secrets** du dépôt | Poser les 4 secrets `DEPLOY_SSH_*`. Sur un dépôt **personnel**, seul le **propriétaire** le peut (un collaborateur n'a que *write*) ; sur un dépôt d'organisation, le rôle **admin** |
| **Minutes Actions** disponibles | Dépôts privés : quota du forfait GitHub. Un déploiement Laravel + Next.js consomme environ 5 minutes |
| Accès au kit | Le kit est public : rien à configurer. Un **fork privé** du kit ne fonctionne que dans une organisation, avec partage des workflows explicitement activé |
| *(Recommandé)* Environment `production` avec relecteurs | *Settings → Environments* : approbation avant chaque déploiement ou `provision` |

## 3. Poste de travail (pour `init.sh`)

`init.sh` et les contrôles de conformité tournent en local, sous macOS ou Linux
(sous Windows : WSL).

| Outil | Version | Utilisé pour |
|---|---|---|
| `bash` | ≥ 3.2 (celui de macOS convient) | Exécuter `init.sh` |
| `git` | récent | Détecter le propriétaire du dépôt, fichiers suivis |
| `curl` | — | Récupérer `init.sh` / `conform.sh` |
| `jq` | ≥ 1.6 | Lire les `package.json` / `composer.json`, rapports |
| `ruby` | ≥ 2.6 (présent sur macOS) | Lire le manifeste YAML |
| `perl` | ≥ 5 (présent partout) | Corrections automatiques (`--fix`) |
| `ssh-keygen` | OpenSSH | `--generate-key` |
| `gh` (GitHub CLI), connecté (`gh auth login`) | ≥ 2.40 | `--set-secrets` ; lancer les workflows |

```bash
for c in bash git curl jq ruby perl ssh-keygen gh; do command -v "$c" >/dev/null && echo "ok  $c" || echo "MANQUE  $c"; done
gh auth status
```

## 4. Projet

### Toujours

- Le code sur GitHub, branche de déploiement `main` (ou celle déclarée par
  `deploy_branch`).
- **Aucun `.env` versionné** (`.env` dans `.gitignore`). Un `.env` suivi par git
  bloque le pipeline.
- **Lockfiles commités** : `composer.lock` (Laravel), `package-lock.json`
  (Next.js et assets Vite). Le kit utilise `npm` : pas de `yarn.lock` ni de
  `pnpm-lock.yaml` seuls.

### Laravel

- `laravel/framework` dans `composer.json` (détection de la stack).
- Route de santé : `/up` (présente par défaut depuis Laravel 11, dans
  `bootstrap/app.php`), à utiliser comme `health_check_url`.
- `.env.example` complet : `action: provision` s'en sert comme base du `.env` de production.
- Tests exécutables en CI : `php artisan test` passe sur une base vide (SQLite
  en mémoire, ou MySQL avec `database: mysql`). Chaque dossier déclaré dans
  `phpunit.xml` doit exister dans le dépôt.
- *(Recommandé)* `'engine' => env('DB_ENGINE', 'InnoDB')` dans
  `config/database.php` (MariaDB mutualisée souvent en MyISAM par défaut).
- Aucun fichier écrit par l'application hors de `storage/` : ce qui n'est pas
  dans le dépôt est effacé au déploiement, sauf si c'est déclaré dans `protect_paths`.

### Next.js

- `next` dans `package.json`, `output: "standalone"` dans `next.config.*`.
- Toutes les variables `NEXT_PUBLIC_*` déclarées dans `build_env` du manifeste
  (elles sont figées au build).
- `npm run build` réussit sans services locaux. Si le build appelle une API, elle
  doit être joignable en ligne ou l'appel doit tolérer une absence de réponse.
- *(Recommandé)* `.nvmrc` avec la version de Node de l'app cPanel.

## 5. Informations à réunir

| Information | Où la trouver |
|---|---|
| Utilisateur cPanel | cPanel → *SSH Access* (commande affichée), ou en-tête de cPanel |
| Hôte et **port** SSH | cPanel → *SSH Access* ; e-mail de bienvenue de l'hébergeur ; support. Ne pas supposer 22 |
| `deploy_path` de chaque app | cPanel → *Domains* → *Document Root* (sans `/public` pour Laravel), préfixé par `/home/UTILISATEUR/` |
| URL publique de chaque app | Domaine ou sous-domaine ; Laravel : `https://…/up` |
| Nom court de la base (si `provision`) | À choisir ; cPanel ajoute son préfixe (`utilisateur_`) |

## Checklist

- [ ] SSH par clé ouvert pour le compte cPanel, port connu, sans liste d'IP
- [ ] `rsync` présent sur le serveur, espace disque suffisant
- [ ] Laravel : version PHP disponible, domaine créé ; Next.js : Setup Node.js App disponible avec la bonne version
- [ ] Droit de poser les secrets du dépôt GitHub (propriétaire ou admin)
- [ ] Outils locaux installés, `gh auth status` OK
- [ ] Pas de `.env` versionné, lockfiles commités
- [ ] Laravel : `/up`, `.env.example`, tests qui passent en CI ; Next.js : `output: "standalone"`, `NEXT_PUBLIC_*` connues
- [ ] Utilisateur, hôte, port, `deploy_path` et URLs notés

Tout est coché : suivez le [démarrage rapide](README.md#démarrage-rapide). Pour
contrôler le projet à tout moment : `init.sh --check`.
