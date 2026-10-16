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
        # auto-safe seul essaie Vulkan Video avant VA-API, non géré par le GPU
        hwdec = "vaapi,auto-safe";
        vo = "gpu-next";
      };
      profiles."extension.gif" = {
        loop-file = "inf";
      };
    };
  };
}
