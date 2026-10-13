# Secrets : le guide pratique

Ce qu'il faut taper, situation par situation. Le pourquoi est dans
[secrets.md](secrets.md).

Une seule règle : **tu restes dans `~/.dotfiles`**. Le dépôt privé `~/.secrets`
suit tout seul (`git pull`, `git push` et `rebuild` s'en occupent). Tu n'as jamais
à y aller à la main.

Quand un secret change, deux choses bougent : le dépôt privé, et `flake.lock`
dans la config, qui dit quelle version des secrets les machines déploient. Les
commandes `secrets` font la première partie seules ; la seconde, c'est le commit
de `flake.lock` qu'elles t'affichent à la fin.

## Modifier un secret

```sh
secrets edit gh/token
```

L'éditeur s'ouvre avec la valeur en clair. Tu modifies, tu enregistres, tu
quittes. La commande commite, pousse le dépôt privé et met `flake.lock` à jour
(mot de passe sudo). Ensuite :

```sh
git commit -m "chore: bump secrets" -- flake.lock && git push
rebuild
```

Le serveur prend la nouvelle valeur à sa mise à jour automatique de la nuit, une
fois le push fait.

## Voir un secret, lister les secrets

```sh
secrets show gh/token
secrets list
```

## Ajouter un secret

1. Le déclarer dans le module qui s'en sert. C'est ce qui décide quelles machines
   pourront l'ouvrir : celles dont la config contient ce module.

   ```nix
   sops.secrets."mon_app/api_key" = { };
   ```

   Nouveau fichier `.nix` ? `git add` (un flake ne voit que les fichiers suivis).

2. Poser la valeur :

   ```sh
   secrets edit mon_app/api_key
   ```

   La commande calcule toute seule la règle du nouveau secret, puis crée le
   fichier. Si tu as oublié l'étape 1, elle refuse et le dit.

3. Commiter la déclaration **avec** le lock (sinon la CI signale une règle que
   la config poussée ne déclare pas), puis rebuild :

   ```sh
   git commit -m "feat: add mon_app api key" -- modules/…/default.nix flake.lock
   git push
   rebuild
   ```

## Supprimer un secret

1. Retirer sa déclaration du module.
2. Supprimer le fichier et synchroniser :

   ```sh
   rm ~/.secrets/mon_app/api_key.yaml && secrets sync
   ```

3. Commiter le module modifié et le lock ensemble, puis `rebuild`.

## Installer un nouveau PC

Sur le PC neuf :

```sh
nix-shell -p git
git clone https://github.com/Nchpg/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles && ./init.sh
```

Le script demande le nom de la machine (nouveau, en minuscules : `laptop`,
`pc-salon`…) et son profil (`personal` ou `server`). Il te fera ajouter une clé
SSH à GitHub si besoin, puis inscrit la machine et pousse tout.

Sur une machine déjà en service (gram par exemple) :

```sh
git pull && secrets policy
```

Elle affiche quels secrets le nouveau PC va pouvoir ouvrir et demande
confirmation. Lis la liste avant de valider : c'est le moment où tu donnes
l'accès. Puis commite le lock comme elle te l'indique :

```sh
git commit -m "chore: bump secrets" -- flake.lock && git push
```

Retour sur le PC neuf :

```sh
git pull && ./scripts/rebuild.sh --host laptop --profile personal
```

Pour savoir où tu en es, relance `./init.sh` sur le PC neuf : il répond « reste
une étape » ou « destinataire de tous ses secrets ».

Pour un nouveau **serveur**, `secrets policy` depuis gram ne peut pas tout faire :
il liste les secrets du serveur « à resceller depuis une machine qui peut les
ouvrir ». Lance aussi `git pull && secrets policy` sur think.

## Réinstaller une machine

Même chose qu'un nouveau PC, avec **le même nom** que la machine réinstallée.
`init.sh` te demande de confirmer la réinstallation, puis remplace ses anciennes
clés par les nouvelles. Ensuite `git pull && secrets policy` sur une autre
machine, exactement comme pour un nouveau PC.

Si tu as restauré les clés depuis ta sauvegarde, il n'y a rien à faire ailleurs :
`init.sh` le voit et te donne directement la commande de rebuild.

## Donner un profil de plus à une machine

Exemple : gram doit pouvoir faire aussi le serveur.

```sh
./init.sh          # sur gram, en tapant le profil server
```

Puis `git pull && secrets policy` sur think, qui seul ouvre les secrets du
serveur, et le commit du lock. Sur gram : `git pull && ./scripts/rebuild.sh --host gram
--profile server`.

## Retirer une machine

1. Dans `hosts/default.nix`, supprimer sa ligne de `deployments` ; commit, push.
2. Dans `~/.secrets/.sops.yaml`, supprimer ses deux ancres (`- &laptop-sys …` et
   `- &laptop-user …`).
3. ```sh
   secrets policy
   ```
   Elle montre les accès retirés (`-laptop-user`…) et demande confirmation.
4. Commiter le lock.
5. **Changer les secrets qu'elle pouvait lire** (`secrets edit` sur chacun) : le
   retirer empêche les lectures futures, pas celles déjà faites.

## Vérifier que tout va bien

```sh
secrets status
```

Rien ne s'affiche : tout est en ordre. Sinon, la commande dit quoi faire. La
même chose s'affiche sous `git status` / `git st` dans la config, et `rebuild` te
propose de corriger avant de reconstruire.

| Message | À faire |
|---|---|
| `→ secrets sync` | `secrets sync` |
| `fichier(s) scellé(s) autrement que le .sops.yaml` | `secrets policy` |
| `à resceller depuis une machine qui peut les ouvrir` | `secrets policy` sur l'autre machine (think pour les secrets du serveur) |
| `→ git -C ~/.secrets pull --ff-only` | cette commande, puis `secrets sync` si demandé |
| `à régler à la main` | les deux machines ont modifié les secrets en même temps : `git -C ~/.secrets status` |

## Travailler sur deux machines

Rien de spécial : `git pull` et `git push` dans `~/.dotfiles`, avec tes alias
habituels. `git pull` met aussi les secrets à jour. `git push` pousse les secrets
d'abord si la config en a besoin, et refuse si c'est impossible, pour que le
serveur ne casse pas la nuit.

## Si tu as oublié une commande

```sh
dots
```

Un menu avec toutes les commandes et des exemples.
