{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.editors.neovim;

  # init.lua séparé (coloration syntaxique à l'édition) : valeurs dynamiques
  # injectées via placeholders @stylix_baseXX@.
  colors = myLib.theme.schemeColors { inherit config themes; };
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
    name: colors.${name}
  ) stylixColorNames) (builtins.readFile ./init.lua);
in
{
  options = {
    userSettings.editors.neovim = {
      enable = lib.mkEnableOption "Enable neovim";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = lib.mkIf cfg.enable {
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
          image-nvim # rendu d'images (backend kitty)

          # git
          vim-fugitive
          gitsigns-nvim

          # edition
          comment-nvim
          nvim-autopairs
          vim-surround
        ]
        # WakaTime : suivi du temps de code, partage la cfg sops (~/.wakatime.cfg)
        ++ lib.optional config.userSettings.editors.wakatime.enable cfg.pkgs.vimPlugins.vim-wakatime;

      extraPackages =
        myLib.packaging.editorLspPackages cfg.pkgs
        ++ (with cfg.pkgs; [
          gopls # go
          lua-language-server
          ripgrep # telescope live grep
          fd
          # image.nvim : rendu + rasterisation PDF/EPS (poppler-utils déclaré
          # ici et pas seulement via claude, sinon perdu sans ce module).
          imagemagick
          ghostscript
          poppler-utils
        ]);

      # Rock lua `magick` : extraLuaPackages matche la version de Neovim,
      # pas de conflit luajit.
      extraLuaPackages = ps: [ ps.magick ];

      initLua = initLuaContent;
    };
  };
}
