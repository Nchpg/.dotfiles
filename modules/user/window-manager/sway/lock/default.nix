{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.lock;
  inherit (cfg) pkgs;

  swaymsgBin = "${osConfig.programs.sway.package}/bin/swaymsg";

  # Réduite à 1920 px : le flou est calculé au verrouillage, une 4K le rallongerait.
  lockFallbackImage =
    lib.optionalString (config.userSettings.stylix.enable && config.stylix.image != null)
      (
        " --image "
        + pkgs.runCommand "lock-fallback.png" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
          magick ${config.stylix.image} -resize '1920x1080^' $out
        ''
      );

  lockArgsNoCapture =
    "--clock --indicator"
    + " --color ${config.lib.stylix.colors.base00}"
    + lockFallbackImage
    + " --indicator-radius 150 --indicator-thickness 7 --effect-blur 7x5"
    + " --effect-vignette 0.5:0.5 --ring-color bb00cc --key-hl-color 880033"
    + " --line-color 00000000 --inside-color 00000088 --separator-color 00000000";
  lockArgs = "--screenshots " + lockArgsNoCapture;
  # Pas de fondu sur before-sleep : la veille le gèle et il reprendrait au réveil
  fadeArgs = "--fade-in 1";
  # Grâce uniquement pour le verrou d'inactivité : une grâce restante au réveil
  # déverrouillerait sans mot de passe.
  graceArgs = "--grace 2";
  # Sans le patch, brancher un écran pendant le verrou tue swaylock. Le build échoue
  # si un fichier patché change : retester avec `swaymsg create_output`, màj empreintes.
  swaylockPackage = myLib.packaging.mkGuardedPatch {
    package = pkgs.swaylock-effects;
    patch = ./swaylock-effects-defer-ack.patch;
    files = {
      "main.c" = "091f2a07579124c1a7f30977432edbde45bef2243fd81248cdbfbabf4b136956";
      "render.c" = "4cfb98b4f31231217a090a7ca6ec9131976ce6f28bfcb45a726a56c5fcbc125e";
      "include/swaylock.h" = "deaf48855906eccb3ede3ef15a05bad64fed8d93fa0615b7492566ed1f71b673";
    };
    where = "modules/user/window-manager/sway/lock/default.nix";
  };
  swaylockBin = "${swaylockPackage}/bin/swaylock";
  pgrep = "${pkgs.procps}/bin/pgrep";
  pkill = "${pkgs.procps}/bin/pkill";
  sleep = "${pkgs.coreutils}/bin/sleep";
  ps = "${pkgs.procps}/bin/ps";
  user = config.home.username;
  lockCmd = "${swaylockBin} ${lockArgs} ${fadeArgs}";
  # -u : ignorer les swaylock d'un autre compte.
  lockBindCmd = "${pgrep} -u ${user} -x swaylock >/dev/null || ${lockCmd}";
  # -f requis : swayidle attend la fin de la commande before-sleep
  lockCmdIdle = "${swaylockBin} -f ${lockArgs} ${fadeArgs} ${graceArgs}";
  # Remplace un swaylock encore en grâce (< 3 s), dont la grâce gelée échouerait le
  # verrou. SIGTERM ne déverrouille pas ; remplaçant sans capture (fond rouge).
  # Chemins absolus : le PATH de swayidle n'a pas coreutils.
  lockCmdBeforeSleep = pkgs.writeShellScript "lock-before-sleep" ''
    pids=$(${pgrep} -u ${user} -x swaylock)
    if [ -n "$pids" ]; then
      for pid in $pids; do
        age=$(${ps} -o etimes= -p "$pid") || continue
        [ "$age" -lt 3 ] || exit 0
      done
      ${pkill} -u ${user} -x swaylock
      for _ in {1..40}; do
        ${pgrep} -u ${user} -x swaylock >/dev/null || break
        ${sleep} 0.05
      done
      exec ${swaylockBin} -f ${lockArgsNoCapture}
    fi
    exec ${swaylockBin} -f ${lockArgs}
  '';

  # N'inhibe QUE le capot, pas `sleep` (UPower doit agir à batterie critique).
  # swaylock garde la dernière valeur d'une option répétée : d'où l'ordre après lockArgs.
  awakeArgs =
    "--ring-color ${config.lib.stylix.colors.base09}"
    + " --key-hl-color ${config.lib.stylix.colors.base0A}"
    + " --datestr Éveillé";

  awake = pkgs.writeShellApplication {
    name = "awake";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      exec systemd-inhibit --what=handle-lid-switch --mode=block \
        --who=awake --why="Session verrouillée, éveillée capot fermé (awake)" \
        ${swaylockBin} ${lockArgs} ${fadeArgs} ${awakeArgs}
    '';
  };

  internalOutput = ''
    internal=$(swaymsg -t get_outputs | jq -r '[.[] | select(.name | test("^eDP"))][0].name // empty')
    [ -n "$internal" ] || exit 0
  '';

  # Pas d'extinction si une veille suit : le swaylock de before-sleep doit pouvoir capturer l'écran.
  lidClose = pkgs.writeShellApplication {
    name = "lid-close";
    runtimeInputs = [
      osConfig.programs.sway.package
      pkgs.systemd
      pkgs.gawk
      pkgs.jq
    ];
    text = internalOutput + ''
      if systemd-inhibit --list --no-legend --no-pager \
        | awk '$1 == "awake" && $3 == "${user}" { found = 1 } END { exit !found }' \
        || swaymsg -t get_outputs \
        | jq -e --arg internal "$internal" '[.[] | select(.active and .name != $internal)] | length > 0' >/dev/null; then
        exec swaymsg output "$internal" power off
      fi
    '';
  };
  lidOpen = pkgs.writeShellApplication {
    name = "lid-open";
    runtimeInputs = [
      osConfig.programs.sway.package
      pkgs.jq
    ];
    text = internalOutput + ''
      exec swaymsg output "$internal" power on
    '';
  };
in
{
  options.userSettings.windowManager.sway.lock = {
    enable = lib.mkEnableOption "verrouillage de la session sway (swaylock, swayidle, awake)" // {
      default = config.userSettings.windowManager.sway.enable;
    };
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [
          awake
          swaylockPackage
        ];

        home.file.".config/sway/conf.d/lock.conf".text = ''
          # --locked : doit marcher aussi sur l'écran rouge (swaylock mort)
          bindsym --locked Control+Escape exec ${lockBindCmd}

          bindswitch --locked lid:on exec ${lib.getExe lidClose}
          bindswitch --locked lid:off exec ${lib.getExe lidOpen}
        '';

        services.swayidle = {
          enable = true;
          package = pkgs.swayidle;
          timeouts = [
            {
              timeout = 600;
              command = lockCmdIdle;
            }
            {
              timeout = 900;
              command = "${swaymsgBin} 'output * power off'";
              resumeCommand = "${swaymsgBin} 'output * power on'";
            }
            {
              timeout = 1800;
              command = "systemctl suspend";
            }
          ];
          events."before-sleep" = "${lockCmdBeforeSleep}";
        };
      }

      (lib.mkIf config.userSettings.windowManager.sway.rofi.enable (
        myLib.desktop.mkRofiAction {
          inherit config;
          name = "awake";
          label = "Awake";
          comment = "Verrouiller en restant éveillé capot fermé";
          exec = "awake";
          color = config.lib.stylix.colors.withHashtag.base09;
          path = "M4 10 h12 v4 a5 5 0 0 1 -5 5 h-2 a5 5 0 0 1 -5 -5 z M16 11 h1.5 a2.5 2.5 0 0 1 0 5 H16 M8 3 v4 M12 3 v4";
        }
      ))
    ]
  );
}
