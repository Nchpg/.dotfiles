{ config, lib, ... }:

let
  cfg = config.userSettings.volumeMixer;
  term = config.userSettings.terminal.default;

  termCmd = import ../../../lib/mk-terminal-cmd.nix {
    inherit lib term;
    title = "ncpamixer";
    exec = "ncpamixer";
    kittyExtraOpts = "-o window_padding_width=20";
  };
in
{
  options.userSettings.volumeMixer = {
    # Suit waybar : l'entrée "mixer" du menu volume ouvre ce module.
    enable = lib.mkEnableOption "mixeur audio (ncpamixer dans terminal flottant)" // {
      default = config.userSettings.waybar.enable;
    };
    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (import ../../../lib/mk-floating-tui-launcher.nix {
        name = "volume-mixer";
        scriptBody = "exec ${termCmd}";
        keybind = "$mod+p";
        title = "ncpamixer";
        width = 1200;
        height = 850;
      })
      { home.packages = [ cfg.pkgs.ncpamixer ]; }
    ]
  );
}
