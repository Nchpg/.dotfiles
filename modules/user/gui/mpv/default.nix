{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.mpv;
in
{
  options.userSettings.gui.mpv = {
    enable = lib.mkEnableOption "mpv (lecteur média)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    programs.mpv = {
      enable = true;
      package = cfg.pkgs.mpv;
      config = {
        # VA-API d'abord (auto-safe seul essaie avant Vulkan Video, non géré
        # par le GPU), puis tout décodeur matériel sûr, CPU en dernier. Sans
        # ça mpv décode tout en logiciel, même avec un driver fonctionnel.
        hwdec = "vaapi,auto-safe";
        vo = "gpu-next";
      };
      # Profil appliqué automatiquement par mpv aux .gif : en boucle comme dans
      # une visionneuse, au lieu de se fermer à la fin de la première lecture.
      profiles."extension.gif" = {
        loop-file = "inf";
      };
    };
  };
}
