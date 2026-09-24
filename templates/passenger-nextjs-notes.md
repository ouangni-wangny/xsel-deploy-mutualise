# Onboarding cPanel — app Next.js (une seule fois par projet)

Depuis `v1.7.0`, `action: provision` (avec `provision: true` sur l'app) fait
l'étape 1 tout seul (cloudlinux-selector ou uapi PassengerApps). Ce qui suit reste
la procédure manuelle, et l'étape 2 (variables d'environnement runtime) reste à faire.

À faire manuellement dans cPanel avant le premier déploiement automatisé
d'une app `nextjs-passenger` (voir ADR-0003 et ADR-0002 — déploiement
direct, sans `current`/releases) :

1. **Setup Node.js App** → *Create Application*
   - Node.js version : celle utilisée en local/CI (`node_version` du
     workflow appelant doit correspondre).
   - Application mode : `Production`.
   - Application root : le `deploy_path` du workflow appelant (ex.
     `peci.org` si l'app root cPanel est `/home/user/peci.org`).
   - Application URL : le (sous-)domaine cible.
   - **Application startup file** : `server.js`
     (le serveur généré par `next build` avec `output: "standalone"`).
2. Dans l'onglet **Environment Variables** de cette même app : renseigner
   toutes les variables runtime nécessaires (tout ce qui n'est pas
   `NEXT_PUBLIC_*`, qui elles doivent être fournies au job de build CI —
   voir le workflow appelant).
3. Cliquer **Create** — cPanel crée l'app et le dossier `tmp/`. Le premier
   déploiement (fait par le workflow) y dépose `server.js` et pourra
   ensuite être redémarré via `tmp/restart.txt`.
4. Vérifier que le (sous-)domaine pointe bien vers l'app root créée
   ci-dessus (cPanel le fait automatiquement pour les apps Node, à
   confirmer dans "Domains" si un domaine existait déjà avant).

Pas d'étape équivalente pour Laravel : il suffit que le document root du
(sous-)domaine (cPanel → Domains) pointe vers `<deploy_path>/public`.
