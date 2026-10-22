# Apps servies par think

Un push sur `main` d'une app la met en ligne quelques minutes plus tard, sans
rien toucher à la main. Ce document dit comment ça marche, comment ajouter une
app et quoi faire quand ça casse.

## Le chemin d'un push

```
push sur l'app
  └─ CI de l'app : app-image.yml (partagé, dans ce dépôt)
       └─ build, contrôle, push ghcr.io/nchpg/<image>:main et :sha-<commit>
            └─ think (apps-watch, toutes les minutes) voit le tag bouger
                 └─ apps-bump.yml ici (runner GitHub) : met à jour profiles/server/apps.lock.json,
                    commit « chore(apps): bump … » sur main
                      └─ think (apps-deploy) : commit qui ne touche que le lock → déployé seul
                           └─ Discord : « 🚀 rlkart mis à jour … répond (200) »
```

think attend que toutes les images d'une app issues d'un même dépôt portent le
même commit (label `org.opencontainers.image.revision`) avant de demander leur
épinglage, en un seul commit. Le frontend et le backend de RLkart ne tournent
donc jamais à des versions différentes. Rien n'est à poser dans les dépôts des
apps : le seul jeton est sur think.

`apps.nix` ne donne que l'image et sa branche (`portfolio:main`, lu `ghcr.io/nchpg/portfolio:main`).
Le digest et le port exposé (`EXPOSE` du Dockerfile) sont dans `apps.lock.json` :
c'est ce digest que podman tire. Un tag
qui bouge dans le registre ne change rien en production tant que le lock n'a pas
bougé.

## Ajouter une app

1. Créer le dépôt depuis le template `Nchpg/app-template` (bouton « Use this
   template », ou `gh repo create Nchpg/monapp --template Nchpg/app-template --private --clone`).
   Il contient déjà le workflow ci-dessous, un Dockerfile d'exemple qui respecte
   les règles, et sa propre marche à suivre. Le workflow, pour un dépôt existant :

   ```yaml
   name: images
   on:
     push:
       branches: [main]
     workflow_dispatch:
   jobs:
     image:
       uses: Nchpg/.dotfiles/.github/workflows/app-image.yml@main
       with:
         images: '[{"name": "monapp"}]'
       permissions:
         contents: read
         packages: write
   ```

   Plusieurs images : une entrée par image, avec `dockerfile` (et `context` si
   ce n'est pas la racine), par exemple
   `[{"name": "monapp-front", "dockerfile": "front/Dockerfile"}, {"name": "monapp-api", "dockerfile": "api/Dockerfile"}]`.

2. Pousser une première fois, pour que l'image existe sur ghcr.io. Le workflow
   partagé refuse de publier une image qui tourne en root ou écoute sous le port
   1024 (voir « Règles des images »). Le Dockerfile déclare aussi son port
   (`EXPOSE 3000`). Un package privé ne demande rien de plus :
   le login `appImages.login` (secret `ghcr/token`) vaut pour toutes les images de
   `ghcr.io/nchpg`.

3. Ici, déclarer l'app dans `profiles/server/apps.nix` :

   ```nix
   monapp.container.image = "monapp:main";
   ```

   C'est tout : l'app est publique sur `monapp.nathanchampagne.com`, sondée sur `/`,
   et son port vient de l'image. Pour s'écarter de ces défauts : `subdomain = "autre"`
   (`"@"` pour le domaine nu), `expose`, `probe = null`, ou `port` sur le conteneur
   si l'image n'a pas d'`EXPOSE`.

   Puis `dots update apps`, qui ajoute l'image au lock avec son digest et son port
   (image privée : `GHCR_TOKEN=… dots update apps`).
   Commit, push. Les pushes suivants de l'app passent ensuite tout seuls.

Aucun DNS à créer : le joker `*.nathanchampagne.com` mène au tunnel Cloudflare,
et seule la route du tunnel (posée par le module) décide si le nom est servi. Un nom sous `.vpn.` n'a besoin de
rien : le joker `*.vpn.nathanchampagne.com` pointe déjà sur le tunnel WireGuard.

## Qui atteint l'app : `expose`

| `expose` | Accès | Ce que le module pose |
|---|---|---|
| `public` (défaut) | tout internet | route dans le tunnel Cloudflare |
| `vpn` | les appareils listés dans `devices`, et think | pas de route ; nom `<subdomain>.vpn.nathanchampagne.com` ; nginx refuse les autres sources |
| `sso` | internet, après connexion Authelia | route, `auth_request` sur le vhost, règle Authelia (`sso.policy`, `sso.subject`) |

En `vpn`, `devices` est obligatoire et nomme les peers de `profiles/server/vpn.nix` :

```nix
monapp = {
  expose = "vpn";
  devices = mesAppareils;          # ou [ "gram" "xiaomi_17t" ]
  containers.web = { … };
};
```

Un nom inconnu fait échouer l'évaluation, et renommer un peer sans mettre à
jour la liste aussi : pas de 403 silencieux. Une sonde (`probe = { }`) choisit
toute seule `http_authelia` pour une app en `sso`.

## Règles des images

`app-image.yml` construit l'image, la contrôle, et ne la publie que si elle passe :

- un utilisateur non-root (`USER`). Node : `USER node` (uid 1000) ou un compte
  créé ; Debian/Python : `RUN useradd --uid 1000 app` puis `USER app` ; nginx :
  partir de `nginxinc/nginx-unprivileged` ;
- un port d'écoute à 1024 ou plus, déclaré par un seul `EXPOSE`.

Sur think, chaque conteneur tourne en plus sans aucune capacité
(`--cap-drop=ALL`), sans nouveaux privilèges, dans un réseau à lui et sans accès
au LAN. Une image tierce qui exige root passe par `allow-root: true` dans le
workflow, ou par `user` et `capabilities` sur le conteneur.

## Plusieurs conteneurs

`container = { … }` est le raccourci d'une app à un conteneur. Au-delà, chaque
conteneur porte un nom choisi (`containers.front`, `containers.api`…), qui nomme
son unité `podman-<app>-<nom>`. Chaque app a son réseau ; les conteneurs s'y
joignent par leur nom (`http://api:8000`). `entrypoint` désigne celui que nginx sert, `dependsOn`
fixe l'ordre de démarrage, et avec un `healthcheck` une unité n'est prête que
quand le conteneur répond. Une base de données a besoin d'un `healthcheck` pour
que l'API attende vraiment qu'elle soit prête.

Les images tierces (`docker.io/library/postgres:17`) passent aussi par le lock,
mais aucune CI ne les pousse : elles avancent par `dots update apps` et par la
PR du lundi, donc toujours avec relecture. Garder la version majeure dans le tag
(`postgres:17`, jamais `latest`) : changer de majeure demande une migration des
données que rien ne fait à ta place.

Les migrations de schéma restent du ressort de l'app, et un retour en arrière
ne restaure pas les données. Les volumes podman ne sont sauvegardés par rien.

## Ce qui se déploie seul, et ce qui attend

think (`appImages.deploy`) regarde `main` toutes les minutes. Il déploie seul un
nouveau commit si, et seulement si :

- les commits depuis la version qui tourne ne touchent que
  `profiles/server/apps.lock.json`, c'est-à-dire des mises à jour de sites ;
- la version qui tourne est un commit poussé sur `main` (pas de changements
  locaux non commités, pas de commits locaux pas encore poussés).

Dans tous les autres cas, il ne touche à rien et poste une seule fois sur
Discord ce qui attend (« 📦 nouveaux commits … `rebuild` à la main », ou
« ⏸️ think tourne une version locale … »). Une modif de config ne part donc
que par ton `rebuild`, avec son retour habituel, et une version locale n'est
jamais écrasée par une mise à jour de site.

Ce qui compte, c'est la version qui tourne, pas l'état du dossier : des
changements en cours dans `~/.dotfiles`, jamais rebuildés, n'empêchent pas un
déploiement. Après chaque déploiement, think avance aussi ce dossier jusqu'au
commit déployé, en avance rapide et au nom de son propriétaire. Seul le lock
change, et tes changements non commités restent tels quels, ni ajoutés ni
commités. Si c'est impossible (commits locaux pas poussés, lock modifié à la
main, autre branche), les sites sont quand même déployés et Discord le signale.

