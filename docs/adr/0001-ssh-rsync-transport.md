# ADR-0001 — Transport de déploiement : SSH + rsync/scp

## Statut
Accepté (2026-09-18)

## Contexte
Les projets XSEL sont hébergés sur des hébergements mutualisés (type cPanel).
Le déploiement actuel est manuel (upload FTP ou commandes tapées à la main),
ce qui est jugé trop fastidieux. Il faut un transport scriptable depuis
GitHub Actions.

Vérifié sur l'hébergement du projet pilote : l'accès SSH par clé est disponible
(cPanel → SSH Access → Manage SSH Keys). C'est un prérequis pour ce modèle ;
un projet dont l'hébergeur ne fournit pas SSH ne peut pas utiliser ce kit
tel quel (voir « Limites » plus bas).

## Décision
Le transport standard est **SSH** (clé dédiée, sans passphrase, autorisée
côté cPanel) pour :
- `rsync` (ou `scp` en repli si `rsync` est absent du serveur) pour envoyer
  les artefacts de build directement dans `deploy_path` (ADR-0002) ;
- des commandes shell exécutées à distance (`ssh host 'script...'`) pour la
  l'installation serveur des dépendances PHP et le
  redémarrage de l'application Node.

FTP et le déploiement Git natif de cPanel (`.cpanel.yml`) sont écartés :
moins observables depuis GitHub Actions, pas de contrôle fin possible
avec FTP seul.

## Conséquences
- Chaque projet consommateur doit générer une paire de clés dédiée
  (`github-actions-deploy`), l'autoriser dans cPanel, et stocker la clé
  privée comme secret GitHub (`SSH_PRIVATE_KEY`).
- Host / port / utilisateur SSH doivent être récupérés depuis la page
  cPanel « SSH Access » (le port n'est pas toujours 22 sur du mutualisé).

## Limites
Si un futur hébergement mutualisé ne fournit pas SSH (FTP/cPanel only),
ce kit ne s'applique pas directement — il faudrait un ADR séparé pour un
transport FTP ou un hook Git cPanel.
