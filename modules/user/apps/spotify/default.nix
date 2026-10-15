{
  config,
  lib,
  inputs,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.apps.spotify;

  # Paquets spicetify (extensions / thèmes) pour la plateforme courante.
  spicePkgs = inputs.spicetify-nix.legacyPackages.${cfg.pkgs.stdenv.hostPlatform.system};

  # base16 renvoie du hex sans '#', format attendu par color.ini.
  c = myLib.theme.schemeColors { inherit config themes; };
  stylixColorScheme = {
    text = c.base05;
    subtext = c.base04;
    sidebar-text = c.base05;
    main = c.base00;
    sidebar = c.base01;
    player = c.base01;
    card = c.base01;
    shadow = c.base00;
    selected-row = c.base04;
    button = c.base0D;
    button-active = c.base0D;
    button-disabled = c.base03;
    tab-bar = c.base01;
    notification = c.base0D;
    notification-error = c.base08;
    misc = c.base03;
  };
  # Adblock niveau RÉSEAU (LD_PRELOAD), pas dans nixpkgs. Contrairement aux
  # extensions spicetify qui manipulent le player (et cassaient la lecture de
  # certaines pistes), il bloque juste les domaines de pub.
  # Version + hashes épinglés automatiquement par update.sh
  adblockPinned = builtins.fromJSON (builtins.readFile ./pinned.json);
  spotifyAdblock = cfg.pkgs.rustPlatform.buildRustPackage {
    pname = "spotify-adblock";
    inherit (adblockPinned) version cargoHash;
    src = cfg.pkgs.fetchFromGitHub {
      owner = "abba23";
      repo = "spotify-adblock";
      rev = "v${adblockPinned.version}";
      inherit (adblockPinned) hash;
    };
    doCheck = false; # pas de tests amont
    # cdylib -> on installe le .so et la config nous-mêmes.
    installPhase = ''
      runHook preInstall
      install -Dm644 target/*/release/libspotifyadblock.so $out/lib/libspotifyadblock.so
      install -Dm644 config.toml $out/share/spotify-adblock/config.toml
      runHook postInstall
    '';
  };
  adblockLib = "${spotifyAdblock}/lib/libspotifyadblock.so";

  pyEnv = cfg.pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
  spotifyTray = cfg.pkgs.stdenv.mkDerivation {
    pname = "spotify-tray-custom";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [
      cfg.pkgs.wrapGAppsHook3
      cfg.pkgs.gobject-introspection
      cfg.pkgs.makeWrapper
    ];
    buildInputs = [
      cfg.pkgs.gtk3
      cfg.pkgs.libayatana-appindicator
      cfg.pkgs.libdbusmenu-gtk3
    ];
    installPhase = ''
      runHook preInstall
      install -Dm644 ${./spotify-tray.py} $out/libexec/spotify-tray.py
      makeWrapper ${pyEnv}/bin/python3 $out/bin/spotify-tray-custom \
        --add-flags $out/libexec/spotify-tray.py \
        ${lib.optionalString cfg.adblock "--set SPOTIFY_ADBLOCK_LIB ${adblockLib}"} \
        --prefix PATH : ${
          lib.makeBinPath [
            cfg.pkgs.playerctl
            cfg.pkgs.sway
          ]
        }
      runHook postInstall
    '';
  };
in
{
  options.userSettings.apps.spotify = {
    enable = lib.mkEnableOption "Spotify patché via spicetify (sans pub)";

    adblock = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Blocage des pubs via spotify-adblock (LD_PRELOAD, niveau réseau), injecté
        au lancement de Spotify par le tray. Mettre à false pour lancer Spotify
        SANS aucun bloqueur (utile pour diagnostiquer un souci de lecture).
      '';
    };

    pkgs = myLib.mkPkgsOption { inherit lib config; };

    theme = lib.mkOption {
      type = lib.types.str;
      default = "text";
      description = ''
        Thème spicetify à appliquer (cf. spicetify-nix `themes`, ex. "text",
        "default", "dribbblish", "catppuccin"). Mettre "" pour garder l'UI
        Spotify d'origine (extensions seules, aucun theming).
      '';
    };

    stylixColors = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Injecte les couleurs Stylix dans le thème (color.ini généré). Sans
        effet si `theme = ""`. Désactiver si le rendu casse après une MAJ.
      '';
    };

    tray.enable = lib.mkEnableOption ''
      indicateur SNI maison pour Spotify (icône de tray native, visible dans
      waybar quand Spotify tourne). Contourne l'absence de tray du client
      officiel via libayatana-appindicator (vrai StatusNotifierItem, contrairement
      à spotify-tray qui ne fait que du XEmbed invisible sous Sway)'';
  };

  config = lib.mkIf cfg.enable {
    # La lib d'adblock n'est injectée (LD_PRELOAD) que par le lanceur du tray :
    # sans lui, sa config est déployée mais Spotify démarre sans bloqueur.
    warnings = lib.optional (cfg.adblock && !cfg.tray.enable) ''
      userSettings.apps.spotify.adblock n'a aucun effet sans
      userSettings.apps.spotify.tray.enable : la bibliothèque n'est chargée
      que par spotify-tray-custom.
    '';

    programs.spicetify = {
      enable = true;
      spotifyPackage = cfg.pkgs.spotify;

      enabledExtensions = [ ]; # adblock fait par spotify-adblock, pas spicetify
    }
    // lib.optionalAttrs (cfg.theme != "") {
      theme = spicePkgs.themes.${cfg.theme};
      customColorScheme = lib.mkIf cfg.stylixColors stylixColorScheme;
    };

    # Pas de démon au login : lancé à l'ouverture de Spotify (comme Teams).
    home.packages = lib.mkIf cfg.tray.enable [ spotifyTray ];

    xdg.desktopEntries = lib.mkIf cfg.tray.enable {
      spotify = {
        name = "Spotify";
        genericName = "Music Player";
        exec = "spotify-tray-custom";
        icon = "spotify-client";
        terminal = false;
        categories = [
          "Audio"
          "Music"
          "Player"
          "AudioVideo"
        ];
        settings.StartupWMClass = "Spotify";
      };
    };

    xdg.configFile."spotify-adblock/config.toml" = lib.mkIf cfg.adblock {
      source = "${spotifyAdblock}/share/spotify-adblock/config.toml";
    };
  };
}
