# Runbook — rotation des secrets

**Quand :** fuite ou soupçon de fuite (clé partagée par messagerie, poste perdu,
dépôt rendu public), départ d'une personne qui y avait accès, ou une fois par an.

Tout se fait **sans interruption du site**, dans cet ordre : créer le nouveau
secret → le poser → vérifier → **seulement ensuite** révoquer l'ancien.

Variables utilisées ci-dessous :

```bash
R=owner/depot            # dépôt GitHub du projet
U=utilisateur-cpanel     # DEPLOY_SSH_USER
H=serveur.example.com    # DEPLOY_SSH_HOST
P=21098                  # DEPLOY_SSH_PORT
APP=/home/$U/chemin/app  # deploy_path de l'app Laravel concernée
```

## 1. Clé SSH de déploiement (`DEPLOY_SSH_PRIVATE_KEY`)

1. Générer une clé **dédiée**, hors du dépôt, sans passphrase :
   ```bash
   ssh-keygen -t ed25519 -N "" -C "github-actions-deploy@$(date +%Y%m)" -f ~/.ssh/xsel-deploy-$(basename "$R")-$(date +%Y%m)
   ```
2. cPanel → *SSH Access* → *Manage SSH Keys* → **Import Key** : coller le contenu
   du fichier `.pub`, puis **Manage → Authorize**.
3. Poser le secret (lu depuis le fichier, jamais passé en argument) :
   ```bash
   gh secret set DEPLOY_SSH_PRIVATE_KEY --repo "$R" < ~/.ssh/xsel-deploy-$(basename "$R")-$(date +%Y%m)
   ```
   Les dépôts d'autres propriétaires qui partagent la même clé (même compte cPanel)
   doivent être mis à jour **aussi** ; sinon leurs déploiements échoueront à l'étape 5.
4. Vérifier : *Actions → CI/CD → Run workflow → `action: doctor`* doit passer.
5. Révoquer l'ancienne clé : cPanel → *Manage SSH Keys* → **Deauthorize**, puis
   **Delete** (publique et privée). Supprimer la copie locale de l'ancienne clé.

## 2. Mot de passe MySQL de l'app (`DB_PASSWORD` du `.env`)

1. Générer un mot de passe **sans l'afficher dans l'historique** et le poser sur le
   serveur, dans la base cPanel **et** le `.env`, en une seule session SSH :
   ```bash
   ssh -p "$P" "$U@$H" "APP='$APP' bash -s" <<'SH'
   set -euo pipefail
   ENV="$APP/.env"; cp "$ENV" "$ENV.bak-$(date +%Y%m%d%H%M%S)"
   USER_DB="$(grep -m1 '^DB_USERNAME=' "$ENV" | cut -d= -f2-)"
   PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
   uapi --output=json Mysql set_password user="$USER_DB" password="$PASS" | grep -q '"status":1'
   sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$PASS|" "$ENV"
   cd "$APP" && php artisan config:cache >/dev/null
   echo "mot de passe changé pour $USER_DB"
   SH
   ```
   (Sur CloudLinux, remplacer `php` par le binaire retenu par le kit, affiché par
   `doctor`, ex. `/opt/alt/php83/usr/bin/php`.)
2. Vérifier : `curl -fsS https://…/up` et une page qui lit la base.
3. En cas d'échec : restaurer `.env.bak-*`, relancer `config:cache`, et reposer
   l'ancien mot de passe via cPanel → *MySQL Databases*.
4. Mettre à jour la copie de secours si elle existe :
   `ssh -p "$P" "$U@$H" "cat '$APP/.env'" | gh secret set PROD_ENV_BACKUP --repo "$R"`.

## 3. `APP_KEY` (Laravel)

À ne changer **que** si elle a fuité : elle chiffre les cookies, les sessions et
les données `encrypted` — la changer déconnecte tout le monde et rend illisible
ce qui a été chiffré avec l'ancienne.

1. Générer la nouvelle : `php artisan key:generate --show` (en local).
2. Dans le `.env` du serveur : mettre l'ancienne dans `APP_PREVIOUS_KEYS`
   (Laravel 11+ : déchiffrement de l'existant), la nouvelle dans `APP_KEY`, puis
   `php artisan config:cache`.
3. Rechiffrer les données concernées (commande propre au projet), puis retirer
   `APP_PREVIOUS_KEYS`.

## 4. Jetons de notification (`NOTIFY_WEBHOOK_URL`, `TELEGRAM_BOT_TOKEN`)

Régénérer le webhook (Slack / Discord : supprimer puis recréer l'intégration) ou
le jeton (Telegram : `@BotFather` → `/revoke`), puis `gh secret set …`. Un échec
d'envoi ne fait jamais échouer un run : vérifier en provoquant un échec sur une
branche de test, ou en regardant la ligne « notification envoyée » du job `notify`.

## 5. Après chaque rotation

- Noter la date et la raison (ticket, commit de l'ADR, etc.).
- Vérifier qu'aucune ancienne valeur ne traîne : `~/Downloads`, messageries,
  fichiers `.env.bak-*` anciens sur le serveur (`find "$APP" -name '.env.bak-*' -mtime +30 -delete`).
