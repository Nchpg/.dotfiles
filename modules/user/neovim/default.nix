{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.userSettings.neovim;

  # init.lua séparé (coloration syntaxique à l'édition) : valeurs dynamiques
  # injectées via placeholders @stylix_baseXX@.
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
      pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
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
        ++ lib.optional config.userSettings.wakatime.enable cfg.pkgs.vimPlugins.vim-wakatime;

      extraPackages = with pkgs-stable; [
        nil # nix
        nixfmt # formateur de `nix fmt` et du hook pre-commit, pas nixpkgs-fmt
        clang-tools # c/cpp
        pyright # python
        gopls # go
        lua-language-server
        ripgrep # telescope live grep
        fd
        # image.nvim : rendu + rasterisation PDF/EPS (poppler-utils déclaré
        # ici et pas seulement via claude, sinon perdu sans ce module).
        imagemagick
        ghostscript
        poppler-utils
      ];

      # Rock lua `magick` : extraLuaPackages matche la version de Neovim,
      # pas de conflit luajit.
      extraLuaPackages = ps: [ ps.magick ];

      initLua = initLuaContent;
    };
  };
}
