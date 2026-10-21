# Secrets (sops-nix)

> Les commandes à taper, situation par situation (modifier, ajouter, nouveau
> PC…) : **[guide pratique](secrets-guide.md)**. Ce document-ci explique le
> pourquoi.

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

- **quelles machines le déclarent** : celles dont la configuration déployée contient
  le module qui le consomme. Un secret déclaré par un module du profil `server` va
  aux machines qui font tourner `server` ; un secret déclaré dans `hosts/gram` ne va
  qu'à gram. Une valeur déclarée des deux côtés d'un tunnel va aux deux machines,
  sans qu'aucun des deux modules connaisse l'autre. `secretProfiles` élargit
  volontairement un secret à toutes les machines d'un profil.

  **Par machine, et non par profil** : traduire « déclaré sous `personal` » en
  « toutes les machines `personal` » donnait la clé privée WireGuard de gram
  (déclarée par `hosts/gram`) à tout nouveau portable `personal`, de quoi usurper
  gram sur le tunnel. Invisible tant qu'il n'y avait qu'une machine par profil.
- **quelles machines font tourner quels profils**, ce que dit
  `systemSettings.sops.deployments` dans `hosts/default.nix`. C'est la seule
  information du montage qui ne se dérive de rien : `flake.nix` construit ses cibles
  par produit cartésien, donc `server-gram` existe et compile, et sans cette table
  « les machines qui font tourner server » voudrait dire « toutes ».

`secrets policy` calcule le bloc `creation_rules` qui en découle (le même que
`nix run .#sops-policy` imprime), le pose dans le `.sops.yaml` du dépôt privé à la
place de l'ancien, rescelle les fichiers si les destinataires ont changé, et
synchronise. Le check `sops-policy` du flake refuse de passer si les deux
divergent, et ce n'est pas du confort : une audience trop LARGE fonctionne mieux,
pas moins. Rien d'autre ne l'attraperait. Ne jamais éditer ce bloc à la main :
c'est un ajout manuel en fin de fichier qui avait mis le check en échec.

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
secrets policy         # régénère les règles, rescelle ce qui diffère, synchronise
secrets sync           # commit + push + lock, sans passer par l'éditeur
secrets status         # dépôt privé en phase avec le lock ? (muet si oui)
```

Il n'y a **plus de commande par défaut** : il n'existe pas de « fichier des
secrets » à ouvrir, il faut dire lequel. `secrets` tout court affiche l'aide.

La commande choisit l'identité **par fichier** et non par catégorie, en lisant ses
destinataires : `smtp/password` ne s'ouvre qu'en root, `gh/token` avec ta clé de
compte. Elle tranche sur les destinataires plutôt que par essai-erreur, sops sortant
en échec aussi bien quand il ne peut pas déchiffrer que quand tu abandonnes
l'édition.

**Les destinataires réels sont contrôlés en continu.** Pour chaque fichier, la
commande compare les clés inscrites dedans à celles qu'attend le `.sops.yaml`
(la règle du fichier, ses ancres résolues en clés). C'est le seul contrôle qui ne
se déduise pas d'un rebuild réussi : un fichier scellé trop largement fonctionne
mieux, pas moins. Il attrape une règle resserrée sans rescellement, l'ancre d'une
machine réinstallée qu'on a remplacée, une clé en trop, et un destinataire
**classique** resté dans un fichier — une clé qui ne commence pas par `age1pq1`, ce
que sops accepte sans un mot et qui rouvre le fichier à la seule clé faible.

- `secrets status` (donc chaque `git status` dans la config et chaque `rebuild`)
  signale les fichiers qui divergent, en 0,1 s, sans rien déchiffrer ;
- `secrets policy` et chaque `secrets edit` les rescellent. Ceux qu'aucune clé de
  cette machine n'ouvre sont listés, à resceller depuis une machine qui le peut.

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

`secrets sync` reprend là où on s'est arrêté : il commite s'il y a des
modifications, pousse s'il y a des commits en avance, et bouge le lock s'il ne
pointe pas sur le dernier commit. Un push qui avait échoué ou un commit fait à la
main dans `~/.secrets` se rattrapent donc par la même commande. `rebuild` la
propose d'office quand `secrets status` signale du travail.

### Ne travailler que dans la config

On reste dans `~/.dotfiles` ; le dépôt privé suit, par les hooks de `.githooks`
(activés par `./init.sh`), qui délèguent tous à `secrets git-hook`. Comme ce sont
des hooks et pas des alias, ils marchent quel que soit le raccourci (`git st`,
`git p`…) et le client (lazygit, éditeur).

| Dans la config | Côté secrets |
|---|---|
| `git pull` | Si le lock tiré pointe sur une révision absente de `~/.secrets`, celui-ci est tiré en `--ff-only`. Modifications locales ou historiques divergents : avertissement, jamais de fusion sur des fichiers chiffrés. |
| `git push` | Le lock de chaque commit poussé doit pointer sur une révision présente sur l'origin du dépôt privé. Sinon `~/.secrets` est poussé d'abord, et si ça ne suffit pas, le push est **refusé**. |
| `git status` | `secrets status` s'affiche dessous quand il y a quelque chose à dire (hook fish `fish_postexec`, alias git résolus). |

Le refus au push protège le serveur : il déploie seul les mises à jour de sites
**depuis GitHub**, donc avec le lock poussé. Un lock qui pointe sur un commit de
secrets resté sur une machine ferait échouer ce déploiement.
`git push --no-verify` passe outre.

## Ajouter un secret

**L'ORDRE COMPTE**, et sops le fait respecter tout seul : sans règle correspondante
dans le `.sops.yaml`, il refuse net (« no matching creation rules »). On déclare
donc d'abord, on régénère la politique, et seulement ensuite on pose la valeur.
C'est ce qui garantit qu'aucune valeur n'existe sans que ses destinataires aient
été calculés.

**1. La déclaration**, dans le module qui consomme le secret — c'est elle qui
détermine l'audience : les machines dont la configuration contient ce module. Deux
formes.

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

**2. La valeur** :

```sh
secrets edit mon_app/api_key
```

La politique se régénère d'elle-même au début de chaque `secrets edit` (0,1 s une
fois l'évaluation en cache, muette si rien n'a changé) : le nouveau secret reçoit
sa règle, calculée depuis la déclaration, sans `secrets policy` à lancer. La
déclaration doit seulement être suivie par git — un flake ne voit que les fichiers
suivis. Sans déclaration, la commande refuse de créer le fichier et le dit.

Le fichier n'existe pas encore, la commande le crée. La création se fait **sous ton
compte quel que soit le secret** : chiffrer ne demande que des clés publiques, seule
la relecture exige d'être destinataire. Un secret système créé ici sera donc scellé
pour la machine qui le consomme, et aussitôt illisible pour toi — c'est le
comportement voulu.

**3. `rebuild`.** La construction refuse de passer si la clé n'existe pas dans le
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
nix-shell -p git     # git n'est pas installé sur une NixOS neuve
git clone https://github.com/Nchpg/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles && ./init.sh
```

