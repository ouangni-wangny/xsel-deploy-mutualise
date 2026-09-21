# ADR-0008 — Durcissement de la chaîne CI/CD : SHA, permissions, Environment

## Statut
Accepté (2026-09-21)

## Contexte
Les workflows de déploiement s'exécutent avec accès à la clé SSH de
production. Une action tierce compromise (tag mobile `@v4` déplacé vers du
code malveillant) ou un jeton GitHub aux droits trop larges donnerait accès
à la production. Les pratiques 2026 recommandent : actions épinglées par
SHA, permissions minimales, et une porte d'approbation pour la production.

## Décision
- **Actions épinglées par SHA de commit** (`uses: actions/checkout@<sha> # v4`),
  dans le kit et dans les projets consommateurs. **Dependabot**
  (`github-actions`, hebdomadaire) propose les mises à jour : l'épinglage ne
  doit pas figer les correctifs. Le script `actionlint` du lint est lui aussi
  figé (commit + version) au lieu de `main`.
- **`permissions: contents: read`** au niveau racine de chaque workflow : le
  jeton `GITHUB_TOKEN` n'a aucun droit d'écriture. Un workflow qui en aurait
  besoin doit le déclarer explicitement, job par job.
- **Environment GitHub** : `deploy.yml` déclare `environment: <input environment>`
  (défaut `production`). Les règles — approbation manuelle (*required
  reviewers*), restriction aux branches — se configurent côté dépôt
  (Settings → Environments), pas dans le code. Sans règle, comportement
  inchangé.

## Conséquences
- Une action tierce ne peut plus changer de contenu sans une PR visible.
- Les runs de déploiement apparaissent sous l'environnement « production »
  (historique des déploiements GitHub).
- Avec *required reviewers*, chaque déploiement attend un clic ; le
  déploiement déclenché par un push n'est plus automatique. Les protections
  d'Environment sur dépôt **privé** exigent un plan GitHub payant (Pro/Team).
- Limite connue : les scripts serveur sont toujours tirés de `main` du kit
  (ADR-0004), donc non figés par le SHA/tag du workflow appelé.
- Hors périmètre volontaire : releases avec bascule de lien symbolique et
  rollback (ADR-0002 les écarte pour l'instant).
