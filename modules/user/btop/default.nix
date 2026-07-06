{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.userSettings.btop;

  # ---------------------------------------------------------------------------
  # Support GPU Intel « xe »
  #
  # btop amont (jusqu'à la 1.4.7 incluse) ne sait lire que le driver `i915` :
  # il hardcode `device = "i915"` (cf. issue aristocratos/btop#1407). Sur les
  # iGPU/dGPU récents pilotés par le driver `xe` (Lunar Lake, Battlemage,
  # Arc récents…), le GPU n'apparaît tout simplement pas dans btop — alors que
  # nvtop le voit, car nvtop gère `xe`.
  #
  # On override la source avec la PR #1457 (deveworld:feature/xe-gpu-support)
  # qui ajoute le support `xe` via sysfs (`gtidle`) + fdinfo, sans toucher aux
  # fichiers IGT importés. Commit épinglé pour la reproductibilité.
  #
  # ⚠️  PR NON MERGÉE : à réévaluer/retirer une fois mergée en amont (il suffira
  #     alors de repasser `xeGpuSupport = false`). Le binaire doit souvent être
  #     lancé en root (`sudo btop`) pour voir le GPU.
  # ---------------------------------------------------------------------------
  # On part de la btop unstable (1.4.6) : c'est la version sur laquelle la PR
  # est basée. L'utiliser comme base évite un mismatch packaging/source (cmake,
  # thèmes…) qu'on aurait en greffant la source 1.4.6 sur la stable 1.4.4.
  btopXe = pkgs-unstable.btop.overrideAttrs (_old: {
    src = pkgs-unstable.fetchFromGitHub {
      owner = "deveworld";
      repo = "btop";
      rev = "0785ff37592458cc3b48a4b705e86e378efdf222"; # PR #1457, tip du 17 avr. 2026
      sha256 = "01wfqhpc6zfkag07cdvs41435pq6shqq2xmwp70pd17zjaylxz6h";
    };

    # La source PR #1457 est basée sur btop 1.4.6 ; le paquet amont est passé en
    # 1.4.7 → le versionCheckPhase échoue (binaire 1.4.6 ≠ 1.4.7 attendu). On le
    # désactive : on utilise sciemment une source différente de l'amont.
    doInstallCheck = false;
  });
in {
  options = {
    userSettings.btop = {
      enable = lib.mkEnableOption "Enable btop";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
      xeGpuSupport = lib.mkEnableOption "support du driver GPU Intel xe (PR #1457, non mergée)";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.btop = {
      enable = true;
      package = if cfg.xeGpuSupport then btopXe else cfg.pkgs.btop;

      # Affiche le GPU dans sa propre box (gpu0) au lieu de le mixer dans la box
      # CPU — équivalent d'appuyer sur « 5 » dans btop, mais par défaut.
      # show_gpu_info=Off évite le doublon (GPU à la fois dans le CPU et sa box).
      settings = lib.mkIf cfg.xeGpuSupport {
        shown_boxes = "cpu gpu0 mem net proc";
        show_gpu_info = "Off";
      };
    };

    # Stylix applique la palette base16 du système au thème btop.
    stylix.targets.btop.enable = true;
  };
}
