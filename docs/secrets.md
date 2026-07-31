# Secrets (sops-nix)

Les valeurs chiffrées ne vivent **pas ici**. Elles sont dans un dépôt privé,
tiré comme entrée `secrets` du flake. Ce dépôt-ci est public et ne contient que
la configuration qui les consomme.

Pourquoi les avoir sorties : sops emballe sa clé de données en X25519, que
l'algorithme de Shor casse. Publier les fichiers chiffrés revenait à offrir à qui
veut une copie permanente, déchiffrable le jour où les machines quantiques
arrivent, et l'historique git rend ça irréversible. Ça vidait notamment de son
sens la clé pré-partagée WireGuard, dont le seul rôle est de protéger du trafic
enregistré aujourd'hui.

## Tout est post-quantique

Les quatre destinataires sont des clés **hybrides ML-KEM-768 + X25519**,
produites par `age-keygen -pq`. Le secret partagé dérive des deux mécanismes :
casser X25519 laisse ML-KEM, et réciproquement. La sécurité est donc au moins
égale à celle d'une clé classique, jamais inférieure — il n'y a pas d'arbitrage.

Sous le capot : ML-KEM-768 est FIPS 203, standardisé par le NIST depuis août
2024, l'implémentation est `crypto/mlkem` de la bibliothèque standard de Go, et
la construction est HPKE (RFC 9180) sous le label
`age-encryption.org/mlkem768x25519`.

> **Ne jamais mélanger avec une clé classique.** `age` en ligne de commande
> refuse net (`can't mix post-quantum and classic recipients`), mais **sops
> accepte le mélange sans un mot**, et le fichier s'ouvre alors avec la seule clé
> faible. Vérifié. La discipline est ici, pas dans l'outil.

C'est pourquoi `sops.age.generateKey` est faux : le script d'activation de
sops-nix appelle `age-keygen` sans `-pq`, donc une machine qui se génèrerait sa
clé toute seule arriverait avec une identité classique et casserait la propriété
pour tout le monde. Les clés sont créées par `./init.sh`.

Corollaire sur les clés utilisateur : elles ne sont plus dérivées de la clé SSH.
Une clé ed25519 ne donne que du X25519, et une clé de signature ML-DSA ne se
convertit pas en clé de chiffrement. Ce sont désormais des identités age
dédiées, ce qui coûte une commodité — restaurer sa clé SSH ne suffit plus à
retrouver ses secrets.

Les identités classiques restent à côté des hybrides dans les mêmes fichiers de
clés. Elles ne servent plus pour ces fichiers-ci, mais elles ouvrent encore les
versions déjà commitées.

## Deux mondes, et le critère qui les sépare

**Qui lit le fichier au bout du compte ?** Un service systemd tourne en root ou
sous son propre compte et ne peut pas entrer dans `/run/user/<uid>`. Un outil que
tu lances toi ne peut pas lire `/run/secrets`, qui est en `0400 root`.

|  | Système | Utilisateur |
|---|---|---|
| Déclaré dans | `modules/system/**` | `modules/user/**` |
| Par | le module NixOS de sops-nix | le module home-manager |
| Destinataires | ancres `<host>-sys` | ancres `<host>-user` |
| Clé de déchiffrement | `/var/lib/sops-nix/key.txt` | `~/.config/sops/age/keys.txt` |
| Lisible par | root seul | ton compte |
| Créée par | `./init.sh` (`age-keygen -pq`) | `./init.sh` (`age-keygen -pq`) |
| Déchiffré | à chaque activation système | à l'ouverture de ta session |
| Atterrit dans | `/run/secrets/<nom>` | `/run/user/<uid>/secrets/<nom>` |

Il n'y a **pas** de fichier par plan. Un secret nommé `wireguard/gram_preshared_key`
vit dans `wireguard/gram_preshared_key.yaml`, et c'est vrai des deux côtés : ce qui
change, ce sont ses destinataires.

