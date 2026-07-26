{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.flameshot;
in
{
  options = {
    userSettings.gui.flameshot = {
      enable = lib.mkEnableOption "flameshot (capture d'écran, Wayland natif sous Sway)";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
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
      grim # backend de capture wlroots
      slurp # sélection de zone
      wl-clipboard # utilisé aussi par le bind Shift+Print de Sway
    ];

    # `buttons` est un blob QVariant Qt5 ("please don't edit by hand").
    # Intégration Sway (binds, daemon, for_window) dans sway-config, pas ici.
    # flameshot.ini ne tolère pas de commentaires, d'où la doc ici :
    #   useGrimAdapter=true      -> capture via grim (flameshot compilé wlrSupport)
    #   disabledGrimWarning=true -> coupe le warning "grim = wlroots" (13+)
    home.file.".config/flameshot/flameshot.ini".source = ./flameshot.ini;
  };
}
