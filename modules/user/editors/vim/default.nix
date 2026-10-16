{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.editors.vim;
in
{
  options = {
    userSettings.editors.vim = {
      enable = lib.mkEnableOption "Enable vim";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {

    programs.vim = {
      enable = true;

      plugins =
        with cfg.pkgs.vimPlugins;
        [
          gruvbox
          vim-polyglot
          vim-airline
          vim-airline-themes
          vim-fugitive
          vim-gitgutter
          vim-commentary
          nerdtree
          coc-nvim
        ]
        ++ lib.optional config.userSettings.editors.wakatime.enable vim-wakatime;

      extraConfig = ''
        ${builtins.readFile ./vim-config/.vimrc}
        execute 'set runtimepath+=' . expand('~/.vim/airline')

        ${
          # base16-stylix absent sans stylix (E185) : repli gruvbox.
          if config.userSettings.stylix.enable then
            ''
              colorscheme base16-stylix
              let g:airline_theme='base16_${
                lib.strings.replaceStrings [ "-" ] [ "_" ] config.userSettings.stylix.theme
              }'
            ''
            + lib.optionalString (config.userSettings.stylix.theme == "gruvbox-dark-custom") ''
              let g:airline_theme='powerline'
            ''
          else
            ''
              colorscheme gruvbox
              let g:airline_theme='powerline'
            ''
        }
      '';

    };

    home.packages =
      with cfg.pkgs;
      [
        nodejs
        powerline-fonts
      ]
      ++ myLib.packaging.editorLspPackages cfg.pkgs;

    home.file = {
      ".vim/airline/autoload/airline/themes/powerline.vim".source = ./vim-config/powerline.vim;
      ".vim/coc-settings.json".source = ./vim-config/coc-settings.json;
      ".clang-format".source = ./vim-config/.clang-format;
    };

    stylix.targets.vim.enable = true;
  };

}
