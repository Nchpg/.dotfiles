# Dotfiles NixOS

Configuration NixOS + home-manager en flake, multi-hosts et multi-profils.

## Structure

```
flake.nix          Entrée : inputs, produit cartésien profils×hosts×variantes, devshells
hosts/             Un dossier par machine (hardware + réglages liés au matériel) ;
                   default.nix dit quelle machine fait tourner quel profil
  gram/            LG Gram 2024 (portable, profil personal)
  think/           serveur maison (profil server)
profiles/          Un dossier par usage : quels modules sont activés, pour
                   quels users, avec quels réglages
  personal/        poste de travail (bureau sway, apps, dev)
  server/          services auto-hébergés (nginx, Authelia, Nextcloud…)
    home/<user>/   userSettings de chaque user du profil
modules/
  system/          Modules NixOS, gatés par des options systemSettings.*
  user/            Modules home-manager, gatés par des options userSettings.*
themes/            Thèmes base16 (schemes/*.yaml) + wallpapers + fonts + galerie
lib/               Helpers injectés en `myLib` (import-all, discover, mk-*, checks)
overlays/          Overlays nixpkgs (displaylink : fetch auto du driver)
docs/              Documentation (secrets-guide.md : quoi taper ; secrets.md : le pourquoi)
devshells/         `nix develop .#python|c|xpu`
init.sh            Mise en place d'une machine neuve : host, matériel, clés age, SSH GitHub, clone des secrets, hooks, inscription
scripts/           Les commandes du dépôt (rebuild, update, genclean, secrets, dots, theme), installées en un paquet (default.nix) ; lib/ : bash partagé, CI comprise
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
| `dots` | Menu : choisis une commande ci-dessous puis un usage courant (exemples expliqués) ou tes propres arguments ; `dots help` liste tout |
| `rebuild` | Rebuild de la cible de ce système (check git, diff nvd, reload sway/waybar) |
| `update` | Vérifie en parallèle les modules à `update.sh` et les inputs du flake, puis propose de cocher quoi mettre à jour (sans rebuild) ; `-c` liste seulement, `-y` prend la sélection par défaut, `update NOM` restreint |
| `rebuild -u` | `update`, puis rebuild |
| `rebuild -y` | Idem sans confirmation si le working tree est sale |
| `theme dark\|light\|toggle` | Bascule le thème (persistant) puis rebuild |
| `nix fmt` | Formate le repo (nixfmt-rfc-style) |
| `git config core.hooksPath .githooks` | Active les hooks (fait par `./init.sh`) : formatage des `.nix` au commit, dépôt de secrets tenu en phase au pull/push |
| `nix flake check` | Vérifie l'évaluation du flake |
| `nix run .#rebuild -- -p <profil> -H <host>` | Les commandes (aussi `update`, `genclean`, `dots`) sur une machine pas encore construite, dépendances comprises |
| `secrets edit\|show\|list\|sync\|status\|policy` | Édite et synchronise les secrets (voir `docs/secrets-guide.md`) |

## Secrets

Gérés par sops-nix, mais **pas dans ce dépôt** : les valeurs chiffrées vivent
dans un dépôt privé, tiré comme entrée `secrets` du flake. Publier des valeurs
emballées en X25519 revenait à en offrir une copie permanente à qui saura casser
la courbe elliptique, et l'historique git rend ça irréversible.

Un fichier par secret, scellé pour les seules machines dont la config le
déclare : clé système (root) pour un secret lu par un service, clé de ton compte
pour un secret lu par tes outils. Quoi taper : `docs/secrets-guide.md` ; le
pourquoi : `docs/secrets.md`.
