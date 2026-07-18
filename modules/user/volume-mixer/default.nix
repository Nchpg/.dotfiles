{ config, lib, ... }:

let
  cfg = config.userSettings.volumeMixer;
  term = config.userSettings.terminal.default;

  # ncpamixer (ncurses) utilise la palette du terminal : il hérite donc
  # automatiquement du thème Stylix via le terminal (kitty).
  # Padding interne plus large que le terminal courant pour ne pas coller aux bords.
  padOpt = lib.optionalString (term == "kitty") "-o window_padding_width=20 ";
  termCmd =
    if term == "alacritty" then
      "${term} --title ncpamixer -e ncpamixer"
    else
      "${term} ${padOpt}--title ncpamixer ncpamixer";
in
{
  options.userSettings.volumeMixer = {
    # Défaut : suit waybar (l'entrée « mixer » du menu volume ouvre ce module).
    # Surchargeable : mettre false pour une waybar sans mixeur.
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