`wg-quick` tourne en root, donc la clé du tunnel est un secret système, même sur un
portable.

**Ce qui décide, ce sont les destinataires, pas le processus qui déchiffre.** Un
seul fichier chiffré pour les clés utilisateur ne protégeait rien : du code lancé
sous ton compte n'a pas besoin de `/run/secrets`, il ouvre le dépôt avec ta clé.

> **Le plan d'un secret n'excuse pas sa portée.** Un jeton lu par un outil que tu
> lances est un secret utilisateur — mais s'il porte un pouvoir qui n'a rien à faire
> sous ton compte, la réponse n'est pas de le ranger là quand même, c'est d'en
> tailler un plus petit. `cloudflare/api_token` porte `Zone:DNS:Edit` pour la
> validation ACME : le sceller aussi pour une clé de compte le mettait à portée de
> tout code lancé sous cet utilisateur, sans passage par root, et suffisait à
> repointer le domaine et à se faire émettre des certificats valides pour lui. Deux
> jetons, un par usage, chacun sur son plan.

## Un secret, un fichier, et des destinataires calculés

Le nom du secret **est** le chemin du fichier, il n'y a donc jamais à choisir où
ranger une valeur — la question qui, mal répondue une seule fois, élargit le rayon
d'explosion de tout ce qui partage le fichier. Il n'y a pas non plus de fichier de
repli : un nom qui ne correspond à rien fait échouer le rebuild à l'évaluation, au
lieu de rester scellé pour tout le parc sans que rien ne le dise.

Les destinataires ne s'écrivent nulle part à la main. Ils se **déduisent** de deux
choses :

- **qui déclare le secret**, c'est-à-dire le profil du module qui le consomme. Une
  valeur déclarée par un module du profil `server` appartient à `server`, sans qu'on
  l'annote. Une valeur déclarée des deux côtés d'un tunnel reçoit les deux rôles,
  sans qu'aucun des deux modules connaisse l'autre.
- **quelles machines font tourner quels profils**, ce que dit
  `systemSettings.sops.deployments` dans `hosts/default.nix`. C'est la seule
  information du montage qui ne se dérive de rien : `flake.nix` construit ses cibles
  par produit cartésien, donc `server-gram` existe et compile, et sans cette table
  « les machines qui font tourner server » voudrait dire « toutes ».

`nix run .#sops-policy` imprime le bloc `creation_rules` qui en découle, à poser dans
le `.sops.yaml` du dépôt privé. Le check `sops-policy` du flake refuse de passer si
les deux divergent, et ce n'est pas du confort : une audience trop LARGE fonctionne
mieux, pas moins. Rien d'autre ne l'attraperait.

Un même fichier peut relever des **deux plans** à la fois, s'il est lu par un service
ici et par un outil sous ton compte là-bas : il reçoit alors des ancres `-sys` et des
ancres `-user`. Aucun ne le fait aujourd'hui, et avant d'en réintroduire un, la bonne
question est celle de l'encadré plus haut — sont-ce vraiment les mêmes octets qu'il
faut des deux côtés ?

## La commande

Tout passe par `secrets`, qui choisit la bonne clé, les bons chemins, ton
éditeur, et enchaîne les deux commits qu'un changement demande.

```sh
secrets edit wireguard/gram_preshared_key   # édite, CRÉE si absent, puis synchronise
secrets show wireguard/gram_preshared_key
secrets list           # les noms, sans aucun déchiffrement
secrets recipients     # fichier par fichier, qui peut l'ouvrir
secrets updatekeys     # après modification de .sops.yaml
secrets sync           # commit + lock, sans passer par l'éditeur
```

Il n'y a **plus de commande par défaut** : il n'existe pas de « fichier des
secrets » à ouvrir, il faut dire lequel. `secrets` tout court affiche l'aide.