`rebuild` vérifie de son côté que ton dépôt n'est pas en retard sur GitHub : des
bumps de sites absents en local reviendraient en arrière. Il propose alors un
`git pull --rebase --autostash` avant de construire.

Un déploiement automatique qui échoue signale l'unité `apps-deploy` sur Discord
(`journalctl -u apps-deploy`) et n'est pas retenté pour ce commit : think reste
sur la version précédente jusqu'au commit suivant ou au prochain `rebuild`.

En amont, `apps-watch` compare les images au lock **sur GitHub** : une image
déjà épinglée, mais pas encore déployée, ne redemande rien. Il prévient sur
Discord, une fois par problème, quand :

- l'épinglage demandé n'apparaît pas dans le lock au bout d'un quart d'heure
  (`apps-bump` en échec). Il redemande alors tous les quarts d'heure ;
- GitHub refuse la demande (jeton expiré) ;
- une image reste illisible, ou les images d'une app viennent de commits
  différents (une CI ratée), pendant plus d'une demi-heure.

## Revenir en arrière

`git revert` du commit `chore(apps): bump …`, puis pousser : ce commit ne touche
que le lock, think remet l'ancien digest tout seul. Pour le reste du système,
revert du commit fautif puis `rebuild`.

## Jetons

- `github/dispatch_token`, secret sops de think : PAT *fine-grained*, dépôt
  `Nchpg/.dotfiles` seul, permission **Actions: Read and write** et rien
  d'autre. think s'en sert pour déclencher `apps-bump.yml`, qui commite avec son
  propre jeton. Note sa date d'expiration : un refus de GitHub déclenche une
  alerte Discord, puis un nouvel essai tous les quarts d'heure.
- `ghcr/token`, secret sops de think : PAT classique `read:packages`, pour tirer
  et surveiller les images privées.
- `GHCR_READ_TOKEN`, facultatif, dans ce dépôt : PAT classique `read:packages`,
  pour que la PR du lundi vérifie aussi les images privées. Localement :
  `GHCR_TOKEN=… dots update apps`.

Si think ne peut pas déclencher l'épinglage, `dots update apps` ou la PR du
lundi rattrapent : ils lisent les mêmes tags.

## Annonces

À chaque déploiement qui change l'image d'une app, `apps-announce` attend
qu'elle réponde (2 min au plus) puis poste sur le webhook Discord des alertes :
lien, commit, code HTTP. Une app qui ne répond pas est annoncée avec ⚠️.

## App privée

Une app dont le dépôt est privé (stage, MyETF) se déclare comme les autres. Son
package ghcr reste privé : la CI le crée privé et refuse de publier s'il est passé
en public. Le lock public n'en montre que le nom et les digests ; l'image ne se
télécharge qu'avec le jeton `ghcr/token`, que think utilise pour la tirer et la
surveiller. Domaine, appareils admis et secrets (sops) ne révèlent rien de plus
que pour les autres apps.
