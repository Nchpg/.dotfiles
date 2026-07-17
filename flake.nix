{
  description = "Nchpg configuration";

  inputs = {
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    stylix = {
      url = "github:nix-community/stylix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    claude-code = {
      # `git+https` (clone git anonyme) et PAS `github:` : ce dernier récupère
      # la source via l'API GitHub (api.github.com/tarball), qui exige un token
      # en CI et échoue en 401 « Bad credentials » sur le runner. Le clone git
      # HTTPS est anonyme sur un repo public, aucune auth requise.
      url = "git+https://github.com/sadjow/claude-code-nix";
      # Pas de `inputs.nixpkgs.follows` : volontaire. L'input garde le nixpkgs
      # pinné par l'upstream → cache binaire garanti et toujours la dernière
      # version de claude-code buildable (bump via `rebuild -u`).
    };

    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # Base nix-index pré-construite (hebdomadaire) : nix-locate, comma et les
    # suggestions command-not-found — la générer localement prend ~15 min.
    # Consommé par modules/user/nix-index (module HM importé dans profiles/).
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
  };

  outputs =
    inputs:
    let
      system = "x86_64-linux";
      lib = inputs.nixpkgs-stable.lib;

      # Instancie un nixpkgs : system + allowUnfree communs, overlays optionnels.
      mkPkgs =
        nixpkgs: overlays:
        import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
        };

      # pkgs-stable porte l'overlay DisplayLink : téléchargement automatique du
      # driver (dock Dell D3100), sinon nix-prefetch-url manuel sur chaque host.
      pkgs-stable = mkPkgs inputs.nixpkgs-stable [ (import ./overlays/displaylink.nix) ];
      pkgs-unstable = mkPkgs inputs.nixpkgs-unstable [ ];

      # Arguments injectés dans TOUS les modules : système (via specialArgs) et
      # home-manager (via extraSpecialArgs). Chacun y ajoute ensuite ses args
      # propres (target côté système, devShellNames côté HM).
      commonArgs = {
        inherit pkgs-stable pkgs-unstable inputs;
      };

      # Auto-découverte du contenu d'un dossier : sous-dossiers (profils, hosts)
      # ou fichiers .nix (devshells). Cf. lib/discover.nix.
      inherit (import ./lib/discover.nix lib) dirNames nixFileNames;

      profiles = dirNames ./profiles;
      hosts = dirNames ./hosts;

      # Variantes de thème : chaque couple profil×host produit une cible par
      # variante — `personal-gram` (dark, nom historique) et
      # `personal-gram-light`. La variante ne vit PAS dans la config (aucun
      # fichier à modifier pour toggler) : elle est portée par la cible, et
      # « l'état courant » est simplement la génération système active.
      # Bascule via la commande `theme` (cf. modules/system/stylix).
      variants = [
        "dark"
        "light"
      ];

      # Produit cartésien profils × hosts × variantes : une cible par combo,
      # sous forme { profile; host; variant; } (cf. targetName).
      targets = lib.cartesianProduct {
        profile = profiles;
        host = hosts;
        variant = variants;
      };

      targetName =
        target:
        "${target.profile}-${target.host}"
        + lib.optionalString (target.variant != "dark") "-${target.variant}";

      # Un devshell = un fichier devshells/<name>.nix ; auto-découvert comme
      # profiles/hosts ci-dessus. `dev-<name>` est généré à partir de la même
      # liste (cf. modules/user/shell) : un nouveau fichier = un nouveau
      # devShell + un nouvel alias, sans rien déclarer à la main.
      devShellNames = nixFileNames ./devshells;

      # Devshells qui doivent matcher la stack système (drivers unstable) au
      # lieu du pkgs-stable par défaut.
      unstableDevShells = [ "xpu" ];
    in
    {
      nixosConfigurations = builtins.listToAttrs (
        map (target: {
          name = targetName target;
          value = lib.nixosSystem {
            inherit system;
            modules = [
              # build host
              ./hosts
              # build profile
              ./profiles
              # system modules
              ./modules/system

              # Variante de thème portée par la cible (cf. `variants` plus haut).
              { systemSettings.stylix.variant = target.variant; }

              inputs.home-manager.nixosModules.home-manager
              {
                # Chaque user HM réutilise le `pkgs` du système au lieu
                # d'instancier son propre nixpkgs (~1 instanciation économisée
                # par user à l'éval). Corollaire : plus de `nixpkgs.*` dans les
                # configs home (ça devient une erreur d'éval).
                home-manager.useGlobalPkgs = true;
                # Paquets HM installés dans le profil système (/etc/profiles)
                # plutôt que dans ~/.nix-profile mutable de chaque user.
                home-manager.useUserPackages = true;
                # La config système est accessible dans les modules HM via
                # l'argument natif `osConfig` (ex. osConfig.systemSettings.*).
                home-manager.extraSpecialArgs = commonArgs // {
                  inherit devShellNames;
                };
              }
            ];
            specialArgs = commonArgs // {
              inherit target;
            };
          };
        }) targets
      );

      devShells.${system} = lib.genAttrs devShellNames (
        name:
        import (./devshells + "/${name}.nix") {
          pkgs = if builtins.elem name unstableDevShells then pkgs-unstable else pkgs-stable;
        }
      );

      # Validation des fonds d'écran : `nix build .#wallpapers-all` réalise
      # TOUTES les fetchurl du registre (modules/themes/wallpapers.nix). Les
      # URLs wallhaven/wallpaperflare sont éphémères, et seuls les fonds des
      # thèmes actifs sont téléchargés en temps normal : une URL morte ne se
      # découvrirait qu'au moment de sélectionner le thème concerné.
      packages.${system}.wallpapers-all =
        let
          themes = import ./modules/themes lib;
        in
        pkgs-stable.linkFarm "wallpapers-all" (
          map (name: {
            inherit name;
            path = themes.wallpaperPath pkgs-stable name;
          }) themes.wallpaperNames
        );

      # `nix fmt` → formate le repo. Voir formatter.nix pour le comportement.
      formatter.${system} = import ./formatter.nix { pkgs = pkgs-stable; };
    };
}
