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
      url = "git+https://github.com/sadjow/claude-code-nix";
      # Pas de `inputs.nixpkgs.follows` : volontaire. L'input garde le nixpkgs
      # pinné par l'upstream → cache binaire garanti et toujours la dernière
      # version de claude-code buildable (bump via `rebuild -u`).
    };

    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
  };

  outputs =
    inputs@{ self, ... }:
    let
      system = "x86_64-linux";

      pkgs-stable = import inputs.nixpkgs-stable {
        inherit system;
        config.allowUnfree = true;
      };

      pkgs-unstable = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };

      lib = inputs.nixpkgs-stable.lib;
      profiles = builtins.filter (x: x != null) (
        lib.mapAttrsToList (name: value: if value == "directory" then name else null) (
          builtins.readDir ./profiles
        )
      );
      hosts = builtins.filter (x: x != null) (
        lib.mapAttrsToList (name: value: if value == "directory" then name else null) (
          builtins.readDir ./hosts
        )
      );

      targets = lib.concatMap (
        profile:
        map (host: {
          inherit profile;
          inherit host;
        }) hosts
      ) profiles;
    in
    {
      nixosConfigurations = builtins.listToAttrs (
        map (target: {
          name = "${target.profile}-${target.host}";
          value = lib.nixosSystem {
            inherit system;
            modules = [
              # build host
              ./hosts
              # build profile
              ./profiles
              # system modules
              ./modules/system

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
                home-manager.extraSpecialArgs = {
                  inherit pkgs-unstable;
                  inherit pkgs-stable;
                  inherit inputs;
                  inherit self;
                };
              }
            ];
            specialArgs = {
              inherit pkgs-stable;
              inherit pkgs-unstable;
              inherit inputs;
              inherit target;
            };
          };
        }) targets
      );

      # `nix fmt` → formate le repo. Exposé aussi pour les éditeurs/CI.
      formatter.${system} = pkgs-stable.nixfmt-rfc-style;

      devShells.${system} = {
        python = import ./devshells/python.nix { pkgs = pkgs-stable; };
        c = import ./devshells/c.nix { pkgs = pkgs-stable; };
        # Intel Arc / XPU PyTorch — uses pkgs-unstable to match the system
        # graphics stack (intel-compute-runtime / level-zero).
        xpu = import ./devshells/xpu.nix { pkgs = pkgs-unstable; };
      };

    };
}
