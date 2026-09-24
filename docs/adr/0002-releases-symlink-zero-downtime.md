# ADR-0002 — Déploiement direct (révisé : plus de releases/symlink)

## Statut
**Révisé (2026-09-18).** Remplace la version initiale de cet ADR, qui
retenait un schéma `releases/<timestamp>/` + symlink `current` (façon
Deployer/Capistrano). Cette section décrit la décision actuelle ; le
contexte historique est gardé plus bas pour mémoire.

## Décision actuelle
Chaque déploiement **écrase le code en place**, directement dans
`<deploy_path>/` :

```
<deploy_path>/
├── .env                 ← persiste (jamais supprimé par rsync)
├── storage/              ← persiste (Laravel : logs, uploads, cache)
├── server.js              ← Next.js standalone (écrasé à chaque déploiement)
└── ...                     ← code applicatif (écrasé à chaque déploiement)
```

`rsync --delete` synchronise le dossier avec le nouveau build (un fichier
retiré du repo est bien supprimé du serveur), mais avec des exclusions
protégées en dur — voir « Incidents » plus bas pour pourquoi chacune
existe : `.deploy-scripts`, `.backups`, et selon la stack `.env`/`storage`
(Laravel) ou `.htaccess`/`tmp` (Next.js, généré par cPanel). Plus
`protect_paths` (configurable par projet) pour les cas de `deploy_path`
imbriqués entre deux apps.

- Le document root cPanel pointe directement sur `<deploy_path>/public`
  (Laravel) ou `<deploy_path>` (Next.js, "Application root" cPanel) — plus
  de segment `current/` dans le chemin.
- Pas de rollback automatisé : en cas de problème après déploiement, il
  faut redéployer la version précédente depuis GitHub (revert du commit +
  push), ou intervenir manuellement sur le serveur.
- Pas de garantie zéro-downtime : il existe une brève fenêtre, pendant le
  `rsync`, où le site peut servir un mélange de fichiers anciens et
  nouveaux.

## Pourquoi ce choix (2026-09-18)
Le schéma releases/symlink ajoutait une couche de complexité (dossiers
`releases/`, `shared/`, gestion de symlink, nettoyage des anciennes
releases, script de rollback séparé) jugée disproportionnée par rapport
au bénéfice pour l'usage réel du projet : complexifie la lecture du
File Manager cPanel, ajoute une étape de compréhension supplémentaire
("pourquoi mon dossier ressemble à ça"), et le rollback instantané n'a
pas été jugé prioritaire face à la simplicité. Décision explicite du
porteur du projet, en connaissance du compromis (pas de zéro-downtime
garanti, pas de rollback instantané).

## Conséquences
- Plus simple à inspecter/déboguer directement dans un File Manager.
- Onboarding plus court (pas de `bootstrap-app.sh` créant une arborescence
  à trois niveaux, pas de doc à lire sur le fonctionnement du symlink).
- En cas de déploiement cassé, le temps de rétablissement dépend du temps
  de build + déploiement d'un nouveau commit (pas de bascule instantanée).
- `scripts/rollback.sh` est retiré du kit (plus rien à quoi l'appliquer).
- Tout fichier placé manuellement sur le serveur (hors `.env`/`storage`)
  et non suivi en git est supprimé au prochain déploiement, sauf s'il
  entre dans une des exclusions protégées ci-dessus. Un fichier Laravel
  comme `.htaccess` doit être suivi en git (voir
  `templates/laravel.htaccess.example`) précisément pour cette raison.

## Incidents rencontrés (tous corrigés, gardés pour mémoire)

**1. `backend/` effacé par le déploiement du frontend.** Première
tentative avec `--delete` sans protection : sur le projet pilote, le sous-domaine
`backend.example.com` vit dans un sous-dossier du `deploy_path` du
frontend (`example.com/backend`, chemin cPanel standard pour un
sous-domaine). `--delete` a traité ce sous-dossier comme obsolète et l'a
supprimé en entier. → `--delete` retiré temporairement, puis réintroduit
avec l'input `protect_paths`.

**2. `.htaccess` généré par cPanel effacé, deux fois.** (a) Un
`.htaccess` Laravel placé manuellement à la racine du projet backend
(réécriture vers `public/`, pattern qui évite de changer le document
root cPanel) a été supprimé car non suivi en git → déplacé en git, suivi
comme n'importe quel fichier du projet (voir `laravel.htaccess.example`).
(b) Le `.htaccess` que cPanel *lui-même* génère à la création d'une app
via *Setup Node.js App* (routage Passenger) a ensuite été supprimé par
le déploiement du frontend suivant — celui-là n'est pas reproductible
depuis un repo (spécifique à l'instance cPanel) → exclu en dur du
`--delete` pour la stack `nextjs-passenger` (avec `tmp/`, même
raisonnement).

## Contexte historique (schéma initial, abandonné)
Le schéma initial reposait sur `releases/<timestamp>/` + symlink
`current`, avec bascule atomique (`mv -T`) et `shared/` pour les fichiers
persistants — inspiré des outils Deployer/Capistrano, pensé pour
permettre un rollback en quelques secondes en repointant le symlink.
Objectif toujours valide en théorie, mais laissé de côté ici au profit de
la simplicité — un futur projet qui a besoin de zéro-downtime garanti ou
de rollback instantané peut réintroduire ce schéma (voir l'historique git
de ce fichier et des scripts pour retrouver l'implémentation).
