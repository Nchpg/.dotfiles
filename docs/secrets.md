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
| Fichier | `system.yaml` | `secrets.yaml` |
| Destinataires | clés système des machines | tes clés `~/.ssh/id_ed25519` |
| Clé de déchiffrement | `/var/lib/sops-nix/key.txt` | `~/.config/sops/age/keys.txt` |
| Lisible par | root seul | ton compte |
| Créée par | sops-nix, à l'activation | toi, une fois, via `ssh-to-age` |
| Déchiffré | à chaque activation système | à l'ouverture de ta session |
| Atterrit dans | `/run/secrets/<nom>` | `/run/user/<uid>/secrets/<nom>` |

`wg-quick` tourne en root, donc la clé du tunnel est un secret système, même sur
un portable. `wrangler` tourne sous toi, donc son jeton est un secret
utilisateur, même s'il permet de modifier le DNS.

**Ce qui décide, ce sont les destinataires, pas le processus qui déchiffre.** Un
seul fichier chiffré pour les clés utilisateur ne protégeait rien : du code lancé
sous ton compte n'a pas besoin de `/run/secrets`, il ouvre le dépôt avec ta clé.

## La commande

Tout passe par `secrets`, qui choisit la bonne clé, les bons chemins, ton
éditeur, et enchaîne les deux commits qu'un changement demande.

```sh
secrets                # édite system.yaml, puis synchronise
secrets user           # édite secrets.yaml, puis synchronise
secrets show wireguard/gram_preshared_key
secrets list           # les clés système, valeurs masquées
secrets updatekeys     # après modification de .sops.yaml
secrets sync           # commit + lock, sans passer par l'éditeur
```

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

**1. La valeur**, avec `secrets` (système) ou `secrets user` (le tien).

**2. La déclaration.** Deux formes.

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

**3. `rebuild`.** La construction refuse de passer si la clé n'existe pas dans le
fichier : sops-nix valide le manifeste au build, donc une configuration qui
référence un secret absent ne peut pas être déployée.

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
utilisateur dérivée de ta clé SSH, et le clone du dépôt privé. Chaque étape est
idempotente, il ne réécrit jamais un secret en place.

Il affiche ensuite les deux clés publiques de la machine, et s'arrête. La suite
ne peut pas se faire là : une machine neuve ne peut pas s'autoriser elle-même.
Depuis une machine **déjà autorisée**, ajouter ces clés dans le `.sops.yaml` du
dépôt privé — la système sous le groupe de `system.yaml`, l'utilisateur sous
celui de `secrets.yaml` — puis :

```sh
secrets updatekeys
```

Resceller un fichier exige de pouvoir déjà le déchiffrer, d'où l'obligation de le
faire ailleurs. Ensuite seulement, `./rebuild.sh` sur la machine neuve.

`updatekeys` doit tourner depuis une machine qui peut **déjà** déchiffrer : il
rouvre le fichier pour le resceller avec la clé en plus.

Révoquer, c'est retirer la clé et refaire `secrets updatekeys`. Et faire tourner
les secrets concernés, la machine révoquée les ayant connus.

## Réinstaller une machine

Sa clé système est détruite. Tant que l'autre machine tient, on ré-encrypte vers
la nouvelle clé et c'est réglé. **Perdre les deux en même temps rend
`system.yaml` illisible pour toujours** : une clé de secours rangée hors des deux
machines couvre ce cas, et peut s'ajouter à tout moment avec `secrets
updatekeys`.

Les secrets utilisateur sont dans le même cas depuis le passage au
post-quantique : leur clé n'est plus dérivable de `~/.ssh/id_ed25519`, donc
restaurer sa clé SSH ne suffit plus. Une machine réinstallée génère une nouvelle
identité via `./init.sh` et doit être réautorisée depuis l'autre.

**Sauvegarde froide**, la seule qui couvre la perte des deux machines à la fois,
et la seule qui reste post-quantique hors du dépôt :

```sh
secrets list                      # vérifier ce qu'on sauvegarde
age -p -o ~/secrets-froid.age ~/.secrets/system.yaml
```

scrypt plus ChaCha20-Poly1305, entièrement symétrique, donc hors de portée de
Shor. À ranger dans un gestionnaire de mots de passe, pas sur un disque de la
maison.

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
