# Apps servies par think

Un push sur `main` d'une app la met en ligne quelques minutes plus tard, et un
réglage changé dans le dashboard (`admin.vpn.nathanchampagne.com`) part seul
lui aussi. Ce document dit comment ça marche, comment ajouter une app et quoi
faire quand ça casse.

## Les pièces

| Où | Pièce | Rôle |
|---|---|---|
| dépôt d'app | `.github/workflows/images.yml` | appelle le build partagé à chaque push |
| ici | `app-image.yml` | construit, contrôle (non-root, un port), publie `:main` et `:sha-<commit>` |
| ici | `apps.yml` | **seul** à écrire les sites sur `main` : action `pin` (nouveau digest) ou `edit` (une entrée d'`apps.json`) |
| ici | `profiles/server/apps.json` | les sites : adresse, accès, images suivies, données, secrets |
| ici | `profiles/server/apps.lock.json` | la version exacte de chaque image suivie (digest, port, commit) |
| think | `apps-watch` (chaque minute) | voit une nouvelle image et demande à `apps.yml` de l'épingler |
| think | `apps-deploy` (chaque minute) | applique seul un commit qui ne touche qu'`apps.json` et le lock |
| think | `apps-announce` | après chaque changement de site, Discord quand il répond |
| think | `admin` | le dashboard : modifie un site par `apps.yml`, après avoir évalué la config |

## Les trois chemins

**Une nouvelle version d'un site**, environ 3 à 5 minutes après le push :

```
push sur l'app ─► app-image.yml publie :main et :sha-<commit>
  ─► apps-watch le voit ─► apps.yml « pin » : commit du lock (chore(apps): bump …)
  ─► apps-deploy l'applique ─► Discord : « 🚀 rlkart mis à jour … répond (200) »
```

think attend que toutes les images d'une app issues d'un même dépôt portent le
même commit (label `org.opencontainers.image.revision`) avant de demander leur
épinglage, en un seul commit : le frontend et le backend de RLkart ne tournent
jamais à des versions différentes.

**Un réglage changé dans le dashboard** :

```
« Appliquer » ─► think évalue la config avec le nouvel apps.json (refus si erreur)
  ─► apps.yml « edit » : commit d'apps.json (et du lock) ─► apps-deploy l'applique
  ─► la page passe au vert quand le site répond ; Discord : « ⚙️ réglages appliqués »
```

**Tout le reste de la config** : `apps-deploy` ne l'applique pas, Discord dit
« 📦 `rebuild` à la main », et c'est ton `rebuild` qui l'applique.

Le digest est ce que podman tire : un tag qui bouge dans le registre ne change
rien en production tant que le lock n'a pas bougé.

## Ajouter une app

1. Créer le dépôt depuis le template `Nchpg/app-template` (« Use this template »,
   ou `gh repo create Nchpg/monapp --template Nchpg/app-template --private --clone`).
   Pour un dépôt existant, copier son `.github/workflows/images.yml` :

   ```yaml
   name: images
   on:
     push:
       branches: [main]   # ou [main, preview] : une image par branche (cf. Environnements)
     workflow_dispatch:
   concurrency:            # un nouveau push annule le build en cours de la même branche
     group: images-${{ github.ref }}
     cancel-in-progress: true
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

2. Pousser une première fois, pour que l'image existe sur ghcr.io (voir « Règles
   des images »).

3. Dans le dashboard, **Ajouter un site** : choisir le dépôt (la liste vient des
   packages ghcr, privés compris), l'adresse et l'accès, puis **Mettre en ligne**.
   Le dashboard écrit l'entrée et le digest, think la met en ligne seul.

   Sans le dashboard : ajouter l'entrée à `apps.json`, puis `dots update apps`
   (qui met l'image dans le lock), commit, push, `rebuild`.

Aucun DNS à créer : le joker `*.nathanchampagne.com` mène au tunnel Cloudflare,
et seule la route du tunnel (posée par le module) décide si le nom est servi. Un
nom sous `.vpn.` n'a besoin de rien : `*.vpn.nathanchampagne.com` pointe déjà sur
le tunnel WireGuard.

## Le format d'apps.json

```json
{
  "rlkart": {
    "entrypoint": "frontend",
    "containers": {
      "frontend": { "image": "rlkart-frontend:main", "dependsOn": ["backend"] },
      "backend": { "image": "rlkart-backend:main" }
    },
    "rateLimit": ["/generate", "/simulate"]
  }
}
```

| Clé | Défaut | Sens |
|---|---|---|
| (nom) | | identifiant interne : unités `podman-<nom>-<conteneur>`, réseau, port, données. 12 caractères au plus ; le changer recrée le site |
| `subdomain` | le nom | adresse sous le domaine (`"@"` : le domaine lui-même) |
| `expose` | `"public"` | `"vpn"` : seulement les appareils de `devices` |
| `devices` | | noms des appareils de `profiles/server/vpn-peers.json`, en `vpn` |
| `sso` | `false` | le portail Authelia en plus, public ou VPN |
| `accounts` | | comptes Authelia admis, au moins un, avec `sso` (page Authelia du dashboard) |
| `internetAccess` | `false` | connexions sortantes vers internet (jamais vers le LAN) |
| `probe` | `"/"` | chemin sondé |
| `entrypoint` | | conteneur servi par nginx, s'il y en a plusieurs |
| `rateLimit` | | chemins limités par IP (`[]` : tout le site) |
| `containers.<c>.image` | | `nom:tag`, sous `ghcr.io/nchpg` ; le tag est la branche suivie (`main`) ou `sha-<commit>` (figé) |
| `name` | `"production"` | nom affiché de la racine |
| `environments` | | autres branches du site, cf. « Environnements » |
| `containers.<c>.memory` | | plafond, `256m`, `1g`… |
| `containers.<c>.dependsOn` | | conteneurs du même site à démarrer avant |
| `containers.<c>.data` | | `[{"path": "/data"}]` : dossier gardé entre deux versions, dans `/var/lib/apps/<site>/<conteneur>/data`, donné à l'utilisateur de l'image. `"on"` choisit l'emplacement : `/var/lib/<site>…` ou un volume podman `<site>-…` |
| `containers.<c>.secrets` | | secrets sops rangés sous `<site>/` (lignes `NOM=valeur`), donnés en variables d'environnement |

Une clé inconnue fait échouer l'évaluation. Ce que le format ne couvre pas
(healthcheck, commande, capacités) se complète en Nix dans `apps.nix`, sur la
même app : `systemSettings.apps.stage.containers.web.healthcheck.command = …`.
Le Nix complète, il ne remplace jamais ce que dit le JSON.

Un secret se crée avec `secrets edit <site>/env`, puis `secrets sync` et
`rebuild` (il change `flake.lock`). Il apparaît alors dans le dashboard, où on le
coche sur un conteneur. Inutile qu'un conteneur le cite d'abord : tout
`<site>/<clé>` d'un site d'`apps.json` a sa règle, scellée pour la machine qui
fait tourner le site (`lib/sops/policy.nix`).


## Environnements

Un site peut tourner sur d'autres branches, chacune à sa propre adresse : c'est
un environnement, sous `environments.<id>` de l'entrée. La racine (le site
lui-même) reste au premier niveau et s'affiche « production » (`name` pour un
autre nom).

```json
"myetf": {
  "subdomain": "etf", "expose": "vpn", "devices": ["gram"],
  "containers": { "web": { "image": "myetf:main", "data": [{ "path": "/app/data" }] } },
  "environments": {
    "preview": {
      "branch": "preview", "data": "copy", "expose": "public",
      "containers": { "web": { "image": "myetf", "memory": "256m", "data": [{ "path": "/app/data" }] } }
    },
    "staging": { "name": "Staging", "branch": "feat/charts", "from": "preview", "data": "shared" }
  }
}
```

- **Servi comme une app à part**, `<site>-<id>` (`myetf-preview`) : ses unités,
  son réseau, son port, ses sondes et ses annonces. L'`id` est fixé à la
  création ; `name` (le nom affiché) se change librement, sans rien redémarrer.
  Adresse par défaut : `<site>-<id>.<domaine>` (`subdomain` pour une autre).
- **Image** : celle du parent, au tag de la branche (`feat/charts` -> `feat-charts`,
  ce que publie `app-image.yml`), ou `pin` (`sha-<commit>`) pour la figer. Dans
  un environnement, une image se donne donc sans tag. Seule une branche qui a
  déjà publié une image peut être choisie : une image absente du lock fait
  échouer l'évaluation.
- **Héritage**, section par section, du parent (`from`, la racine par défaut) :
  une section est à l'environnement dès que sa clé repère est là.

  | Section | Repère | Clés |
  |---|---|---|
  | accès | `expose` | `expose`, `devices`, `sso`, `accounts` |
  | conteneurs | `containers` | `containers` (images, mémoire, données, secrets, `dependsOn`), `entrypoint` |
  | options | `internetAccess` | `internetAccess`, `probe`, `rateLimit` |

- **Données** (`data`) :
  - `separate` (défaut) : `/var/lib/apps/<site>-<id>/…`, vides au départ ;
  - `copy` : le même dossier, rempli au premier démarrage par une copie de
    celui du parent (propriétaire compris), puis indépendant. Le dashboard
    peut le **recopier** à la demande (`admin-recopy`, root, arrête
    l'environnement le temps de la copie) ;
  - `shared` : le dossier du parent lui-même (attention aux migrations de
    schéma lancées par la branche).
- **Secrets** : ceux du site (`<site>/…`). Un environnement aux conteneurs
  hérités reçoit les mêmes que son parent, sauf ceux qu'il remplace :
  `"secrets": { "<site>/db": "<site>/preview_db" }`. Les remplacements se
  cumulent le long de l'héritage (le plus proche l'emporte) ; avec des
  conteneurs propres, les secrets se choisissent dans chaque conteneur. Pour
  tout ce qui ne doit pas toucher la production (base, envoi d'e-mails,
  paiements).
- Un environnement public n'est pas indexé par les moteurs de recherche
  (`X-Robots-Tag: noindex`).
- Retirer un environnement : ceux qui en héritaient héritent de son parent ;
  ses données restent sur think.

Pour qu'une branche publie une image, le workflow du dépôt doit se déclencher
sur elle (`on.push.branches`, par exemple `[main, preview]` ou `["**"]`) :
`app-image.yml` publie alors `:<branche>` et `:sha-<commit>`.
## Règles des images

`app-image.yml` construit l'image, la contrôle, et ne la publie que si elle passe :

- un utilisateur non-root (`USER`). Node : `USER node` (uid 1000) ou un compte
  créé ; Debian/Python : `RUN useradd --uid 1000 app` puis `USER app` ; nginx :
  partir de `nginxinc/nginx-unprivileged` ;
- un port d'écoute à 1024 ou plus, déclaré par un seul `EXPOSE`.

Sur think, chaque conteneur tourne en plus sans aucune capacité
(`--cap-drop=ALL`), sans nouveaux privilèges, dans un réseau à lui et sans accès
au LAN. Un `HEALTHCHECK` dans le Dockerfile est repris par podman tel quel.

## Plusieurs conteneurs

Chaque site a son réseau ; ses conteneurs s'y joignent par leur nom
(`http://backend:8000`). `entrypoint` désigne celui que nginx sert, `dependsOn`
fixe l'ordre de démarrage. Les migrations de schéma restent du ressort de l'app,
et un retour en arrière ne restaure pas les données.

## Ce qui se déploie seul, et ce qui attend

`apps-deploy` regarde `main` toutes les minutes. Il applique seul un nouveau
commit si, et seulement si :

- les commits depuis la version qui tourne ne touchent que
  `profiles/server/apps.json` et `profiles/server/apps.lock.json` ;
- la version qui tourne est un commit poussé sur `main` (pas de changements
  locaux non commités, pas de commits locaux pas encore poussés).

Dans tous les autres cas, il ne touche à rien et poste une seule fois sur
Discord ce qui attend. Une modif de config ne part donc que par ton `rebuild`,
et une version locale n'est jamais écrasée par un changement de site. Il tient
`/var/lib/apps-deploy/status.json` à jour (décision, versions, état de
`~/.dotfiles`) : c'est ce que montre la carte « État de think » du dashboard.

Après chaque déploiement, think avance aussi `~/.dotfiles` jusqu'au commit
déployé (avance rapide, à ton nom, changements en cours conservés). Si c'est
impossible, les sites sont quand même déployés et Discord le signale. `rebuild`
vérifie de son côté que le dépôt n'est pas en retard sur GitHub, et propose un
`git pull --rebase --autostash`.

Un déploiement qui échoue (build refusé) laisse la version précédente, signale
l'unité `apps-deploy` sur Discord et n'est pas retenté pour ce commit.

En amont, `apps-watch` compare les images au lock **sur GitHub**. Il prévient
sur Discord, une fois par problème, quand l'épinglage n'apparaît pas au bout
d'un quart d'heure (`apps.yml` en échec : il redemande tous les quarts d'heure),
quand GitHub refuse la demande (jeton expiré), ou quand une image reste illisible
ou incomplète plus d'une demi-heure.

## Revenir en arrière

Dans le dashboard, menu **Version** du site : choisir un commit. Les images
passent de `:main` à `:sha-<commit>` (le même pour toutes celles du site), le
site est **figé** et think l'applique seul. Un tag `sha-…` ne bouge jamais :
les nouvelles images de `main` attendent jusqu'à ce que le site suive `main` de
nouveau. Seules les images construites par le template ont ces tags.

Sans le dashboard : même changement dans `apps.json` (`"image": "rlkart-frontend:sha-<commit>"`),
puis `dots update apps` pour le lock. Un `git revert` d'un commit `bump` ne tient
pas : `apps-watch` redemanderait aussitôt la dernière image de `main`.

Pour le reste du système : revert du commit fautif puis `rebuild`.

## Le dashboard

`admin.vpn.nathanchampagne.com`, joignable depuis les appareils de
`profiles/server/admin.nix` **et** derrière Authelia en 2FA. Il ne tourne pas en
root et n'a aucun droit d'écriture sur un dépôt : chaque modification passe par
`apps.yml`, qui revérifie l'entrée, refuse si le site a changé depuis
l'ouverture de la page (empreinte de l'entrée), puis commite. Avant d'envoyer,
il évalue toute la config de think avec le nouvel `apps.json` : une adresse
prise ou un appareil inconnu ne part jamais sur `main`. Il suit ensuite le
commit, l'application par think et la réponse de chaque adresse touchée
(environnements qui héritent du changement compris). Un onglet par
environnement ; « + Environnement » en crée un (nom, branche publiée, parent).
Sa seule action hors de `apps.yml` : demander la recopie des données d'un
environnement en `copy`, que fait `admin-recopy` (root, environnements connus
de la config seulement).

## Jetons

- `github/dispatch_token`, secret sops de think : PAT *fine-grained*, dépôt
  `Nchpg/.dotfiles` seul, permission **Actions: Read and write** et rien
  d'autre. think s'en sert pour lancer `apps.yml`, qui commite avec son propre
  jeton. Note sa date d'expiration : un refus de GitHub déclenche une alerte
  Discord.
- `ghcr/token`, secret sops de think : PAT classique `read:packages`, pour tirer
  et surveiller les images privées, et lister les dépôts dans le dashboard.
- `GHCR_READ_TOKEN`, facultatif, dans ce dépôt : PAT classique `read:packages`,
  pour que la PR du lundi vérifie aussi les images privées. Localement :
  `GHCR_TOKEN=… dots update apps`.

## Annonces

Après chaque déploiement, `apps-announce` poste sur le webhook Discord des
alertes, une ligne par site changé, une fois qu'il répond (2 min au plus) :
🆕 en ligne, 🚀 nouvelle image, ⚙️ réglages appliqués, 🗑️ supprimé, ⚠️ s'il ne
répond pas. Un site qui devient public, ou qui perd le portail, le dit en clair
(🔓).

## App privée

Une app dont le dépôt est privé (stage, MyETF) se déclare comme les autres. Son
package ghcr reste privé : la CI le crée privé et refuse de publier s'il est passé
en public. Le lock public n'en montre que le nom et les digests ; l'image ne se
télécharge qu'avec le jeton `ghcr/token`.