La commande choisit l'identité **par fichier** et non par catégorie, en lisant ses
destinataires : `smtp/password` ne s'ouvre qu'en root, `gh/token` avec ta clé de
compte. Elle tranche sur les destinataires plutôt que par essai-erreur, sops sortant
en échec aussi bien quand il ne peut pas déchiffrer que quand tu abandonnes
l'édition.

`secrets recipients` est le seul contrôle qui ne se déduise pas d'un rebuild réussi,
et il mérite un coup d'œil après chaque changement de politique : un fichier scellé
trop largement fonctionne mieux, pas moins. C'est aussi là qu'on voit un fichier qui
aurait gardé un destinataire **classique** — une clé qui ne commence pas par
`age1pq1` — ce que sops accepte sans un mot et qui rouvre le fichier à la seule clé
faible.

Le dépôt privé est attendu dans `~/.secrets`, surchargeable par `MY_SECRETS`.

### Pourquoi deux commits

L'entrée `secrets` est **épinglée par `flake.lock`**, comme toute entrée de
flake. Commiter dans le dépôt privé ne suffit donc pas : tant que le lock d'ici
pointe sur l'ancienne révision, les machines déploient l'ancienne valeur, sans
un message.

C'est délibéré. Modifier le dépôt de secrets ne change rien à ce que think
déploie tant qu'un commit explicite n'a pas bougé le lock, donc le changement se
voit dans un diff au lieu d'arriver en douce la nuit suivante. `secrets` fait la
séquence pour qu'on ne l'oublie pas.

## Ajouter un secret

**L'ORDRE COMPTE**, et sops le fait respecter tout seul : sans règle correspondante
dans le `.sops.yaml`, il refuse net (« no matching creation rules »). On déclare
donc d'abord, on régénère la politique, et seulement ensuite on pose la valeur.
C'est ce qui garantit qu'aucune valeur n'existe sans que ses destinataires aient
été calculés.

**1. La déclaration**, dans le module qui consomme le secret — c'est elle qui
détermine l'audience, puisque le profil du module *est* l'audience. Deux formes.

Le secret est un fichier à lui seul :

```nix
sops.secrets."mon_app/api_key" = {
  owner = "mon-service";   # côté système : qui a le droit de le lire
  mode = "0400";
};
```

Le secret doit être inséré dans un fichier de configuration :

```nix
sops.secrets."mon_app/api_key" = { };
sops.templates."mon-app-conf" = {
  path = "${config.home.homeDirectory}/.config/mon_app/conf.toml";
  content = ''
    api_key = "${config.sops.placeholder."mon_app/api_key"}"
  '';
};
```

Le `placeholder` est un jeton bidon au build : c'est lui qui part dans le store,
jamais la valeur. sops le remplace à l'activation. Le `/` navigue dans le YAML
imbriqué.

**2. La politique**, puisque l'audience vient de changer. Le bloc généré est à
substituer à celui du `.sops.yaml` du dépôt privé, sans quoi le check du flake
refusera de passer :

```sh
nix run .#sops-policy
```

**3. La valeur** :

```sh
secrets edit mon_app/api_key
```

Le fichier n'existe pas encore, la commande le crée. La création se fait **sous ton
compte quel que soit le secret** : chiffrer ne demande que des clés publiques, seule
la relecture exige d'être destinataire. Un secret système créé ici sera donc scellé
pour la machine qui le consomme, et aussitôt illisible pour toi — c'est le
comportement voulu.

**4. `rebuild`.** La construction refuse de passer si la clé n'existe pas dans le
fichier : sops-nix valide le manifeste au build, donc une configuration qui
référence un secret absent ne peut pas être déployée. Elle refuse aussi si le
fichier lui-même n'existe pas, le chemin étant vérifié à l'évaluation.

> **Piège flake** : un flake n'inclut que les fichiers suivis par git. Un
> *nouveau* fichier `.nix` doit être `git add`é avant le rebuild, sinon Nix ne le
> voit pas. Éditer un fichier déjà suivi ne demande rien.

### Le cas des services système

