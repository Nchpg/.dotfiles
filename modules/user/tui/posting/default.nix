{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.tui.posting;
  c = (myLib.theme.schemeColors { inherit config themes; }).withHashtag;
in
{
  options.userSettings.tui.posting = {
    enable = lib.mkEnableOption "Enable posting (TUI HTTP client)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.posting ];

    xdg.configFile."posting/config.yaml".text = ''
      theme: stylix
      watch_themes: false
    '';

    # posting cherche ses thèmes dans ~/.local/share/posting/themes (xdg.dataFile).
    xdg.dataFile."posting/themes/stylix.yaml".text = ''
      name: stylix
      primary: "${c.base0D}"
      secondary: "${c.base0B}"
      accent: "${c.base0D}"
      background: "${c.base00}"
      surface: "${c.base01}"
      panel: "${c.base01}"
      foreground: "${c.base05}"
      error: "${c.base08}"
      success: "${c.base0B}"
      warning: "${c.base0A}"
    '';
  };
}
