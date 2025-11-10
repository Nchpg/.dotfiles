{ config, lib, pkgs-stable, pkgs-unstable, stylix, ... }:

let
  cfg = config.userSettings.vim;
in {
  options = {
    userSettings.vim = {
      enable = lib.mkEnableOption "Enable vim";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {

    programs.vim = {
      enable = true;

      # Plugins gérés par Nix
      plugins = with cfg.pkgs.vimPlugins; [
        gruvbox
        vim-polyglot
        vim-airline
        vim-airline-themes
        vim-wakatime
        vim-fugitive
        vim-gitgutter
        vim-commentary
        nerdtree
        coc-nvim
      ];

      extraConfig = ''
        ${builtins.readFile ./vim-config/.vimrc}
        execute 'set runtimepath+=' . expand('~/.vim/airline')
        colorscheme base16-stylix
        let g:airline_theme='base16_${lib.strings.replaceStrings ["-"] ["_"] config.userSettings.stylix.theme}'
        
        ${lib.optionalString (config.userSettings.stylix.theme == "custom") ''
          set background=dark
          colorscheme gruvbox
          let g:airline_theme='powerline'
        ''}
        ${lib.optionalString (config.userSettings.stylix.theme == "gruvbox-dark-custom") ''
          let g:airline_theme='powerline'
        ''}
      '';

    };

    home.packages = with cfg.pkgs; [
      # for coc-nvim
      nodejs

      # font for vim-airline
      powerline-fonts

      ### language servers

      # c
      clang-tools

      #python
      pyright

      # nix
      nil
      nixpkgs-fmt
    ];

    home.file = {
      ".vim/airline/autoload/airline/themes/powerline.vim".source = ./vim-config/powerline.vim;
      ".vim/coc-settings.json".source = ./vim-config/coc-settings.json;
      ".clang-format".source = ./vim-config/.clang-format;
    };

    stylix.targets.vim.enable = true;
  };
}