{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.btop;

  # btop amont <= 1.4.7 hardcode i915 (btop#1407) : GPU absent sous xe. Override PR #1457 épinglé par update.sh.
  # EXPIRE: override btop, cf. https://github.com/aristocratos/btop/pull/1457
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

      # GPU dans sa propre box ; show_gpu_info=Off évite le doublon avec la box CPU.
      settings = lib.mkIf cfg.xeGpuSupport {
        shown_boxes = "cpu gpu0 mem net proc";
        show_gpu_info = "Off";
      };
    };

    stylix.targets.btop.enable = true;
  };
}
