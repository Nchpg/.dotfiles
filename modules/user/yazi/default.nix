{ config, lib, ... }:

let
  cfg = config.userSettings.yazi;
in
{
  options = {
    userSettings.yazi = {
      enable = lib.mkEnableOption "Enable yazi";

      pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {

    programs.yazi = {
      enable = true;
      package = cfg.pkgs.yazi;
      # 26.05 a changé le défaut du wrapper "yy" → "y" ; on garde "yy".
      shellWrapperName = "yy";
    };

    # Yazi thémé par Stylix : il utilise exactement la même palette base16 que
    # le shell (et suit le toggle dark/light). On NE met PAS de flavor manuel
    # ici, sinon il écrirait le même theme.toml → conflit avec Stylix.
    stylix.targets.yazi.enable = true;
  };
}
