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
      # `git+https` et pas `github:` : ce dernier récupère la source via
      # l'API GitHub (tarball), qui exige un token et échoue en 401 en CI.
      url = "git+https://github.com/sadjow/claude-code-nix";
      # Pas de `inputs.nixpkgs.follows`, volontaire : garde le nixpkgs pinné
      # par l'upstream -> cache binaire garanti, bump via `rebuild -u`.
    };

    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # Base pré-construite : la générer localement prend ~15 min.
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # Registre base16/base24 upstream (~496 schemes), déjà tiré
    # transitivement par stylix mais posé ici en input EXPLICITE : on le
    # CONSOMME directement (modules/themes lit ses .yaml), un input qu'on
    # utilise ne doit pas être atteint en creusant dans ceux d'un autre.
    # `follows` (pas un `url` séparé) : une seule résolution dans le lock,
    # garantie identique à celle que stylix utilise déjà en interne — sinon
    # deux copies du registre pourraient diverger.
    tinted-schemes.follows = "stylix/tinted-schemes";
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

      # Overlay DisplayLink : téléchargement automatique du driver (dock Dell
      # D3100), sinon nix-prefetch-url manuel sur chaque host.
      pkgs-stable = mkPkgs inputs.nixpkgs-stable [ (import ./overlays/displaylink.nix) ];
      pkgs-unstable = mkPkgs inputs.nixpkgs-unstable [ ];

      # Injectés dans TOUS les modules (specialArgs système, extraSpecialArgs
      # HM). Chacun ajoute ensuite ses args propres.
      commonArgs = {
        inherit pkgs-stable pkgs-unstable inputs;
      };

      inherit (import ./lib/discover.nix lib) dirNames nixFileNames;

      profiles = dirNames ./profiles;
      hosts = dirNames ./hosts;

      # `personal-gram` (dark, nom historique) et `personal-gram-light`. La
      # variante ne vit pas dans la config : portée par la cible, "l'état
      # courant" est la génération système active (bascule via `theme`).
      variants = [
        "dark"
        "light"
      ];

      targets = lib.cartesianProduct {
        profile = profiles;
        host = hosts;
        variant = variants;
      };

      targetName =
        target:
        "${target.profile}-${target.host}"
        + lib.optionalString (target.variant != "dark") "-${target.variant}";

      # Un host se terminant par "-light"/"-dark" collisionne avec une autre
      # cible (host "x-light" en dark == host "x" en light) : listToAttrs
      # garderait silencieusement la première entrée, l'autre machine
      # deviendrait inatteignable. On échoue à l'éval à la place.
      targetNames =
        let
          names = map targetName targets;
          dupes = lib.unique (lib.filter (n: lib.count (x: x == n) names > 1) names);
        in
        lib.throwIf (dupes != [ ])
          "flake.nix : collision de noms de cibles (${lib.concatStringsSep ", " dupes}) — un nom de host ne doit pas se terminer par -dark ou -light."
          names;

      # Un fichier devshells/<name>.nix = un devShell + un alias `dev-<name>`
      # (modules/user/shell), sans rien déclarer à la main.
      devShellNames = nixFileNames ./devshells;

      unstableDevShells = [ "xpu" ];
    in
    {
      # zipListsWith plutôt que `map` : consommer `targetNames` force le
      # contrôle de collision ci-dessus (sinon jamais évalué).
      nixosConfigurations = builtins.listToAttrs (
        lib.zipListsWith (name: target: {
          inherit name;
          value = lib.nixosSystem {
            inherit system;
            modules = [
              ./hosts
              ./profiles
              ./modules/system

              { systemSettings.stylix.variant = target.variant; }

              inputs.home-manager.nixosModules.home-manager
              {
                # Réutilise le `pkgs` du système (~1 instanciation économisée
                # par user) : plus de `nixpkgs.*` dans les configs home,
                # deviendrait une erreur d'éval.
                home-manager.useGlobalPkgs = true;
                # Paquets HM dans le profil système (/etc/profiles), pas dans
                # ~/.nix-profile mutable de chaque user.
                home-manager.useUserPackages = true;
                home-manager.extraSpecialArgs = commonArgs // {
                  inherit devShellNames;
                };
                # Manpages générées PAR USER (3x ici) à chaque rebuild,
                # jamais consultées (doc en ligne).
                home-manager.sharedModules = [ { manual.manpages.enable = false; } ];
              }
            ];
            specialArgs = commonArgs // {
              inherit target;
            };
          };
        }) targetNames targets
      );

      devShells.${system} = lib.genAttrs devShellNames (
        name:
        import (./devshells + "/${name}.nix") {
          pkgs = if builtins.elem name unstableDevShells then pkgs-unstable else pkgs-stable;
        }
      );

      # `nix build .#wallpapers-all` réalise TOUTES les fetchurl du registre :
      # les URLs wallhaven/wallpaperflare sont éphémères, une URL morte ne se
      # découvrirait sinon qu'à la sélection du thème concerné.
      packages.${system}.wallpapers-all =
        let
          themes = import ./modules/themes lib inputs;
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
