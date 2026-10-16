{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.editors.neovim;

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
      # 26.05 a basculé ces défauts à false : on garde l'ancien.
      withRuby = true;
      withPython3 = true;

      plugins =
        with cfg.pkgs.vimPlugins;
        [
          plenary-nvim
          nvim-web-devicons
          telescope-nvim
          telescope-fzf-native-nvim

          nvim-treesitter.withAllGrammars

          nvim-lspconfig

          nvim-cmp
          cmp-nvim-lsp
          cmp-buffer
          cmp-path
          luasnip
          cmp_luasnip

          lualine-nvim
          nvim-tree-lua
          image-nvim

          vim-fugitive
          gitsigns-nvim

          comment-nvim
          nvim-autopairs
          vim-surround
        ]
        ++ lib.optional config.userSettings.editors.wakatime.enable cfg.pkgs.vimPlugins.vim-wakatime;

      extraPackages =
        myLib.packaging.editorLspPackages cfg.pkgs
        ++ (with cfg.pkgs; [
          gopls
          lua-language-server
          ripgrep
          fd
          # image.nvim : rendu + rasterisation PDF/EPS
          imagemagick
          ghostscript
          poppler-utils
        ]);

      # Rock lua `magick` : extraLuaPackages matche la version de Neovim.
      extraLuaPackages = ps: [ ps.magick ];

      initLua = initLuaContent;
    };
  };
}
