# ADR-0004 — Un repo central "source de vérité", workflow réutilisable

## Statut
Accepté (2026-09-18)

## Contexte
Chaque projet XSEL a jusqu'ici réinventé son propre script de déploiement
(voir `dolci-reva/deploy/`, `nounou/deploy/`, `folioas` `DEPLOY.md`, etc.),
avec des variations non justifiées par de vraies différences de besoin.
Corriger un bug de déploiement (ex. mauvaise gestion des migrations) oblige à
le corriger séparément dans chaque projet.

## Décision
- Ce repo (`xsel-deploy-mutualise`) est l'unique source de vérité pour le
  déploiement vers un hébergement mutualisé cPanel. Il contient :
  - un **workflow GitHub Actions réutilisable**
    (`.github/workflows/deploy.yml`, déclenché via `workflow_call`) ;
  - les **scripts de déploiement serveur** (`scripts/`), génériques par
    stack (`laravel`, `nextjs-passenger`), paramétrés par variables
    d'environnement — jamais copiés-collés dans un projet consommateur.
- Un projet consommateur (ex. le projet pilote) ne porte que :
  - un petit workflow appelant (`.github/workflows/deploy.yml` du projet,
    voir `templates/caller-workflow.example.yml`) qui référence le workflow
    réutilisable et renseigne ses `with:` (stack, chemin serveur,
    sous-dossier...) — ce fichier *est* la configuration, pas besoin d'un
    fichier YAML séparé à maintenir en double ;
  - les secrets GitHub (clé SSH, host/port/user) ;
  - côté serveur, un `.env` (Laravel) créé une fois à la main dans `deploy_path`.
- Toute évolution du comportement de déploiement (nouvelle stack, correctif
  de bug, simplification du transport) se fait **une seule fois ici**, puis se
  propage aux projets consommateurs au déploiement suivant — sans action de
  leur part si le workflow appelant référence `@main` (ou une version taguée
  si un projet a besoin de figer une version).
- Les scripts serveur (`scripts/lib/common.sh`, `scripts/deploy-*.sh`) sont
  synchronisés vers le serveur à **chaque** déploiement (avant exécution),
  garantissant qu'ils sont toujours à la dernière version de ce repo, même
  si le serveur n'a jamais de `git pull` de `xsel-deploy-mutualise` lui-même.

## Conséquences
- Un changement buggé dans ce repo peut casser le déploiement de *tous* les
  projets consommateurs en même temps — d'où l'intérêt de disposer d'un
  projet de référence (le projet pilote) pour valider chaque évolution avant qu'elle ne
  soit taguée/adoptée largement.
- Référencer `@main` dans le workflow appelant donne la dernière version
  automatiquement (pratique en phase de rodage) ; épingler un tag
  (`@v1.2.0`) une fois le kit stabilisé, pour éviter qu'un projet ne soit
  affecté par un changement non testé.
- **Visibilité du repo — contrainte technique découverte en implémentant :**
  GitHub n'autorise l'appel `uses: owner/repo/.github/workflows/x.yml@ref`
  vers un *autre* repo que si ce repo est public, ou privé au sein d'une
  organisation avec accès explicitement partagé. Le compte `ouangni-wangny` étant un
  compte personnel (pas une org), `xsel-deploy-mutualise` doit rester
  **public** pour que le mécanisme fonctionne pour tous les projets
  consommateurs. Comme le repo ne contient aucun secret ni information
  spécifique à un client (uniquement des scripts génériques), ce n'est pas
  un problème de confidentialité — mais c'est une contrainte à connaître
  avant d'y ajouter quoi que ce soit de sensible.
