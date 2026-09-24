# ADR-0012 — Conformité du projet : règles uniques, bloquantes, corrigeables

## Statut
Accepté (2026-09-24). Remplace le point 5 d'ADR-0011 (politiques en avertissements seulement).

## Contexte
L'intégration d'un nouveau projet (monorepo Laravel + Next.js, dépôt chez un autre
propriétaire que le kit) a buté sur des manques **du projet**, chacun découvert
tard, parfois en production :

| Manque | Découvert | Coût |
|---|---|---|
| `secrets: inherit` vers un kit d'un autre propriétaire | au déploiement | secrets SSH vides, run en échec |
| suite PHPUnit pointant vers un dossier absent du dépôt | en CI | « Test directory not found » |
| `output: "standalone"` absent | avant, par chance | Passenger sans `server.js` |
| moteur MySQL par défaut (MariaDB mutualisée en MyISAM) | pendant la migration | base à moitié créée, `db:wipe` manuel |
| `/.well-known` et `/cgi-bin` non protégés de `rsync --delete` | par hasard | renouvellement TLS cassé |
| `<env DB_DATABASE>` de `phpunit.xml` ≠ base de CI | en CI | contournement dans le manifeste |

`policy.sh` ne faisait qu'avertir, sur quatre règles, et rien n'aidait à corriger.

## Décision
1. **Une source unique de règles : `scripts/conform.sh`.** Chaque règle a un
   identifiant, un niveau (`erreur` | `avertissement`) et, quand c'est sûr, une
   correction automatique. Règles actuelles :

   | id | niveau | auto | objet |
   |---|---|---|---|
   | `secrets-inherit` | erreur | oui | `secrets: inherit` vers un kit d'un autre propriétaire |
   | `env-versionne` | erreur | oui* | `.env` suivi par git (*sort de l'index + `.gitignore` ; changer les secrets reste manuel) |
   | `next-standalone` | erreur | oui | `output: "standalone"` absent de `next.config.*` |
   | `phpunit-dossier` | erreur | oui | suite PHPUnit vers un dossier absent du dépôt (`.gitkeep`) |
   | `npm-lock` / `composer-lock` | erreur | non | lockfile absent (`npm ci`, build reproductible) |
   | `app-introuvable` | erreur | non | `path` du manifeste inexistant |
   | `moteur-innodb` | avertissement | oui | `'engine' => null` dans `config/database.php` |
   | `laravel-htaccess` | avertissement | oui | `.htaccess` racine absent (document root cPanel) |
   | `version-node` | avertissement | oui | ni `.nvmrc`, ni `engines.node`, ni `node_version` |
   | `dependabot` | avertissement | oui | `.github/dependabot.yml` absent |
   | `health-http` | avertissement | non | `health_check_url` en `http://` |
   | `kit-branche` / `kit-en-retard` | avertissement | non | référence du kit |

2. **Le pipeline bloque.** L'étape « Conformité du projet » du job `plan`
   (`policy.sh` → `conform.sh --annotate`) échoue s'il reste une erreur : ni CI
   ni déploiement. Chaque problème est annoté et listé dans le résumé du run avec
   la commande de correction. Exceptions : `action: doctor` et `provision`
   (ne déploient rien, erreurs signalées sans bloquer) et le cron de monitoring.

3. **La correction est locale, jamais faite par le pipeline.** `init.sh --fix`
   (ou `conform.sh --fix`) applique les corrections sûres ; on relit le diff et
   on commite. Le pipeline garde `contents: read` : pas de commit de bot, pas de
   boucle, et le code déployé est toujours celui qu'un humain a relu.

4. **Même usage pour un développeur et pour un agent IA.** Non interactif,
   idempotent, codes de sortie stables (0 conforme · 1 erreur restante · 2 usage),
   `--json` pour une sortie machine (`{conforme, erreurs, avertissements, corriges,
   corrigeables, regles[]}`), `--check` pour contrôler sans rien écrire.

5. **Échappatoire explicite** dans le manifeste, visible en revue de code :
   `policy: { ignore: [laravel-htaccess] }`.

6. **Ce que le kit peut faire seul, il le fait** sans le demander au projet :
   `/.well-known` et `/cgi-bin` toujours exclus de `rsync --delete` ; base de test
   de la CI exportée dans l'environnement du job (prime sur `phpunit.xml`) ;
   `doctor` affiche le moteur MySQL par défaut du serveur et alerte s'il n'est pas InnoDB ;
   `init.sh` génère un `cicd.yml` qui passe les secrets un par un.

## Conséquences
- Un projet non conforme ne déploie plus ; la correction tient en une commande.
- Les projets existants (les trois en production) ont été contrôlés avant la
  publication : aucune erreur bloquante, seulement des avertissements.
- Ajouter une règle = une fonction dans `conform.sh` + un test dans
  `tests/test_conform.sh`. Une nouvelle règle **bloquante** peut arrêter les
  déploiements de projets en `@v1` : la vérifier d'abord sur les projets connus,
  sinon l'introduire en avertissement.
