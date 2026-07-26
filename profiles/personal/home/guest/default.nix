{
  pkgs-stable,
  pkgs-unstable,
  ...
}:

{
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix.enable = true;

      editors = {
        vim.enable = true;
        vscode = {
          enable = true;
          pkgs = pkgs-unstable;
        };
      };

      git.enable = true;

      browsers.firefox.enable = true;

      shell = {
        zsh.enable = true;
        bash.enable = true;
        default = "zsh";
      };

      terminal = {
        kitty.enable = true;
        foot.enable = false;
        alacritty = {
          enable = true;
          shell = "bash";
        };
        default = "kitty";
      };
    };
  };
}
