# ADR-0007 — Build once (vendor livré par le CI) et extensions PHP vérifiées/activées

## Statut
Accepté (2026-09-21). Amende ADR-0002 (composer sur le serveur).

## Contexte
Jusqu'à v1.0.x, `composer install --no-dev` tournait **sur le serveur**. Sur
un mutualisé, cela imposait des prérequis manuels et fragiles : composer
présent (souvent absent), accès réseau vers Packagist, et toutes les
extensions PHP CLI du build (ex. `ext-zip` pour phpspreadsheet) — chaque
manque bloquait le déploiement au milieu du flux (cas vécus en production).

Les pratiques actuelles (build once / deploy the artifact) recommandent de
résoudre les dépendances **une fois, dans un environnement de build
contrôlé**, et de ne livrer que l'artefact : la production n'exécute jamais
composer.

## Décision
- **Build sur le runner** : `composer install --no-dev --optimize-autoloader
  --no-scripts` (PHP `php_version` + extensions déduites), puis `vendor/` est
  livré par rsync avec le code. Le serveur exécute seulement
  `artisan package:discover`, `config:cache`, `migrate`, etc.
  Opt-out : `composer_on_server: true` (ancien comportement, avec repli sur
  le composer.phar du runner, ADR non requis).
- **Extensions PHP déduites** de `composer.json` + `composer.lock` (`ext-*`
  des paquets de prod) + `php_extensions` (entrée optionnelle) : source de
  vérité unique, utilisée pour équiper le PHP du runner (`setup-php`) et
  contrôler le serveur.
- **Préflight extensions** (`scripts/ensure-php-extensions.sh`) : compare
  avec `php -m` du `php_bin` ; les manquantes sont activées via CloudLinux
  PHP Selector (`selectorctl --enable-user-extensions`, disponible pour
  l'utilisateur), sinon échec explicite **avant tout transfert**. Un
  avertissement (non bloquant) signale les extensions absentes du PHP web
  `ea-phpXY`, que le selector ne pilote pas.
- **PHP web aligné** (`scripts/ensure-web-php.sh`, entrée `manage_web_php`,
  défaut `true`, exécuté **après** le transfert du code) : le PHP CLI
  (`php_bin`) et le PHP qui sert le domaine (cPanel MultiPHP) sont
  indépendants. MultiPHP applique la version en écrivant un bloc
  `# php -- BEGIN cPanel-generated handler` dans le `.htaccess` du document
  root ; un `rsync` qui écrase ce `.htaccess` (versionné dans le repo)
  supprime le bloc et le domaine retombe sur le PHP hérité du dossier parent,
  alors que `uapi` continue d'annoncer la bonne version (cas vécu : web en
  8.1.34 pour un CLI en 8.4, donc HTTP 500 via `platform_check`). Le script
  aligne la version dans cPanel (`uapi LangPHP`), puis (ré)installe le bloc
  handler dans le `.htaccess` du docroot (idempotent, règles existantes
  conservées). Il ne bloque jamais le déploiement.
- **Échecs lisibles** : `health_check` affiche le code HTTP, le début de la
  réponse et les dernières lignes `.ERROR:` de Laravel ; la sauvegarde DB lit
  le `.env` avec phpdotenv (le parseur de Laravel) au lieu de `grep/cut`, et
  affiche l'erreur de `mysqldump`.
- Les scripts serveur restent tirés de `main` (ADR-0004) ; `deploy-laravel.sh`
  garde `COMPOSER_ON_SERVER=true` par défaut pour ne pas casser les workflows
  appelants épinglés sur une version antérieure.

## Conséquences
- Plus de composer ni de réseau Packagist requis sur le serveur ; les
  installations échouent sur le runner (visible, reproductible) et non en prod.
- `vendor/` est transféré à chaque déploiement (rsync incrémental).
- Le CLI et le PHP web peuvent différer : seul un avertissement est possible.
- Hors CloudLinux (pas de `selectorctl`), les extensions manquantes restent
  à activer côté hébergeur, mais l'erreur est claire et précoce.
