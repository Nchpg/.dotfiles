# Secrets (sops-nix)

Gestion des secrets du dotfiles avec [sops-nix](https://github.com/Mic92/sops-nix).
Les secrets sont **chiffrés** dans `secrets/secrets.yaml` (committable sans risque)
et déchiffrés **uniquement** sur une machine autorisée, au moment du
`nixos-rebuild switch`.

## Fichiers clés

| Fichier | Rôle |
|---|---|
| `secrets/secrets.yaml` | Les secrets, **chiffrés** (committé dans Git) |
| `.sops.yaml` (racine) | Liste des clés publiques age autorisées à déchiffrer |
| `modules/user/sops/default.nix` | Config globale sops-nix (chemin clé + fichier) |
| `~/.config/sops/age/keys.txt` | Clé **privée** age, dérivée de la clé SSH. **JAMAIS** dans Git, locale à chaque machine |

## Comment ça marche (en bref)

Deux moments distincts — Nix ne voit **jamais** le secret en clair :

1. **Au build** : `config.sops.placeholder."x"` vaut un jeton bidon
   `<SOPS:…:PLACEHOLDER>`. C'est lui qui part dans le Nix store. Aucun secret exposé.
2. **À l'activation** (`switch`, sur la machine, avec ta clé age) : sops déchiffre
   les `sops.secrets.*`, remplace chaque jeton par la vraie valeur, et écrit le
   fichier final en `0400` dans `$HOME`.

Trois briques :
- `sops.secrets.<nom>` → **déchiffre** la clé `<nom>` du fichier.
- `sops.placeholder.<nom>` → **marqueur** « ici, mettre la valeur de `<nom>` ».
- `sops.templates.<nom>` → texte à trous + chemin du fichier généré.

Le `/` dans un nom (`"google/client_id"`) navigue dans le YAML imbriqué.

---

## 1. Éditer un secret existant

```sh
cd ~/.dotfiles
nix shell nixpkgs#sops -c sops secrets/secrets.yaml   # ou juste `sops secrets/secrets.yaml` apres un switch
```

Ça ouvre le fichier **déchiffré** dans `$EDITOR`. Modifie, sauvegarde, ferme →
sops **re-chiffre tout seul**. Puis :

```sh
git add secrets/secrets.yaml
sudo nixos-rebuild switch --flake .#personal-gram
```

> Pas besoin de `updatekeys` : c'est seulement pour changer les *clés*, pas le contenu.

---

## 2. Ajouter un nouveau secret

### Étape A — mettre la valeur (chiffrée)

```sh
nix shell nixpkgs#sops -c sops secrets/secrets.yaml
```

Ajoute ta ligne / ton bloc YAML, ex :

```yaml
mon_app:
    api_key: la_valeur_en_clair
```

Vérifie qu'elle est bien chiffrée :

```sh
grep -A1 mon_app secrets/secrets.yaml   # doit montrer ENC[...]
```

### Étape B — la référencer dans Nix (2 cas)

**Cas 1 — le secret = un fichier à part entière** (ex. un `.json`, une clé) :

```nix
sops.secrets."mon_app/api_key" = {
  path = "${config.home.homeDirectory}/.config/mon_app/api_key";
};
```
→ dépose un fichier `0400` contenant la valeur.

**Cas 2 — le secret doit être inséré DANS un fichier de conf** :

```nix
sops.secrets."mon_app/api_key" = { };          # declare (-> dechiffrable)
sops.templates."mon-app-conf" = {
  path = "${config.home.homeDirectory}/.config/mon_app/conf.toml";
  content = ''
    api_key = "${config.sops.placeholder."mon_app/api_key"}"
  '';
};
```

Pour générer un **JSON** depuis plusieurs sous-clés (cf. task-tui) :

```nix
content = builtins.toJSON {
  key = config.sops.placeholder."mon_app/api_key";
  other = config.sops.placeholder."mon_app/other";
};
```

### Étape C — appliquer

```sh
git add secrets/secrets.yaml          # + tout NOUVEAU fichier .nix cree (cf. piege ci-dessous)
sudo nixos-rebuild switch --flake .#personal-gram
```

> ⚠️ **Piège flake** : un flake n'inclut que les fichiers **tracked par git**.
> Si tu crées un *nouveau* fichier `.nix`, fais `git add` avant le `switch`,
> sinon Nix ne le voit pas. (Éditer un fichier déjà tracked ne nécessite rien.)

---

## 3. Ajouter un nouveau PC (nouvelle clé SSH)

Chaque machine déchiffre avec **sa propre** clé SSH ed25519 (convertie en clé age).
On autorise une machine en ajoutant sa clé **publique** comme destinataire.

### Sur le NOUVEAU PC

1. S'assurer qu'il a une clé SSH ed25519 (`~/.ssh/id_ed25519`). Sinon :
   ```sh
   ssh-keygen -t ed25519
   ```
2. Récupérer sa clé **publique** age :
   ```sh
   nix shell nixpkgs#ssh-to-age -c ssh-to-age < ~/.ssh/id_ed25519.pub
   # -> age1......
   ```
3. Générer le fichier de clé **privée** age local (pour que sops déchiffre au switch) :
   ```sh
   mkdir -p ~/.config/sops/age
   nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/.ssh/id_ed25519 \
     -o ~/.config/sops/age/keys.txt
   chmod 600 ~/.config/sops/age/keys.txt
   ```

### Depuis un PC DÉJÀ autorisé (ex. `gram`)

4. Ajouter le `age1...` du nouveau PC dans `.sops.yaml` :
   ```yaml
   keys:
     - &gram   age1jaux...          # existant
     - &laptop age1NOUVELLE_CLE...  # nouveau PC
   creation_rules:
     - path_regex: secrets/.*\.ya?ml$
       key_groups:
         - age:
             - *gram
             - *laptop
   ```
5. **Re-chiffrer** les secrets pour inclure la nouvelle clé :
   ```sh
   nix shell nixpkgs#sops -c sops updatekeys secrets/secrets.yaml
   ```
6. Commit / push. Le nouveau PC peut maintenant déchiffrer.

> ⚠️ `updatekeys` doit être lancé depuis un PC qui peut **déjà** déchiffrer
> (il ré-ouvre le secret pour le re-sceller avec la clé en plus).

### Révoquer un PC

Retirer sa clé de `.sops.yaml`, `sops updatekeys secrets/secrets.yaml`, commit.
(Idéalement, faire aussi tourner les secrets compromis côté fournisseur.)

---

## 4. Réinstaller une machine

Tant que tu **restaures ta clé SSH** `~/.ssh/id_ed25519`, tu peux tout redéchiffrer.
Il suffit de régénérer le fichier age local :

```sh
mkdir -p ~/.config/sops/age
nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/.ssh/id_ed25519 \
  -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Aucun secret supplémentaire à migrer : **la clé SSH est la clé maîtresse**.

---

## Commandes utiles

```sh
sops secrets/secrets.yaml                  # editer (dechiffre en memoire)
sops -d secrets/secrets.yaml               # afficher en clair (stdout)
sops updatekeys secrets/secrets.yaml       # re-sceller apres changement de .sops.yaml
ssh-to-age < ~/.ssh/id_ed25519.pub         # cle publique age d'une machine
```

(préfixe par `nix shell nixpkgs#sops -c` / `nix shell nixpkgs#ssh-to-age -c`
si les outils ne sont pas encore dans le `$PATH`.)

---

## Rappels sécurité

- Le fichier `secrets.yaml` chiffré est **safe à committer**.
- `~/.config/sops/age/keys.txt` (clé privée) n'est **jamais** committé ni géré par Nix.
- Les fichiers déchiffrés sur disque (`~/.config/.../config`, `~/.gtask/...`) sont
  en `0400` mais **en clair** : c'est inévitable (les apps doivent les lire). La
  protection finale repose sur ta **clé SSH** + idéalement le **chiffrement de disque**.
- Les **tokens OAuth runtime** (`token.json`, `google-token.json`) sont mutables,
  réécrits par les apps → volontairement **hors sops**.
