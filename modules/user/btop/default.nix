{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.btop;

  # btop amont (<= 1.4.7) hardcode `device = "i915"` (issue btop#1407) : sur
  # driver `xe` (Lunar Lake, Battlemage, Arc récents), le GPU n'apparaît pas.
  # Source overridée avec la PR #1457 (deveworld:feature/xe-gpu-support, non
  # mergée -> à retirer une fois mergée, repasser xeGpuSupport = false), qui
  # ajoute le support xe via sysfs/gtidle + fdinfo. Doit souvent tourner en
  # root (`sudo btop`) pour voir le GPU.
  # Base = btop unstable 1.4.6, celle sur laquelle la PR est basée (évite un
  # mismatch packaging/source en greffant sur la stable 1.4.4).
  btopXe = pkgs-unstable.btop.overrideAttrs (_old: {
    src = pkgs-unstable.fetchFromGitHub {
      owner = "deveworld";
      repo = "btop";
      rev = "0785ff37592458cc3b48a4b705e86e378efdf222"; # PR #1457, tip du 17 avr. 2026
      sha256 = "01wfqhpc6zfkag07cdvs41435pq6shqq2xmwp70pd17zjaylxz6h";
    };

    # versionCheckPhase échoue (binaire 1.4.6 != 1.4.7 attendu du paquet amont).
    doInstallCheck = false;
  });
in
{
  options = {
    userSettings.btop = {
      enable = lib.mkEnableOption "Enable btop";
      pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
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
