# Contribuer au kit

Chaque projet qui référence `@v1` exécute le code de ce dépôt **à son
déploiement suivant**. Un changement cassé arrête les déploiements de tous les
projets à la fois. D'où les règles de ce document : tests pour tout, lint strict,
releases qui ne déplacent `v1` que si les tests passent.

## Organisation du dépôt

```
.github/
  workflows/
    pipeline.yml      point d'entrée unique appelé par les projets (plan → ci → deploy / doctor / provision / monitor → notify)
    deploy.yml, doctor.yml, monitor.yml   workflows individuels (usage avancé)
    lint.yml          CI du kit : actionlint, shellcheck, tests
    release.yml       sur un tag vX.Y.Z : tests, release GitHub, déplacement du tag vX
  actions/            actions composites partagées : ci-app, deploy-app, doctor-app, provision-app, resolve-php, ssh-setup
scripts/
  plan.sh             lit le manifeste, décide quoi lancer (runner)
  conform.sh          règles de conformité du projet, --fix, --json (runner et poste local)
  policy.sh           conform.sh au format GitHub (job plan)
  init.sh             initialisation / mise en conformité d'un projet (poste local)
  detect-app.sh       stack, PHP minimal, extensions, Node (runner)
  deploy-*.sh, preflight.sh, doctor.sh, provision-*.sh, ensure-*.sh, resolve-php.sh   exécutés SUR LE SERVEUR
  lib/common.sh       fonctions serveur (healthcheck, sauvegardes, PHP web)
templates/            fichiers à copier dans un projet
tests/                suite de tests bash (aucune dépendance)
docs/adr/             décisions d'architecture
docs/runbooks/        procédures d'exploitation
```

## Environnement de développement

