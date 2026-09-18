# xsel-deploy-mutualise

Source de vérité unique pour le déploiement CI/CD des projets XSEL vers un
hébergement mutualisé cPanel (SSH par clé + `Setup Node.js App` /
Passenger pour Node). Un projet consommateur n'a qu'à appeler le workflow
réutilisable de ce repo — la logique de déploiement (build, transfert,
install/migrations, redémarrage) vit ici et nulle part ailleurs.
Déploiement direct : chaque push écrase le code en place (pas de
releases/rollback automatisé — voir ADR-0002).

Voir les décisions d'architecture dans [`docs/adr/`](docs/adr/) :

- [ADR-0001](docs/adr/0001-ssh-rsync-transport.md) — transport SSH + rsync/scp
- [ADR-0002](docs/adr/0002-releases-symlink-zero-downtime.md) — déploiement direct (pas de releases/symlink)
- [ADR-0003](docs/adr/0003-nextjs-passenger.md) — Next.js via cPanel Passenger
- [ADR-0004](docs/adr/0004-central-reusable-workflow.md) — repo central, workflow réutilisable
- [ADR-0005](docs/adr/0005-ci-cd-separation.md) — séparation CI / CD

## Stacks supportées

| `stack`            | Build (CI)                          | Serveur                                  |
|---------------------|---------------------------------------|---------------------------------------------|
| `laravel`             | `composer` (tests, via CI du projet), `npm run build` (Vite, optionnel) | `composer install --no-dev`, migrations, cache Laravel |
| `nextjs-passenger`      | `next build` (`output: "standalone"` requis) | Aucune install serveur — le build standalone embarque ses dépendances |

> **CloudLinux (CageFS) — `php`/`composer` par défaut peuvent être la
> mauvaise version.** Sur les hébergeurs utilisant CloudLinux (reconnaissable
> à `~/.cagefs`), le `php` du `PATH` correspond à une version différente de
> celle réellement sélectionnée pour le compte, et `composer` est souvent
> absent du `PATH` alors qu'il existe déjà. Vérifier avant le premier
> déploiement :
> ```bash
> ls -d /opt/alt/php*/usr/bin/php   # ex. /opt/alt/php83/usr/bin/php
> ls /opt/alt/php83/usr/bin/composer
> ```
> Puis renseigner `php_bin` / `composer_bin` dans le workflow appelant (voir
> `templates/caller-workflow.example.yml`) avec les chemins trouvés.

## Onboarding d'un nouveau projet

### 1. Générer et autoriser une clé SSH dédiée au déploiement

cPanel → *SSH Access* → *Manage SSH Keys* → **Generate a New Key**.
- Nom : `github-actions-deploy` (ou similaire).
- **Passphrase** : ce formulaire l'exige (min. 5 caractères, force ≥ 80) —
  impossible de la laisser vide ici, contrairement à d'autres versions de
  cPanel. Utiliser **Password Generator** pour en remplir une, la noter
  temporairement (nécessaire une seule fois, à l'étape 3).
- **Generate Key**, puis dans la liste *Private Keys*, cliquer **Manage**
  sur cette clé → **Authorize** (sans ça, la connexion SSH sera refusée
  même avec la bonne clé).

### 2. Récupérer host / port / utilisateur SSH

Retour à l'écran principal **cPanel → SSH Access** (pas le sous-écran
"Manage Keys"). Il affiche un exemple de commande de connexion, du type :

```
ssh moncpaneluser@monserveur.exemple.com -p 21098
```

- `moncpaneluser` → `DEPLOY_SSH_USER`
- `monserveur.exemple.com` → `DEPLOY_SSH_HOST` (peut aussi être une IP)
- `21098` → `DEPLOY_SSH_PORT` (souvent différent de 22 sur du mutualisé —
  bien vérifier, ne pas supposer 22)

### 3. Télécharger la clé privée et retirer sa passphrase

Toujours dans *Manage SSH Keys*, sur la clé créée : **View/Download** →
télécharger le fichier de clé privée (pas la `.pub`) quelque part sur ta
machine, ex. `~/Downloads/github-actions-deploy`.

GitHub Actions ne peut pas saisir de passphrase à la connexion : il faut
la retirer localement (la clé reste chiffrée au repos côté GitHub une fois
stockée en secret, donc ce n'est pas une perte de protection pour cet
usage) :

```bash
ssh-keygen -p -f ~/Downloads/github-actions-deploy
```

Saisir l'ancienne passphrase (celle du Password Generator à l'étape 1),
puis laisser la nouvelle **vide** (Entrée) aux deux invites suivantes.

### 4. Ajouter les 4 secrets GitHub Actions

