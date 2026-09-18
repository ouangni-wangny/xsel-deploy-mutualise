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

`rsync --delete` synchronise le dossier avec le nouveau build, à
l'exception de `.env` et `storage/` (Laravel), explicitement exclus pour
persister entre déploiements.

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

## Contexte historique (schéma initial, abandonné)
Le schéma initial reposait sur `releases/<timestamp>/` + symlink
`current`, avec bascule atomique (`mv -T`) et `shared/` pour les fichiers
persistants — inspiré des outils Deployer/Capistrano, pensé pour
permettre un rollback en quelques secondes en repointant le symlink.
Objectif toujours valide en théorie, mais laissé de côté ici au profit de
la simplicité — un futur projet qui a besoin de zéro-downtime garanti ou
de rollback instantané peut réintroduire ce schéma (voir l'historique git
de ce fichier et des scripts pour retrouver l'implémentation).
