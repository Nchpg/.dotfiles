# Dotfiles NixOS

Configuration NixOS + home-manager en flake, multi-hosts et multi-profils.

## Structure

```
flake.nix          Entrée : inputs, produit cartésien profils×hosts×variantes, devshells
hosts/             Un dossier par machine (hardware + réglages liés au matériel)
  gram/            LG Gram 2024 (hardware-configuration.nix généré + choix manuels)
profiles/          Un dossier par usage (personal, work, …) : quels modules
  personal/        sont activés, pour quels users, avec quels réglages
    home/<user>/   userSettings de chaque user du profil
modules/
  system/          Modules NixOS, gatés par des options systemSettings.*
  user/            Modules home-manager, gatés par des options userSettings.*
themes/            Thèmes base16 (schemes/*.yaml) + wallpapers + fonts + galerie
lib/               Helpers injectés en `myLib` (import-all, discover, mk-*, checks)
overlays/          Overlays nixpkgs (displaylink : fetch auto du driver)
docs/              Documentation longue (docs/secrets.md : sops, clés, enrôlement)
devshells/         `nix develop .#python|c|xpu`
init.sh            Enrôlement d'une machine neuve : jeton, clés age, clone des secrets
rebuild.sh         Script de rebuild (enrobé par la commande `rebuild`)
genclean.sh        Nettoyage interactif des générations (commande `genclean`)
formatter.nix      `nix fmt` (nixfmt sur les fichiers trackés)
statix.toml        Config du linter statix
```

## Cibles du flake : produit cartésien profils × hosts × variantes

Les `nixosConfigurations` sont **auto-découvertes** : chaque dossier de
`profiles/` croisé avec chaque dossier de `hosts/` donne une cible par
variante de thème — `<profil>-<host>` (dark, nom historique, ex.
`personal-gram`) et `<profil>-<host>-light`. Aucune liste à maintenir dans
`flake.nix` — ajouter un dossier suffit. Le hostname de la machine est
`<profil>-<host>` quelle que soit la variante (basculer le thème ne change
pas le hostname).

- **Ajouter un host** : `hosts/<nom>/` avec son `hardware-configuration.nix`
  (généré par `nixos-generate-config`) et, si besoin, un `configuration.nix`
  pour les réglages matériels manuels (importé automatiquement s'il existe).
- **Ajouter un profil** : partir d'une copie de `profiles/personal/`, puis
  régler `systemSettings` (users, modules activés) et `home/<user>/`.
- **Ajouter un user** : l'ajouter à `systemSettings.users` dans le profil et
  créer `profiles/<profil>/home/<user>/default.nix`. Le compte système, le
  home-manager et les groupes (wheel/docker/libvirt selon les flags) suivent.

## Principes des modules

- Tous les fichiers `.nix` de `modules/system` et `modules/user` sont importés
  automatiquement (`lib/import-all.nix`) ; chaque module est **inerte tant que
  son option `enable` n'est pas activée** par le profil ou le host.
- Côté home-manager, la config système est accessible via l'argument natif
  `osConfig` (ex. `osConfig.systemSettings.stylix.theme`).
- Deux nixpkgs disponibles partout : `pkgs-stable` (défaut) et `pkgs-unstable`
  (opt-in par module via son option `pkgs`).

## Commandes du quotidien

| Commande | Effet |
|---|---|
| `rebuild` | Rebuild de la cible de ce système (check git, diff nvd, reload sway/waybar) |
| `rebuild -u` | Idem + bump de l'input claude-code et de chaque module à `update.sh` (confirmation par module) |
| `rebuild -y` | Idem sans confirmation si le working tree est sale |
| `theme dark\|light\|toggle` | Bascule le thème (persistant) puis rebuild |
| `nix fmt` | Formate le repo (nixfmt-rfc-style) |
| `git config core.hooksPath .githooks` | Active le hook pre-commit (une fois par clone) : formate les `.nix` stagés |
| `nix flake check` | Vérifie l'évaluation du flake |
| `secrets` / `secrets user` | Édite les secrets système / les tiens (voir `docs/secrets.md`) |

## Secrets

Gérés par sops-nix, mais **pas dans ce dépôt** : les valeurs chiffrées vivent
dans un dépôt privé, tiré comme entrée `secrets` du flake. Publier des valeurs
emballées en X25519 revenait à en offrir une copie permanente à qui saura casser
la courbe elliptique, et l'historique git rend ça irréversible.

Deux fichiers, deux classes de destinataires : `system.yaml` n'est déchiffrable
que par root sur les machines, `secrets.yaml` par ta clé utilisateur. Détails et
procédures : `docs/secrets.md`.
