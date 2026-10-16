{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.git.tig;
in
{
  options = {
    userSettings.git.tig = {
      enable = lib.mkEnableOption "Enable tig";

      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = with cfg.pkgs; [
      tig
    ];

    home.file.".tigrc".text = ''
      color cursor                        default     default     reverse
      color title-focus                   8           default
      color title-blur                    8           default

      bind generic D >sh -c "git show %(commit) | delta --paging always --side-by-side"

      bind generic v >sh -c "git show %(commit):%(file) | bat --color=always --paging=always --style=plain -n --pager 'less -c -R' --file-name \"%(file)\""

      bind generic <Esc>[1;5A move-up
      bind generic <Esc>[1;5B move-down
    '';
  };
}
