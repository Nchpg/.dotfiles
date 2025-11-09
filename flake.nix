{
  description = "Nchpg configuration";

  inputs = {
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    stylix = {
      url = "github:nix-community/stylix/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
  };

  outputs = inputs@{ self, ... }:
    let
      system = "x86_64-linux";

      pkgs-stable = import inputs.nixpkgs-stable {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };
      };

      pkgs-unstable = import inputs.nixpkgs-unstable {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };
      };

      lib = inputs.nixpkgs-stable.lib;
      profiles = builtins.filter (x: x != null) (lib.mapAttrsToList (name: value: if value == "directory" then name else null) (builtins.readDir ./profiles));
      hosts    = builtins.filter (x: x != null) (lib.mapAttrsToList (name: value: if value == "directory" then name else null) (builtins.readDir ./hosts));

      targets = lib.concatMap (profile: map (host: { profile = profile; host = host; }) hosts) profiles;
    in
    {
      nixosConfigurations = builtins.listToAttrs
        (map (target: {
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
              ({ config, ... }: {
                home-manager.extraSpecialArgs = {
                  inherit pkgs-unstable;
                  inherit pkgs-stable;
                  inherit inputs;
                  systemSettings = config.systemSettings; 
                };
              })
            ];
            specialArgs = {
              inherit pkgs-stable;
              inherit inputs;
              inherit target;
            };
          };
        }) targets);

    };
}