Outils : `bash`, `git`, `jq`, `ruby`, `perl`, `curl`. Pour certains tests :
`php` et `sqlite3` (les tests qui en dépendent sont ignorés s'ils manquent).
Lint : [`shellcheck`](https://www.shellcheck.net/) et
[`actionlint`](https://github.com/rhysd/actionlint).

```bash
bash tests/run.sh                 # toute la suite
bash tests/run.sh conform         # un fichier (motif sur le nom)
shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh
actionlint
```

Les trois doivent passer avant toute pull request. `lint.yml` les rejoue sous Linux.

## Écrire des tests

- Un fichier `tests/test_<sujet>.sh`, une fonction `test_<comportement_en_français>`
  par cas. Chaque test tourne dans un sous-shell avec un dossier temporaire `$T`.
- Outils de `tests/lib.sh` : `run` (capture `$OUT` et `$RC`), `mkstub nom 'script'`
  (faux binaire dans `$T/bin`, en tête du `PATH`), `assert_eq`,
  `assert_contains`, `assert_not_contains`, `assert_file_contains`, `need_php`.
- **Pas d'accès réseau ni de serveur réel** : `uapi`, `cloudlinux-selector`,
  `mysqldump`, `gh`… sont simulés par `mkstub`. Reproduisez le **format réel** de
  leur sortie (relevé sur un serveur, en lecture seule).
- Un correctif s'accompagne d'un test qui échouait avant. Nommez l'incident en
  commentaire : c'est ce qui justifie la règle plus tard.
- Le câblage des workflows (entrées transmises, étapes présentes) se teste dans
  `tests/test_workflows.sh` : ce que les tests de scripts ne voient pas.

## Conventions

### Scripts exécutés sur le serveur

Hébergements mutualisés, souvent CloudLinux / CageFS :

- **Pas de substitution de processus** `<(…)` : `/dev/fd` est absent sous CageFS.
  Utilisez `<<<"$(…)"` (le test `test_portabilite_serveur.sh` le vérifie).
- Uniquement `bash`, coreutils, `rsync`, `curl`, `gzip`. Tout autre outil
  (`uapi`, `selectorctl`, `mysqldump`…) est **facultatif** : testez sa présence
  et prévoyez une solution de repli ou un message clair.
- Un script chargé par `ssh 'bash -s'` n'a pas de `BASH_SOURCE` fiable.
- `set -euo pipefail` sauf rapport de diagnostic (`doctor.sh`). Messages
  `::error::` / `::warning::` pour GitHub.

### Scripts exécutés sur le poste (`init.sh`, `conform.sh`)

- Compatibles **bash 3.2** (macOS) : pas de tableaux associatifs, de
  `mapfile`, de `${var,,}`.
- `sed -i` diffère entre macOS et Linux : utilisez `perl -pi`.
- Non interactifs, idempotents, codes de sortie stables, `--json` sur stdout
  pur (le reste sur stderr) : ils sont utilisés par des développeurs et par des
  agents IA.

### Workflows

- Actions tierces **épinglées par SHA** avec la version en commentaire
  (`uses: owner/action@<sha> # v4`) ; Dependabot les met à jour.
- `permissions: contents: read` ; rien de plus sans justification dans une ADR.
- Le kit est récupéré à `job.workflow_sha` (jamais `main`) : workflow, scripts et
  actions restent de la même version.
- Secrets : jamais en argument de commande ni dans un log ; lus sur stdin ou
  depuis l'environnement.

### Textes

Messages, logs, documentation et commentaires en **français**. Messages de commit
en anglais, au présent, courts (`plan: protect nested deploy paths`).

## Ajouter une règle de conformité

1. Dans `scripts/conform.sh`, appelez `report <niveau> <id> <app> <message> <correction> [fonction_fix]`.
   `niveau` : `erreur` (bloque le pipeline) ou `avertissement`. Fournissez une
   fonction `fix_*` seulement si la correction est **sûre et idempotente**.
2. Tests dans `tests/test_conform.sh` : détection, correction, idempotence.
3. Ajoutez la règle au tableau du README et d'[ADR-0012](docs/adr/0012-conformite-projet-bloquante.md).
4. **Une nouvelle erreur bloquante peut arrêter des projets en production.**
   Lancez `conform.sh --dir <projet>` sur les projets consommateurs connus avant
   la release. S'ils ne passent pas, introduisez la règle en avertissement,
   corrigez les projets, puis passez-la en erreur dans une version suivante.

## Ajouter une clé au manifeste

1. `scripts/plan.sh` : ajoutez-la à `KNOWN_APP` (ou aux clés de premier niveau)
   et à la normalisation (valeur par défaut via `d(...)`).
2. Transmettez-la dans `pipeline.yml` (`matrix.app.<clé>`) jusqu'à l'action
   composite concernée, et déclarez l'entrée de l'action.
3. Tests : `tests/test_plan.sh` (valeur normalisée) et
   `tests/test_workflows.sh` (transmission).
4. Documentez-la : tableau du README, `templates/xsel-deploy.example.yml`.

## Décisions d'architecture (ADR)

Tout changement de comportement visible, de sécurité ou de compatibilité fait
l'objet d'une ADR dans `docs/adr/NNNN-titre.md` : *Statut*, *Contexte*,
*Décision*, *Conséquences*. Une ADR ne se réécrit pas : une nouvelle ADR la
complète ou la remplace, et l'ancienne le signale.

## Pull requests

- Une PR = un sujet. Titre et description disent **quoi** et **pourquoi**.
- Cochez avant de demander une relecture :
  - [ ] `bash tests/run.sh`, `shellcheck`, `actionlint` passent
  - [ ] tests ajoutés pour le comportement nouveau ou corrigé
  - [ ] README, templates et ADR à jour si le comportement visible change
  - [ ] `CHANGELOG.md` complété (section *Non publié*)
  - [ ] aucun nom de client, serveur, utilisateur ou chemin réel dans le code, les tests ou la doc
- Les PR Dependabot : vérifier que le SHA correspond au tag officiel de l'action, puis fusionner si `lint.yml` passe.

## Publier une version

Versionnage sémantique : **correctif** (`1.7.1`) = correction sans changement
de comportement attendu ; **mineure** (`1.8.0`) = fonctionnalité compatible ;
**majeure** (`2.0.0`) = changement incompatible (clé de manifeste retirée, secret
renommé…) : les projets doivent passer volontairement de `@v1` à `@v2`.

1. `main` à jour, `lint.yml` vert.
2. `CHANGELOG.md` : renommer *Non publié* en `vX.Y.Z — AAAA-MM-JJ`.
3. Tag annoté et push :
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z — résumé" && git push origin vX.Y.Z
   ```
4. `release.yml` rejoue les tests, crée la release GitHub et déplace `vX` sur ce
   commit. **Si les tests échouent, `vX` ne bouge pas** : corriger, puis nouveau tag.
5. Vérifier sur un projet consommateur : `action: doctor`, puis un déploiement.

Les tags `vX.Y.Z` sont immuables : ne jamais les déplacer ni les supprimer.

## Signaler un problème

Ouvrez une *issue* avec : version du kit (`@v1` → commit, visible dans le log
« Checkout xsel-deploy-mutualise »), extrait du log du job en échec (**sans
secret**), manifeste (chemins anonymisés) et résultat de `action: doctor`. Pour
une faille de sécurité, contactez le mainteneur en privé plutôt qu'en issue publique.
