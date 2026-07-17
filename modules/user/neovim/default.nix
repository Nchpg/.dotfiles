{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.userSettings.neovim;

  # init.lua vit dans un fichier séparé (coloration syntaxique Lua à l'édition,
  # comme sway/config.template ou vscode/settings.json) : les seules valeurs
  # dynamiques (palette Stylix, cf. Telescope) sont injectées via placeholders
  # @stylix_baseXX@.
  stylixColorNames = [
    "base00"
    "base01"
    "base02"
    "base03"
    "base05"
    "base0A"
    "base0D"
  ];
  initLuaContent = lib.replaceStrings (map (name: "@stylix_${name}@") stylixColorNames) (map (
    name: config.lib.stylix.colors.${name}
  ) stylixColorNames) (builtins.readFile ./init.lua);
in
{
  options = {
    userSettings.neovim = {
      enable = lib.mkEnableOption "Enable neovim";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Stylix colore Neovim avec la même palette base16 que le shell et VSCode.
    stylix.targets.neovim.enable = true;

    programs.neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      # 26.05 a basculé ces défauts à false ; on garde l'ancien comportement.
      withRuby = true;
      withPython3 = true;

      plugins =
        with cfg.pkgs.vimPlugins;
        [
          # telescope + deps
          plenary-nvim
          nvim-web-devicons
          telescope-nvim
          telescope-fzf-native-nvim

          # treesitter
          nvim-treesitter.withAllGrammars

          # lsp
          nvim-lspconfig

          # completion
          nvim-cmp
          cmp-nvim-lsp
          cmp-buffer
          cmp-path
          luasnip
          cmp_luasnip

          # ui
          lualine-nvim
          nvim-tree-lua
          image-nvim # rendu d'images (backend kitty) dans Markdown + API

          # git
          vim-fugitive
          gitsigns-nvim

          # edition
          comment-nvim
          nvim-autopairs
          vim-surround
        ]
        # WakaTime : suivi du temps de code, partage la cfg sops (~/.wakatime.cfg)
        ++ lib.optional config.userSettings.wakatime.enable cfg.pkgs.vimPlugins.vim-wakatime;

      extraPackages = with pkgs-stable; [
        # language servers
        nil # nix
        nixpkgs-fmt
        clang-tools # c/cpp
        pyright # python
        gopls # go
        lua-language-server
        # telescope live grep
        ripgrep
        fd
        # image.nvim : traitement d'images, + ghostscript pour rasteriser PDF/EPS,
        # + poppler-utils (pdftoppm/pdftotext) déclaré ICI — avant, il n'arrivait
        # que via le module claude : neovim sans claude perdait le rendu PDF.
        imagemagick
        ghostscript
        poppler-utils
      ];

      # image.nvim a besoin du rock lua `magick` sur le luapath de Neovim.
      # extraLuaPackages fournit le set lua qui matche la version de Neovim,
      # donc pas de conflit luajit (cf. note pkgs-stable plus haut).
      extraLuaPackages = ps: [ ps.magick ];

      initLua = initLuaContent;
    };
  };
}