`restartUnits` n'est pas décoratif. La plupart des démons lisent leur secret
**une fois au démarrage** et ne surveillent pas le fichier : sans cette ligne,
une rotation régénère le fichier sans que le service la reprenne, et ça ne se
voit qu'au prochain redémarrage.

```nix
sops.secrets."wireguard/server_private_key" = {
  owner = "systemd-network";
  mode = "0400";
  restartUnits = [ "systemd-networkd.service" ];
};
```

## Enrôler une machine

```sh
git clone git@github.com:Nchpg/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles && ./init.sh
```

`init.sh` pose tout ce qui doit exister **avant** le premier rebuild, dans le bon
ordre et avec les bons droits : le jeton de lecture, la clé système, la clé
utilisateur — deux identités age dédiées, hybrides, générées sur place — et le
clone du dépôt privé. Chaque étape est idempotente, il ne réécrit jamais un secret
en place.

Il affiche ensuite les deux clés publiques de la machine, et s'arrête. La suite ne
peut pas se faire là : une machine neuve ne peut pas s'autoriser elle-même. Quatre
gestes, dans cet ordre, depuis une machine **déjà autorisée** :

**1. Les ancres**, dans le `.sops.yaml` du dépôt privé, au-dessus du bloc généré :

```yaml
- &nouvelle-sys   age1pq1…
- &nouvelle-user  age1pq1…
```

**2. Le parc**, dans `hosts/default.nix` de ce dépôt-ci. Rien d'autre ne porte
l'information « cette machine fait tourner ce profil pour de vrai », et sans elle
la machine ne devient destinataire de rien :

```nix
systemSettings.sops.deployments.nouvelle = [ "personal" ];
```

**3. La politique**, regénérée depuis les configurations, à substituer au bloc
généré du `.sops.yaml` :

```sh
nix run .#sops-policy
```

**4. Le rescellement**, qui applique cette politique aux fichiers existants :

```sh
secrets updatekeys
```

Resceller exige de pouvoir **déjà** déchiffrer — il rouvre le fichier pour le
refermer avec la clé en plus — d'où l'obligation de le faire ailleurs que sur la
machine neuve. Sur celle-ci, `./rebuild.sh` seulement ensuite.

`updatekeys` ne s'arrête pas sur un fichier qu'il ne peut pas ouvrir : cette
machine-ci ne peut plus lire les secrets qui ne la concernent pas, c'est la
propriété recherchée. Il les liste en fin de course comme « à resceller depuis
celle qui les détient ».

Révoquer, c'est retirer l'ancre, retirer la machine de `deployments`, regénérer la
politique et refaire `secrets updatekeys`. Et **faire tourner les secrets
concernés**, la machine révoquée les ayant connus — le rescellement ne reprend pas
ce qui a déjà été lu.

## Réinstaller une machine

Ses deux clés sont détruites. Tant que l'autre machine tient, elle rescelle vers
les nouvelles et c'est réglé : régénérer les identités avec `./init.sh`, remplacer
les ancres dans le `.sops.yaml`, `nix run .#sops-policy`, `secrets updatekeys`
depuis l'autre. C'est la cérémonie d'enrôlement, à l'identique.

Depuis le passage au post-quantique, ça vaut aussi pour les secrets utilisateur :
leur clé n'est plus dérivée de `~/.ssh/id_ed25519`, donc restaurer sa clé SSH ne
suffit plus à retrouver quoi que ce soit.

**Perdre les deux machines en même temps rend le dépôt de secrets illisible pour
toujours.**

### Ce qu'il faut sauvegarder, et ce que ça ne sert à rien de sauvegarder

Les fichiers chiffrés sont **déjà** hors des machines : ils vivent dans un dépôt
GitHub privé. Les archiver une fois de plus ne couvre rien — sans identité age pour
les ouvrir, ce sont des octets opaques, que la sauvegarde soit protégée par une
phrase de passe ou non.