Dans le repo du projet consommateur (ex. `ouangni-wangny/peci`) → *Settings* →
*Secrets and variables* → *Actions* → *New repository secret* — ou en
ligne de commande avec le [GitHub CLI](https://cli.github.com/), une fois
les valeurs des étapes 2 et 3 en main :

```bash
gh secret set DEPLOY_SSH_HOST --repo <owner>/<repo> --body "monserveur.exemple.com"
gh secret set DEPLOY_SSH_PORT --repo <owner>/<repo> --body "21098"
gh secret set DEPLOY_SSH_USER --repo <owner>/<repo> --body "moncpaneluser"
gh secret set DEPLOY_SSH_PRIVATE_KEY --repo <owner>/<repo> < ~/Downloads/github-actions-deploy
```

La dernière commande lit le fichier directement (`<`) plutôt que de coller
le contenu de la clé en argument — évite qu'elle traîne dans l'historique
du shell ou d'une conversation.

### 5. Créer le dossier de base sur le serveur (une fois par app)

Copier [`scripts/bootstrap-app.sh`](scripts/bootstrap-app.sh) sur le
serveur (`scp` ou coller son contenu dans un fichier via `nano`), puis :
```bash
ssh <user>@<host> -p <port>
DEPLOY_PATH=/home/<user>/<app> STACK=laravel bash bootstrap-app.sh
# ou pour le frontend :
DEPLOY_PATH=/home/<user>/<app> STACK=nextjs-passenger bash bootstrap-app.sh

# Laravel uniquement : remplir le .env de prod (créé vide par le script)
nano /home/<user>/<app>/.env
```

### 6. Configurer cPanel pour servir l'app

- **Laravel** : cPanel → *Domains* → document root du (sous-)domaine sur
  `<deploy_path>/public`.
- **Next.js** : cPanel → *Setup Node.js App* → *Create Application*,
  fichier de démarrage `server.js` — détail dans
  [`templates/passenger-nextjs-notes.md`](templates/passenger-nextjs-notes.md).

### 7. Ajouter le workflow appelant

Copier [`templates/caller-workflow.example.yml`](templates/caller-workflow.example.yml)
dans `.github/workflows/` du projet, adapter `stack` / `app_path` /
`deploy_path` / `health_check_url`.

Si le `deploy_path` d'une autre app de ce même projet est un sous-dossier
de celui-ci (cas standard cPanel : un sous-domaine `api.example.com` qui
vit physiquement dans `example.com/api`), ajouter `protect_paths` pour
éviter que `rsync --delete` ne l'efface au déploiement de l'app parente :
```yaml
protect_paths: |
  api
```

### 8. Ajouter le monitoring (optionnel mais recommandé)

Copier [`templates/monitor-caller.example.yml`](templates/monitor-caller.example.yml)
dans `.github/workflows/monitor.yml` du projet, adapter les URLs. Tourne
indépendamment des déploiements (cron toutes les 15 min) — détecte une
panne qui n'a rien à voir avec un push (serveur down, certificat expiré,
modification manuelle cassée). GitHub envoie un email au propriétaire du
repo si ce workflow échoue, sans configuration supplémentaire.

### 9. Premier déploiement

Push sur `main` → déploiement automatique. En cas de problème après coup,
pas de rollback automatisé (voir ADR-0002) : revert le commit fautif sur
GitHub et repush, ou corrige directement sur le serveur.

## Sauvegardes

- **Base de données** : `deploy-laravel.sh` fait un `mysqldump` avant
  chaque `migrate --force`, dans `<deploy_path>/.backups/db/` (5 dumps
  compressés conservés, purge automatique des plus anciens). Ne bloque
  jamais le déploiement si `mysqldump` échoue ou est absent.
- **`.env` de prod** : n'existe que sur le serveur par défaut — aucune
  copie automatique. Recommandé : après l'avoir rempli (étape 5),
  sauvegarder son contenu comme secret GitHub du projet consommateur
  (`gh secret set PROD_ENV_BACKUP --repo <owner>/<repo> < .env`) comme
  copie de secours en cas de perte du fichier serveur — à remettre à jour
  manuellement si le `.env` change.

## Qualité du kit lui-même

[`lint.yml`](.github/workflows/lint.yml) valide ce repo à chaque push :
`actionlint` sur les workflows (aurait attrapé un input retiré mais
encore référencé ailleurs), `shellcheck` sur les scripts serveur. Un
projet consommateur qui pointe sur `@main` hérite de tout changement
ici dès son prochain déploiement (voir ADR-0004) — ce lint est donc la
seule protection avant que ce repo ne casse tout le monde en même temps.

## Statut

Conçu et validé (ADR) avec PECI comme premier projet de référence, et
éprouvé en déploiement réel (plusieurs incidents rencontrés et corrigés —
voir l'historique des ADR et des commits). À tagger en `v1.0.0` une fois
stabilisé sur quelques semaines d'usage sans incident.
