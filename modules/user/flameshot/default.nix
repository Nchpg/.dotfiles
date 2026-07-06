{ config, lib, ... }:

let
  cfg = config.userSettings.flameshot;
in {
  options = {
    userSettings.flameshot = {
      enable = lib.mkEnableOption "flameshot (capture d'écran, Wayland natif sous Sway)";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.pkgs.flameshot.override { enableWlrSupport = true; };
        defaultText = "flameshot avec enableWlrSupport = true";
        description = ''
          flameshot compilé avec le support wlroots (enableWlrSupport). Sans ce
          flag il capture un écran noir sous Sway : il utilise alors grim pour la
          capture et KSystemClipboard (protocole wlr-data-control) pour la copie.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with cfg.pkgs; [
      cfg.package
      grim         # backend de capture wlroots (requis par flameshot)
      slurp        # sélection de zone
      wl-clipboard # wl-copy/wl-paste (utilisé aussi par le bind Shift+Print de Sway)
    ];

    # Config flameshot déclarative : barre d'outils sans Upload/Open With/Pin,
    # icône de barre désactivée (disabledTrayIcon). La clé `buttons` est un blob
    # QVariant Qt5 généré avec le Qt de flameshot ("please don't edit by hand").
    #
    # NB : l'intégration Sway (bind Print/Shift+Print, daemon flameshot lancé au
    # démarrage, règles for_window) vit dans modules/user/sway/sway-config, car
    # c'est de la syntaxe de config Sway, pas du Nix.
    # NB : flameshot.ini ne tolère PAS de commentaires (# rejeté : « Unrecognized
    # setting »), d'où la doc ici. Réglages Wayland du .ini :
    #   useGrimAdapter=true     -> capture via grim (flameshot compilé wlrSupport)
    #   disabledGrimWarning=true -> coupe le warning « grim = wlroots » (flameshot 13+)
    home.file.".config/flameshot/flameshot.ini".source = ./flameshot.ini;
  };
}