Ce qui est irremplaçable, ce sont les **deux clés**, et elles ne quittent jamais la
machine qui les a fabriquées :

```sh
tar -cz /var/lib/sops-nix/key.txt ~/.config/sops/age/keys.txt \
  | age -p -o ~/cles-froid.tar.gz.age
```

scrypt plus ChaCha20-Poly1305, entièrement symétrique, donc hors de portée de Shor.
À ranger dans un gestionnaire de mots de passe, pas sur un disque de la maison — ce
fichier ouvre **tout** le dépôt de secrets, la force de la phrase de passe est donc
la seule chose qui le protège.

Restauration : déchiffrer, remettre les deux fichiers à leur place et leurs droits
(`0600 root` pour la clé système), cloner le dépôt privé, et rien d'autre à faire —
les ancres correspondantes sont toujours dans le `.sops.yaml`.

> L'autre voie serait une identité de secours ajoutée comme **destinataire
> supplémentaire** de chaque secret, rangée hors des deux machines. Elle a
> l'avantage de survivre à la perte des deux clés sans rien restaurer, et
> l'inconvénient d'élargir l'audience de tous les secrets à la fois. Le générateur
> de politique ne sait pas l'émettre aujourd'hui : il ne connaît que des ancres de
> machines.

## Le jeton d'amorçage

Le dépôt de secrets étant privé, Nix a besoin d'un jeton de lecture pour le
récupérer. Il est posé à la main, une fois par machine, et il ne peut pas en être
autrement : c'est le jeton qui donne accès aux secrets, il ne peut donc pas venir
des secrets.

```sh
sudo install -d -m 755 /var/lib/nix
sudo sh -c 'umask 077; echo "access-tokens = github.com=github_pat_..." \
  > /var/lib/nix/access-tokens.conf'
```

> **Le `0755` sur le répertoire n'est pas une négligence.** Si un utilisateur ne
> peut pas traverser jusqu'au fichier inclus, nix n'ignore pas l'include : il
> abandonne la totalité de `/etc/nix/nix.conf`. Plus de flakes, plus de
> substituters, `max-jobs = 1`, sans un message. Un fichier illisible dans un
> répertoire traversable est en revanche toléré, ce qui permet de garder le
> jeton en `0600 root`.

Par `!include` depuis `nix.extraOptions` et non par `nix.settings.access-tokens`,
qui écrirait la valeur dans `/etc/nix/nix.conf`, lisible par tous.

Le fichier est en `0600 root`, donc une commande nix lancée sous ton compte qui
doit **aller chercher** l'entrée échoue en 404. Ce n'est pas un oubli : ouvrir ce
jeton à ton compte permettrait d'archiver les fichiers chiffrés, ce qui rouvrirait
exactement le scénario qu'on ferme en sortant les secrets du dépôt public.

En pratique ça ne se voit pas. `rebuild` passe par sudo, et une fois l'entrée
récupérée par root elle vit dans le store partagé, donc les évaluations suivantes
n'ont plus rien à télécharger. Le seul moment sensible est celui qui suit un
changement de lock, et `secrets sync` le fait justement passer par sudo.

### La boucle d'amorçage

Sur une machine neuve, écrire le fichier ne suffit pas : le `!include` n'arrive
dans `/etc/nix/nix.conf` qu'à l'**activation**, laquelle a besoin de récupérer
l'entrée privée, laquelle a besoin du jeton. Le premier rebuild échoue donc en
404, jeton en place ou non.

On casse la boucle en passant l'include une fois à la main, ce qui revient à
faire d'avance ce que la configuration fera ensuite :

```sh
sudo sh -c 'NIX_CONFIG="!include /var/lib/nix/access-tokens.conf" \
  nixos-rebuild switch --flake /home/nchpg/.dotfiles#<cible>'
```

Le jeton ne passe ni par `argv`, visible de tous dans `ps`, ni par
l'environnement : seulement par le fichier que root lit déjà. Les rebuilds
suivants n'ont plus besoin de rien.
