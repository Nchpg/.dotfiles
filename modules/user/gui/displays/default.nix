{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.displays;
  inherit (cfg) pkgs;

  # nwg-displays se redimensionne ~0,5s après l'ouverture : on attend que la taille
  # se stabilise avant de recentrer la fenêtre.
  scriptDeps = [
    osConfig.programs.sway.package
    pkgs.jq
    pkgs.gnugrep
    pkgs.coreutils
    pkgs.procps
  ];

  nwg-displays-wrapped = pkgs.writeShellApplication {
    name = "nwg-displays";
    runtimeInputs = scriptDeps;
    text = myLib.desktop.swayWaitSh + ''
      # Pas de `grep -q` : SIGPIPE de swaymsg ferait échouer le test sous pipefail
      if swaymsg -t get_tree | grep '"nwg-displays"' >/dev/null; then
        exec swaymsg '[app_id="nwg-displays"] kill'
      fi

      # Écran focus mémorisé avant que la fenêtre hors-écran ne passe sur un autre
      out="$(swaymsg -t get_outputs | jq -r '.[] | select(.focused).name')"

      ${pkgs.nwg-displays}/bin/nwg-displays >/dev/null 2>&1 &

      if ! sway_wait_stable 40 0.25 '.. | objects | select(.app_id? == "nwg-displays").rect | "\(.width)x\(.height)"' >/dev/null; then
        swaynag -t error -m "nwg-displays : la fenêtre ne s'est pas stabilisée (timeout)."
        exit 1
      fi

      exec swaymsg "[app_id=\"nwg-displays\"] move container to output \"$out\", resize set 1250 800, move position center, focus; mode \"displays\""
    '';
  };

  mirror = pkgs.writeShellApplication {
    name = "mirror";
    runtimeInputs = scriptDeps ++ [ pkgs.wl-mirror ];
    text = ''
      if pkill -x wl-mirror; then
        exit 0
      fi

      internal=$(swaymsg -t get_outputs \
        | jq -r '.[] | select(.name | test("^eDP")) | .name' | head -n1)
      external=$(swaymsg -t get_outputs \
        | jq -r '.[] | select(.active and (.name | test("^eDP") | not)) | .name' | head -n1)

      if [ -z "$external" ]; then
        swaynag -t warning -m "Clonage : aucun écran externe détecté."
        exit 1
      fi

      exec wl-mirror --fullscreen-output "$external" "$internal"
    '';
  };
in
{
  options.userSettings.gui.displays = {
    enable = lib.mkEnableOption "gestion des écrans externes / HDMI via la GUI nwg-displays";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    # hiPrio : le wrapper et le paquet fournissent tous deux bin/nwg-displays
    home.packages = [
      (lib.hiPrio nwg-displays-wrapped)
      pkgs.nwg-displays
      pkgs.wlr-randr
      pkgs.wl-mirror
    ];

    # ~/.config/sway/outputs est écrit par nwg-displays : pas de home.file (read-only)
    home.file.".config/sway/conf.d/displays.conf".text = ''
      include ~/.config/sway/outputs

      for_window [app_id="nwg-displays"] floating enable, border pixel 2, move position 100000 100000

      bindsym $mod+o exec nwg-displays
      bindsym $mod+Shift+o exec ${lib.getExe mirror}

      mode "displays" {
        bindsym q [app_id="nwg-displays"] kill; mode default
        bindsym Escape [app_id="nwg-displays"] kill; mode default
        bindsym $mod+o [app_id="nwg-displays"] kill; mode default
      }
    '';
  };
}
