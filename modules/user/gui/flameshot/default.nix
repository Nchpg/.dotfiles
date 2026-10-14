{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.flameshot;

  # La surface de l'overlay couvre TOUT le layout (tous les écrans), mais
  # flameshot demande lui-même un plein écran sur UN output juste après le
  # map : sway y compresse l'image, et ça écrase un for_window. On attend
  # cette demande (sway_wait, lib/sway-wait.sh) puis on repasse en
  # `fullscreen global` (étalé 1:1).
  flameshotGui = cfg.pkgs.writeShellApplication {
    name = "flameshot-gui";
    runtimeInputs = [
      cfg.package
      osConfig.programs.sway.package # swaymsg
      cfg.pkgs.jq
    ];
    text = myLib.swayWaitSh + ''
      QT_QPA_PLATFORM=wayland QT_QPA_PLATFORMTHEME=xdgdesktopportal flameshot gui &
      sway_wait 40 0.05 '.. | objects | select(.type == "con" and .name == "flameshot" and .fullscreen_mode == 1) | .id' >/dev/null \
        || exit 0
      exec swaymsg '[title="^flameshot$"] border none, fullscreen enable global'
    '';
  };
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
    ];

    # Intégration Sway, seulement si ce user a une session sway.
    home.file.".config/sway/conf.d/flameshot.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text =
            let
              grim = lib.getExe cfg.pkgs.grim;
              slurp = lib.getExe cfg.pkgs.slurp;
              wl-copy = "${cfg.pkgs.wl-clipboard}/bin/wl-copy";
            in
            ''
              # Daemon flameshot (Wayland natif) : indispensable pour le bouton Copier.
              # Le « gui » envoie l'image au daemon via DBus, et c'est lui qui la pose dans le
              # presse-papier et la maintient en vie après fermeture de l'éditeur.
              exec QT_QPA_PLATFORM=wayland ${lib.getExe cfg.package}

              # QT_QPA_PLATFORM=wayland : copie via KSystemClipboard (wlr-data-control),
              # actif seulement en Wayland natif. QT_QPA_PLATFORMTHEME=xdgdesktopportal :
              # boîte "Save" via le sélecteur de fichiers GTK.
              # Lancé via flameshot-gui (cf. plus haut) pour le multi-écran.
              bindsym Print exec ${lib.getExe flameshotGui}
              bindsym Shift+Print exec ${grim} -g "$(${slurp} -d)" - | ${wl-copy}
            '';
        };

    # `buttons` est un blob QVariant Qt5 ("please don't edit by hand").
    # flameshot.ini ne tolère pas de commentaires, d'où la doc ici :
    #   useGrimAdapter=true      -> capture via grim (flameshot compilé wlrSupport)
    #   disabledGrimWarning=true -> coupe le warning "grim = wlroots" (13+)
    home.file.".config/flameshot/flameshot.ini".source = ./flameshot.ini;
  };
}
