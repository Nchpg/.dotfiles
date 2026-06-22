{ config, lib, inputs, ... }:

let
  cfg = config.userSettings.spotify;

  # Paquets spicetify (extensions / thèmes) pour la plateforme courante.
  spicePkgs = inputs.spicetify-nix.legacyPackages.${cfg.pkgs.stdenv.hostPlatform.system};

  # Couleurs Stylix (base16) -> color.ini spicetify. base16 renvoie déjà du hex
  # SANS '#', ce qui est exactement le format attendu par color.ini.
  c = config.lib.stylix.colors;
  stylixColorScheme = {
    text                = c.base05;
    subtext             = c.base04;
    sidebar-text        = c.base05;
    main                = c.base00;
    sidebar             = c.base01;
    player              = c.base01;
    card                = c.base01;
    shadow              = c.base00;
    selected-row        = c.base04;
    button              = c.base0D;
    button-active       = c.base0D;
    button-disabled     = c.base03;
    tab-bar             = c.base01;
    notification        = c.base0D;
    notification-error  = c.base08;
    misc                = c.base03;
  };
  # Adblock niveau RÉSEAU (LD_PRELOAD) : abba23/spotify-adblock, compilé depuis
  # la source (pas dans nixpkgs). Contrairement aux extensions spicetify qui
  # manipulent le player (et cassaient la lecture de certaines pistes, ex.
  # « you're not able to play this content »), il bloque juste les domaines de
  # pub -> aucune incidence sur la lecture. config.toml fourni (allowlist).
  spotifyAdblock = cfg.pkgs.rustPlatform.buildRustPackage {
    pname = "spotify-adblock";
    version = "1.1.0";
    src = cfg.pkgs.fetchFromGitHub {
      owner = "abba23";
      repo = "spotify-adblock";
      rev = "v1.1.0";
      hash = "sha256-Em8ICO+GtA1k/urBA7e9+OdZmHvthTy+iRWueUz4+40=";
    };
    cargoHash = "sha256-gxGetdqaoJa/ZF1VnW6UXJyJfLBGZxZnyKpT/Qk/8Og=";
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

  # Indicateur SNI Spotify : script Python (pygobject) enrobé avec les bons
  # typelibs GObject-Introspection (gtk3 + ayatana-appindicator) via
  # wrapGAppsHook, et le PATH runtime (playerctl + swaymsg).
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
        --prefix PATH : ${lib.makeBinPath [
          cfg.pkgs.playerctl
          cfg.pkgs.sway
        ]}
      runHook postInstall
    '';
  };
in
{
  options.userSettings.spotify = {
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

    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };

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
    programs.spicetify = {
      enable = true;
      spotifyPackage = cfg.pkgs.spotify;

      # Pas d'extension adblock spicetify : elles manipulent le player et
      # cassaient la lecture de certaines pistes. Le blocage de pub est fait par
      # spotify-adblock (LD_PRELOAD, niveau réseau) injecté au lancement.
      # spicetify ne sert donc plus qu'au thème.
      enabledExtensions = [ ];
    }
    # Theming optionnel : seulement si un thème est demandé.
    // lib.optionalAttrs (cfg.theme != "") {
      theme = spicePkgs.themes.${cfg.theme};
      customColorScheme = lib.mkIf cfg.stylixColors stylixColorScheme;
    };

    # Indicateur SNI : PAS de démon au login. Il est lancé à l'ouverture de
    # Spotify, puis persiste (icône en tray) jusqu'à « Quitter », exactement
    # comme Teams. On l'embarque + on redirige l'entrée de menu « Spotify »
    # vers lui (le binaire spotify-tray-custom ouvre Spotify et reste en tray ;
    # un 2e lancement se contente de focus/relancer Spotify).
    home.packages = lib.mkIf cfg.tray.enable [ spotifyTray ];

    xdg.desktopEntries = lib.mkIf cfg.tray.enable {
      spotify = {
        name = "Spotify";
        genericName = "Music Player";
        exec = "spotify-tray-custom";
        icon = "spotify-client";
        terminal = false;
        categories = [ "Audio" "Music" "Player" "AudioVideo" ];
        settings.StartupWMClass = "Spotify";
      };
    };

    # Liste de domaines pub/allowlist lue par spotify-adblock au runtime.
    xdg.configFile."spotify-adblock/config.toml" = lib.mkIf cfg.adblock {
      source = "${spotifyAdblock}/share/spotify-adblock/config.toml";
    };
  };
}
