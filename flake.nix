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

    # Valeurs chiffrées, dans un dépôt PRIVÉ à part. Ce dépôt-ci reste public.
    #
    # Pourquoi les avoir sorties : sops emballe sa clé de données en X25519, que
    # l'algorithme de Shor casse. Les publier revenait à offrir à qui veut une
    # copie permanente, déchiffrable le jour où les machines quantiques
    # arrivent, et l'historique git rend ça irréversible. Ça vidait de son sens
    # la clé pré-partagée WireGuard, dont le seul rôle est justement de protéger
    # du trafic enregistré aujourd'hui.
    #
    # `flake = false` : c'est de la donnée, pas un flake. On en tire un chemin
    # du store, consommé par modules/system/sops et modules/user/sops.
    #
    # ÉPINGLÉ par flake.lock, comme toute entrée, et c'est voulu : modifier le
    # dépôt de secrets ne change rien à ce que think déploie tant qu'un commit
    # explicite n'a pas bougé le lock ici. Le changement se voit dans un diff au
    # lieu d'arriver en douce la nuit suivante. La commande `secrets` enchaîne
    # les deux pour qu'on ne l'oublie pas.
    #
    # Dépôt privé, donc Nix a besoin d'un jeton de lecture pour le récupérer :
    # il est posé à la main sur chaque machine, cf. modules/system/nix.
    secrets = {
      url = "github:Nchpg/secrets";
      flake = false;
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
    # CONSOMME directement (themes/ lit ses .yaml), un input qu'on
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
      # D3100), sinon nix-prefetch-url manuel sur chaque host. Overlay sway :
      # sway-unwrapped patché (verrouillage sans flash noir, cf. le fichier).
      pkgs-stable = mkPkgs inputs.nixpkgs-stable [
        (import ./overlays/displaylink)
        (import ./overlays/sway myLib)
      ];
      pkgs-unstable = mkPkgs inputs.nixpkgs-unstable [ ];

      # Commandes du dépôt hors de tout système (apps, packages.commands) : seul
      # le marqueur sops est connu ici, le reste suit les défauts des scripts.
      dotsCommands = pkgs-stable.callPackage ./scripts {
        settings.DOTS_SOPS_MARKER = myLib.sopsPolicy.marker;
      };

      # Helpers du dépôt, agrégés une fois (cf. lib/default.nix) : les modules
      # les reçoivent en argument `myLib` au lieu de remonter jusqu'à lib/ par
      # des `../../../..` que le moindre déplacement de dossier casse.
      myLib = import ./lib lib;

      # API des thèmes (cf. themes/default.nix), injectée pour la même raison
      # que myLib : elle était atteinte par `../../themes` depuis six modules
      # à trois profondeurs différentes.
      themes = import ./themes lib inputs;

      # Empreinte du contenu de la config, gravée dans chaque système pour
      # `dotstate` (cf. lib/content-hash.nix) : calculée ici une seule fois.
      dotfilesContent = myLib.contentHash inputs.self.outPath;

      # Injectés dans TOUS les modules (specialArgs système, extraSpecialArgs
      # HM). Chacun ajoute ensuite ses args propres.
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

      inherit (myLib) dirNames nixFileNames;

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

      # Cf. lib/target-name.nix (partagé avec network, la politique sops…).
      targetName = myLib.targetName.full;

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

              # Volet SYSTÈME de sops-nix (le volet home-manager est monté par
              # profiles/default.nix). Lui seul écrit dans /run/secrets, d'où
              # lisent les units systemd. Configuré dans modules/system/sops.
              inputs.sops-nix.nixosModules.sops

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
            # `target.name` (personal-gram-light) et `target.machine`
            # (personal-gram, le hostname) : calculés une fois ici plutôt que
            # recomposés par chaque module.
            specialArgs = commonArgs // {
              target = target // {
                inherit name;
                machine = myLib.targetName.machine target;
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

      # `nix run .#sops-policy` : imprime le bloc `creation_rules` du .sops.yaml
      # du dépôt PRIVÉ (que `secrets policy` y pose et synchronise), déduit de
      # ce que les cibles DÉPLOYÉES déclarent (cf. lib/sops-policy.nix et
      # hosts/default.nix).
      #
      # Un `run` et pas un fichier commité ici : le .sops.yaml vit dans l'autre
      # dépôt, à côté des ancres de clés qui n'ont rien à faire dans celui-ci.
      # Ce qui reste ici, c'est la politique ; ce qui reste là-bas, les clés.
      packages.${system} = {
        # Les commandes du dépôt sans valeurs propres à un système (cf.
        # scripts/default.nix) : ce que lancent les apps ci-dessous.
        commands = dotsCommands;

        sops-policy = pkgs-stable.writeShellScriptBin "sops-policy" ''
          cat ${
            pkgs-stable.writeText "creation-rules.yaml" (
              myLib.sopsPolicy.generate { inherit nixosConfigurations; }
            )
          }
        '';

        # `nix build .#wallpapers-all` réalise TOUTES les fetchurl du registre :
        # les URLs wallhaven/wallpaperflare sont éphémères, une URL morte ne se
        # découvrirait sinon qu'à la sélection du thème concerné.
        wallpapers-all = pkgs-stable.linkFarm "wallpapers-all" (
          map (name: {
            inherit name;
            path = themes.wallpaperPath pkgs-stable name;
          }) themes.wallpaperNames
        );
      };

      # `nix run .#rebuild -- -p <profil> -H <host>` : les commandes sur une
      # machine NEUVE, avant le premier rebuild qui les installe — avec leurs
      # dépendances (gum…), contrairement à ./scripts/<commande>.sh. `secrets`
      # n'y est pas : elle exige les valeurs figées d'un système construit.
      apps.${system} = lib.genAttrs [ "rebuild" "update" "genclean" "dots" ] (c: {
        type = "app";
        program = "${dotsCommands}/bin/${c}";
        meta.description = "Commande `${c}` du dépôt (cf. scripts/)";
      });

      # UN SEUL attribut `checks.${system}`, et pas deux chemins qui le
      # partagent : Nix refuse de fusionner deux chemins d'attributs dont un
      # segment est dynamique (« dynamic attribute already defined »), et
      # `${system}` en est un.
      checks.${system} = {
        # La politique de ce dépôt-ci et le .sops.yaml du dépôt PRIVÉ disent la
        # même chose (cf. lib/check-sops-policy.nix). À l'ÉVAL, comme
        # option-paths juste en dessous (cf. lib/mk-eval-check.nix).
        sops-policy = myLib.mkEvalCheck {
          pkgs = pkgs-stable;
          name = "check-sops-policy";
          check = myLib.checkSopsPolicy {
            expected = myLib.sopsPolicy.generate { inherit nixosConfigurations; };
            inherit (myLib.sopsPolicy) marker;
            file = "${inputs.secrets}/.sops.yaml";
          };
        };

        # Miroir dossier <-> chemin d'option (cf. lib/check-option-paths.nix).
        # Échoue à l'ÉVAL et pas au build (cf. lib/mk-eval-check.nix) : `nix
        # flake check --no-build` en CI l'attrape sans rien construire.
        #
        # N'importe quelle cible / n'importe quel user fait l'affaire : les
        # `options` sont déclarées HORS des `mkIf`, elles existent donc même
        # pour un module désactivé. On prend les premières pour ne réintroduire
        # aucune liste en dur.
        option-paths =
          let
            any = builtins.head (lib.attrValues nixosConfigurations);
            anyUser = builtins.head (lib.attrValues any.config.home-manager.users);

            # Côté NixOS, `options` est exposé : on part des options déclarées
            # et on remonte au fichier déclarant.
            sys = myLib.checkOptionPaths.byDeclarations {
              options = any.options.systemSettings;
              namespace = "systemSettings";
              tree = "system";
              # `server/` regroupe les modules du rôle serveur sans nommer un
              # niveau d'option : `modules/system/server/authelia/` déclare bien
              # `systemSettings.authelia.*`. Le rôle est porté par le profil qui
              # active ces modules, le répéter dans chaque chemin n'y ajouterait
              # rien.
              transparentDirs = [ "server" ];
            };

            # Côté home-manager, les options par user ne sont pas introspectables
            # (elles viennent d'un `imports` du sous-module) : on part des
            # dossiers. Cf. lib/check-option-paths.nix.
            usr = myLib.checkOptionPaths.byDirectory {
              inherit (anyUser) userSettings;
              root = ./modules/user;
              # Module de base : porte userSettings.user et defaultPkgs, il n'a
              # volontairement pas de namespace à lui.
              exceptions = [ "home-manager" ];
            };

          in
          myLib.mkEvalCheck {
            pkgs = pkgs-stable;
            name = "check-option-paths";
            check = {
              ok = sys.ok && usr.ok;
              report = "${sys.report}\n${usr.report}";
            };
          };
      };

      # `nix fmt` → formate le repo. Voir formatter.nix pour le comportement.
      formatter.${system} = import ./formatter.nix { pkgs = pkgs-stable; };
    };
}
