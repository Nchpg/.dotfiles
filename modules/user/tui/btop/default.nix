{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.btop;

  # btop amont (<= 1.4.7) hardcode `device = "i915"` (issue btop#1407) : sur
  # driver `xe` (Lunar Lake, Battlemage, Arc récents), le GPU n'apparaît pas.
  # Source overridée avec la PR #1457 (deveworld:feature/xe-gpu-support), qui
  # ajoute le support xe via sysfs/gtidle + fdinfo.
  # Doit souvent tourner en root (`sudo btop`) pour voir le GPU.
  # Une fois la PR mergée : retirer btopXe et repasser xeGpuSupport = false.
  # EXPIRE: override btop, cf. https://github.com/aristocratos/btop/pull/1457
  # Base = btop unstable 1.4.6, celle sur laquelle la PR est basée (évite un
  # mismatch packaging/source en greffant sur la stable 1.4.4).
  # Dépôt et commit de la branche de la PR épinglés par update.sh, qui suit
  # sa tête et signale le merge (moment de retirer cet override).
  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);
  btopXe = pkgs-unstable.btop.overrideAttrs (_old: {
    src = pkgs-unstable.fetchFromGitHub {
      inherit (pinned)
        owner
        repo
        rev
        hash
        ;
    };

    # versionCheckPhase échoue (binaire 1.4.6 != 1.4.7 attendu du paquet amont).
    doInstallCheck = false;
  });
in
{
  options = {
    userSettings.tui.btop = {
      enable = lib.mkEnableOption "Enable btop";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      xeGpuSupport = lib.mkEnableOption "support du driver GPU Intel xe (PR #1457, non mergée)";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.btop = {
      enable = true;
      package = if cfg.xeGpuSupport then btopXe else cfg.pkgs.btop;

      # GPU dans sa propre box (gpu0), show_gpu_info=Off évite le doublon
      # avec la box CPU.
      settings = lib.mkIf cfg.xeGpuSupport {
        shown_boxes = "cpu gpu0 mem net proc";
        show_gpu_info = "Off";
      };
    };

    stylix.targets.btop.enable = true;
  };
}