En HTTPS : le dépôt est public, aucune clé n'est nécessaire pour le cloner. Et
**dans `~/.dotfiles`**, que le script exige : home-manager y fige `MY_FLAKE`.

`init.sh` pose tout ce qui doit exister **avant** le premier rebuild, dans le bon
ordre et avec les bons droits :

- le **nom du host** et le profil, demandés (le hostname vaut `nixos` sur une
  installation neuve, ce n'est pas le nom qui sert aux ancres) ;
- `hosts/<host>/hardware-configuration.nix`, généré pour un nouveau host, et
  proposé à la régénération s'il cite des disques absents (réinstallation) ;
- le jeton de lecture, la clé système, la clé utilisateur — deux identités age
  dédiées, hybrides, générées sur place ;
- l'**accès SSH à GitHub** : clé créée si besoin, le script attend qu'elle soit
  ajoutée au compte, puis passe le remote de la config en SSH pour pouvoir
  pousser ;
- le clone du dépôt privé dans `~/.secrets`, et les hooks git ;
- l'**inscription** de la machine, après une confirmation : ses deux clés
  publiques comme ancres `<host>-sys` / `<host>-user` dans le `.sops.yaml` du dépôt
  privé (remplacées si elles existent, cas d'une réinstallation), son profil dans
  `systemSettings.sops.deployments` (`hosts/default.nix`), et son fichier matériel —
  commités et poussés dans les deux dépôts.

Chaque étape est idempotente, il ne réécrit jamais un secret en place.

**L'inscription ne donne accès à rien.** Une clé publique ajoutée n'ouvre aucun
fichier : il faut encore qu'une machine qui les ouvre déjà les **rescelle** pour la
nouvelle. C'est l'unique geste qui reste, sur une machine **déjà autorisée** :

```sh
git pull && secrets policy
```

`secrets policy` affiche, fichier par fichier, quelle machine gagne (`+newpc-user`)
ou perd (`-gram-user`) l'accès, et demande confirmation avant de resceller. C'est
le moment où l'accès se donne — une ancre poussée à ton insu dans le dépôt privé se
verrait là, avant d'avoir rien ouvert.

Resceller exige de pouvoir **déjà** déchiffrer — il rouvre le fichier pour le
refermer avec la clé en plus — d'où l'obligation de le faire ailleurs que sur la
machine neuve. Les fichiers qu'aucune clé de la machine autorisée n'ouvre sont
listés « à resceller depuis une machine qui peut les ouvrir » : `secrets policy`
là-bas aussi.

`secrets policy` finit en donnant le commit du lock à faire (`flake.lock`) : à
commiter et pousser, sans quoi le `git pull` de la machine neuve ne lui apporte
rien. Puis, sur la machine neuve : `git pull && ./scripts/rebuild.sh --host <host>
--profile <profil>`. Relancer `./init.sh` dit où l'on en est : « destinataire de
tous ses secrets » quand chaque fichier qui doit s'ouvrir pour elle la cite.

Entre l'inscription et ce commit du lock, le check `sops-policy` de la CI est
rouge sur `main` : la config déclare une machine que le `.sops.yaml` verrouillé ne
connaît pas encore. C'est attendu, et ça se referme avec le commit du lock.

Révoquer, c'est retirer l'ancre, retirer la machine de `deployments`, puis
`secrets policy`. Et **faire tourner les secrets concernés**, la machine révoquée
les ayant connus — le rescellement ne reprend pas ce qui a déjà été lu.

## Réinstaller une machine

Ses deux clés sont détruites. Tant que l'autre machine tient, elle rescelle vers
les nouvelles et c'est réglé : `./init.sh` régénère les identités et **remplace**
les ancres de la machine dans le `.sops.yaml`, puis `secrets policy` depuis
l'autre. C'est la cérémonie d'enrôlement, à l'identique.

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
