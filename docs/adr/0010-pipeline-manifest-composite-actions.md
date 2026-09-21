# ADR-0010 — Point d'entrée unique (`pipeline.yml`), manifeste, actions composites, tag flottant

## Statut
Accepté (2026-09-21). Complète ADR-0004 et ADR-0009.

## Contexte
Même après la détection automatique (ADR-0009), un projet portait 5 à 6
workflows (CI backend, CI frontend, deploy backend, deploy frontend, monitor,
doctor), ~200 lignes, à faire évoluer en même temps que le kit. Deux
contraintes techniques de GitHub Actions dictent la solution :
- dans un workflow réutilisable appelé depuis un autre dépôt, `uses: ./…` se
  résout vers le dépôt **appelant** ; et `uses:` n'accepte pas d'expression :
  un `pipeline.yml` ne peut donc pas appeler `deploy.yml` « à la même version »
  sans figer un `@v1` flottant (cohérence perdue, impossible à tester sur
  branche) ;
- les actions **composites** chargées depuis un checkout du kit à
  `job.workflow_sha` restent à la version exacte du workflow appelé.

## Décision
1. **La logique vit dans des actions composites** (`.github/actions/`) :
   `deploy-app`, `ci-app`, `doctor-app` (+ `ssh-setup`, `resolve-php`). Les
   workflows n'orchestrent que : `deploy.yml` et `doctor.yml` deviennent de
   fines couches, `pipeline.yml` en est une autre.
2. **`pipeline.yml`** : job `plan` (lit `.xsel-deploy.yml`, `scripts/plan.sh`),
   puis `ci` (matrice d'apps, en parallèle), `deploy` (matrice, `max-parallel: 1`,
   ordre du manifeste, `fail-fast`, attend la CI), `doctor`, `monitor`. Le projet
   n'écrit qu'un workflow d'appel de 25 lignes et un manifeste.
3. **Qui lance quoi** : selon l'événement (PR, push, dispatch, cron) et les
   fichiers modifiés (`git diff`), avec repli sur « toutes les apps » sans diff
   exploitable ou si le manifeste / `.github/` change.
4. **CI standard** (`ci-app`) : Laravel (composer, `.env` de test, MySQL 8 en
   conteneur si `database: mysql`, Pint si `lint`, `artisan test`) ; Next.js
   (`npm ci`, lint si demandé, tests s'ils existent, `npm run build`). Un projet
   au CI spécifique met `ci: none` sur l'app et garde sa propre CI.
5. **Tag flottant `v1`** : `release.yml`, sur tag `vX.Y.Z`, exécute les tests,
   crée la GitHub Release, puis déplace `vX`. Un tag qui échoue aux tests ne
   déplace jamais `vX`. Les tags `vX.Y.Z` restent immuables ; un projet peut
   figer une version (ou un SHA).
6. **Hygiène** : les valeurs du manifeste transitent par des variables
   d'environnement dans les actions, non interpolées dans le shell ; les
   booléens sont normalisés une fois par `plan.sh` (piège jq : `false // x`
   vaut `x`, corrigé et testé).

## Conséquences
- Un correctif du kit atteint tous les projets en `@v1` sans commit chez eux ;
  la contrepartie est de faire confiance au kit (c'est le vôtre) et de tenir la
  discipline de versions (changement cassant = `v2`).
- Les secrets suivent une convention de nommage (`DEPLOY_SSH_*`) avec
  `secrets: inherit`.
- `build_frontend_assets` vaut `false` par défaut : le squelette Laravel
  embarque toujours `vite build`, même pour une API JSON (faux positif).
- Les déploiements d'un même push sont séquentiels : plus lents qu'en parallèle
  mais sans rafale de connexions SSH (ADR-0006) et avec l'API avant le frontend.
- Hors périmètre : releases avec bascule de lien symbolique et rollback (ADR-0002).
