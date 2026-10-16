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

    # Valeurs chiffrées dans un dépôt privé (pourquoi : docs/secrets.md).
    secrets = {
      url = "github:Nchpg/secrets";
      flake = false;
    };

    claude-code = {
      # `git+https` et pas `github:` : le tarball de l'API GitHub échoue en 401 en CI.
      url = "git+https://github.com/sadjow/claude-code-nix";
      # Pas de `follows` : nixpkgs pinné par l'upstream pour le cache binaire.
    };

    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # Déploiement GitOps du serveur (modules/system/server/gitops).
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    tinted-schemes.follows = "stylix/tinted-schemes";
  };

  outputs =
    inputs:
    let
      system = "x86_64-linux";
      lib = inputs.nixpkgs-stable.lib;

      mkPkgs =
        nixpkgs: overlays:
        import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
        };

      pkgs-stable = mkPkgs inputs.nixpkgs-stable [
        (import ./overlays/displaylink)
        (import ./overlays/sway myLib)
      ];
      pkgs-unstable = mkPkgs inputs.nixpkgs-unstable [ ];

      dotsCommands = pkgs-stable.callPackage ./scripts {
        settings.DOTS_SOPS_MARKER = myLib.sops.policy.marker;
      };

      myLib = import ./lib lib;
      themes = import ./themes lib inputs;

      # Doit rester identique au calcul de `contentOf` dans modules/user/dotstate/dotstate.sh.
      dotfilesContent =
        let
          src = inputs.self.outPath;
          rel = f: lib.removePrefix "${toString src}/" (toString f);
          files = lib.sort (a: b: a < b) (map rel (lib.filesystem.listFilesRecursive src));
        in
        builtins.hashString "sha256" (
          lib.concatMapStrings (p: "${p} ${builtins.hashFile "sha256" "${src}/${p}"}\n") files
        );

      mkEvalCheck =
        name: check:
        lib.throwIf (!check.ok) check.report (
          pkgs-stable.runCommand name { } ''
            echo ${lib.escapeShellArg check.report}
            touch $out
          ''
        );

      dirNames =
        dir: lib.attrNames (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir dir));
      nixFileNames =
        dir:
        lib.pipe (builtins.readDir dir) [
          (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name))
          lib.attrNames
          (map (lib.removeSuffix ".nix"))
        ];

      commonArgs = {
        inherit
          pkgs-stable
          pkgs-unstable
          inputs
          myLib
          themes
          dotfilesContent
          ;
      };

      profiles = dirNames ./profiles;
      hosts = dirNames ./hosts;

      variants = [
        "dark"
        "light"
      ];

      targets = lib.cartesianProduct {
        profile = profiles;
        host = hosts;
        variant = variants;
      };

      targetName = myLib.flake.targetName.full;

      targetNames =
        let
          names = map targetName targets;
          dupes = lib.unique (lib.filter (n: lib.count (x: x == n) names > 1) names);
        in
        lib.throwIf (dupes != [ ])
          "flake.nix : collision de noms de cibles (${lib.concatStringsSep ", " dupes}) — un nom de host ne doit pas se terminer par -dark ou -light."
          names;

      devShellNames = nixFileNames ./devshells;

      unstableDevShells = [ "xpu" ];

      # zipListsWith : consommer `targetNames` force le contrôle de collision.
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

              inputs.sops-nix.nixosModules.sops
              inputs.comin.nixosModules.comin

              inputs.home-manager.nixosModules.home-manager
              {
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.extraSpecialArgs = commonArgs // {
                  inherit devShellNames;
                };
                home-manager.sharedModules = [ { manual.manpages.enable = false; } ];
              }
            ];
            specialArgs = commonArgs // {
              target = target // {
                inherit name;
                machine = myLib.flake.targetName.machine target;
              };
            };
          };
        }) targetNames targets
      );
    in
    {
      inherit nixosConfigurations;

      devShells.${system} = lib.genAttrs devShellNames (
        name:
        import (./devshells + "/${name}.nix") {
          pkgs = if builtins.elem name unstableDevShells then pkgs-unstable else pkgs-stable;
        }
      );

      packages.${system} = {
        commands = dotsCommands;

        sops-policy = pkgs-stable.writeShellScriptBin "sops-policy" ''
          cat ${
            pkgs-stable.writeText "creation-rules.yaml" (
              myLib.sops.policy.generate { inherit nixosConfigurations; }
            )
          }
        '';

        wallpapers-all = pkgs-stable.linkFarm "wallpapers-all" (
          map (name: {
            inherit name;
            path = themes.wallpaperPath pkgs-stable name;
          }) themes.wallpaperNames
        );
      };

      # `secrets` n'y est pas : elle exige les valeurs figées d'un système construit.
      apps.${system} = lib.genAttrs [ "rebuild" "update" "genclean" "dots" ] (c: {
        type = "app";
        program = "${dotsCommands}/bin/${c}";
        meta.description = "Commande `${c}` du dépôt (cf. scripts/)";
      });

      # Un seul `checks.${system}` : Nix ne fusionne pas deux chemins à segment dynamique.
      checks.${system} = {
        sops-policy = mkEvalCheck "check-sops-policy" (
          myLib.sops.checkPolicy {
            expected = myLib.sops.policy.generate { inherit nixosConfigurations; };
            inherit (myLib.sops.policy) marker;
            file = "${inputs.secrets}/.sops.yaml";
          }
        );

        option-paths =
          let
            any = builtins.head (lib.attrValues nixosConfigurations);
            anyUser = builtins.head (lib.attrValues any.config.home-manager.users);

            sys = myLib.flake.checkOptionPaths.byDeclarations {
              options = any.options.systemSettings;
              namespace = "systemSettings";
              tree = "system";
              transparentDirs = [ "server" ];
            };

            usr = myLib.flake.checkOptionPaths.byDirectory {
              inherit (anyUser) userSettings;
              root = ./modules/user;
              exceptions = [ "home-manager" ];
            };

          in
          mkEvalCheck "check-option-paths" {
            ok = sys.ok && usr.ok;
            report = "${sys.report}\n${usr.report}";
          };
      };

      formatter.${system} = import ./formatter.nix { pkgs = pkgs-stable; };
    };
}
