# ADR-0006 — Une seule connexion SSH par déploiement (ControlMaster)

## Statut
Accepté (2026-09-21)

## Contexte
Jusqu'à v1.0.1, chaque étape du workflow ouvrait sa propre connexion SSH :
`ssh-keyscan` (une connexion **par type de clé**), création des dossiers,
préflight, deux `rsync`, finalisation — une huitaine de connexions en
quelques minutes depuis la même IP.

De nombreux hébergeurs mutualisés limitent le nombre de nouvelles
connexions par IP (pare-feu CSF/LFD, fail2ban, `MaxStartups`, règles
réseau…). Le symptôme est trompeur : les premières connexions passent, les
suivantes ne reçoivent **aucune réponse** (`ssh: connect to host … Connection
timed out`, exit 255, ~2 min de blocage) — pas un refus, donc pas un problème
de clé, de port ou de host key. Cas vécu sur SIS (serveur Namecheap
`*.hostns.io`) : `ssh-keyscan` + `mkdir` passaient, le préflight time-out ;
un test `ssh-keyscan` en boucle depuis un poste reproduisait le blocage dès
la 3e tentative et le port restait fermé plusieurs minutes. PECI, sur un
autre serveur, n'était pas concerné.

Les hébergeurs cibles du kit sont divers ; la correction doit donc être
générique, pas spécifique à un hébergeur.

## Décision
Dans l'étape « Configurer la clé SSH » :
- **Host key** : un seul `ssh-keyscan -t <type>` (ed25519, puis ecdsa, puis
  rsa en repli si le serveur n'expose pas le précédent) au lieu d'un scan de
  tous les types.
- **Multiplexage** : un bloc `Host` dans `~/.ssh/config` active
  `ControlMaster auto` / `ControlPersist 30m`. Toutes les commandes `ssh` et
  `rsync -e ssh` des étapes suivantes réutilisent la connexion TCP maître ;
  si elle est perdue, ssh en recrée une automatiquement.
- **Robustesse** : `ConnectTimeout 20` (échec en 20 s et non 2 min),
  `ServerAliveInterval`, et ouverture de la connexion maître avec retry +
  backoff (4 essais, 20/40/60 s). Un refus d'authentification ou de host key
  n'est pas retenté.
- Une étape finale `if: always()` ferme la connexion maître.

Total : 1 connexion de scan + 1 connexion maître, quel que soit le nombre
d'étapes.

## Conséquences
- Les étapes suivantes ne changent pas (elles passent toujours `-p`,
  `-o StrictHostKeyChecking=yes`, `user@host` en ligne de commande) : le
  bloc `Host` s'applique au nom d'hôte tel que fourni dans `SSH_HOST`.
- Si un hébergeur limite à moins de 2 nouvelles connexions par fenêtre, le
  retry/backoff absorbe les blocages temporaires ; au-delà, il faut faire
  lever la limite côté hébergeur (le message d'erreur le suggère).
- Ne concerne que le transport ; aucun changement de comportement du
  déploiement lui-même.
