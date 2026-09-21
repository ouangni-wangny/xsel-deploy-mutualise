# ADR-0007 — Build once (vendor livré par le CI) et extensions PHP vérifiées/activées

## Statut
Accepté (2026-09-21). Amende ADR-0002 (composer sur le serveur).

## Contexte
Jusqu'à v1.0.x, `composer install --no-dev` tournait **sur le serveur**. Sur
un mutualisé, cela imposait des prérequis manuels et fragiles : composer
présent (souvent absent), accès réseau vers Packagist, et toutes les
extensions PHP CLI du build (ex. `ext-zip` pour phpspreadsheet) — chaque
manque bloquait le déploiement au milieu du flux (cas vécus sur SIS).

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
