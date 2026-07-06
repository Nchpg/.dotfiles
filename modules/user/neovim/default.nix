{ config, lib, pkgs-stable, ... }:

let
  cfg = config.userSettings.neovim;
in {
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

      plugins = with cfg.pkgs.vimPlugins; [
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
        image-nvim   # rendu d'images (backend kitty) dans Markdown + API

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
        nil          # nix
        nixpkgs-fmt
        clang-tools  # c/cpp
        pyright      # python
        gopls        # go
        lua-language-server
        # telescope live grep
        ripgrep
        fd
        # image.nvim : traitement d'images, + ghostscript pour rasteriser PDF/EPS.
        # (pdftoppm/pdftotext viennent de poppler-utils, cf. modules/user/common.nix)
        imagemagick
        ghostscript
      ];

      # image.nvim a besoin du rock lua `magick` sur le luapath de Neovim.
      # extraLuaPackages fournit le set lua qui matche la version de Neovim,
      # donc pas de conflit luajit (cf. note pkgs-stable plus haut).
      extraLuaPackages = ps: [ ps.magick ];

      initLua = ''
        -- Options de base
        vim.opt.number = true
        vim.opt.relativenumber = true
        vim.opt.expandtab = true
        vim.opt.shiftwidth = 2
        vim.opt.tabstop = 2
        vim.opt.smartindent = true
        vim.opt.wrap = false
        vim.opt.termguicolors = true
        vim.opt.signcolumn = "yes"
        vim.opt.updatetime = 250
        vim.opt.splitbelow = true
        vim.opt.splitright = true
        vim.opt.scrolloff = 8
        vim.opt.mouse = "a"
        vim.opt.clipboard = "unnamedplus"

        vim.g.mapleader = " "

        -- Couleurs : le colorscheme base16 est injecté par Stylix
        -- (même palette exacte que le shell et le reste du système).

        -- Lualine
        require("lualine").setup({
          options = {
            theme = "auto",
            component_separators = { left = "|", right = "|" },
            section_separators = { left = "", right = "" },
          },
        })

        -- Telescope
        local telescope = require("telescope")
        local actions = require("telescope.actions")
        telescope.setup({
          defaults = {
            mappings = {
              i = {
                ["<C-k>"] = actions.move_selection_previous,
                ["<C-j>"] = actions.move_selection_next,
                ["<C-q>"] = actions.send_selected_to_qflist + actions.open_qflist,
                ["<Esc>"] = actions.close,
              },
            },
            file_ignore_patterns = { "%.git/", "node_modules/", "%.cache/" },
          },
        })
        telescope.load_extension("fzf")

        -- Telescope ne suit pas la palette base16 de Stylix par défaut
        -- (base16-nvim ne définit pas ses highlight groups), on les mappe
        -- explicitement sur les couleurs Stylix pour rester cohérent.
        local c = {
          base00 = "#${config.lib.stylix.colors.base00}", -- fond
          base01 = "#${config.lib.stylix.colors.base01}", -- fond clair
          base02 = "#${config.lib.stylix.colors.base02}", -- sélection
          base03 = "#${config.lib.stylix.colors.base03}", -- commentaires / bordures
          base05 = "#${config.lib.stylix.colors.base05}", -- texte
          base0A = "#${config.lib.stylix.colors.base0A}", -- match
          base0D = "#${config.lib.stylix.colors.base0D}", -- titres
        }
        local function tshl()
          local set = vim.api.nvim_set_hl
          -- fenêtres / fonds
          set(0, "TelescopeNormal",          { fg = c.base05, bg = c.base00 })
          set(0, "TelescopeResultsNormal",   { fg = c.base05, bg = c.base00 })
          set(0, "TelescopePreviewNormal",   { fg = c.base05, bg = c.base00 })
          set(0, "TelescopePromptNormal",    { fg = c.base05, bg = c.base01 })
          -- bordures (toutes mappées sur base03, plus aucun accent par défaut)
          set(0, "TelescopeBorder",          { fg = c.base03, bg = c.base00 })
          set(0, "TelescopeResultsBorder",   { fg = c.base03, bg = c.base00 })
          set(0, "TelescopePreviewBorder",   { fg = c.base03, bg = c.base00 })
          set(0, "TelescopePromptBorder",    { fg = c.base03, bg = c.base01 })
          -- titres
          set(0, "TelescopePromptTitle",     { fg = c.base00, bg = c.base0D, bold = true })
          set(0, "TelescopeResultsTitle",    { fg = c.base00, bg = c.base0D, bold = true })
          set(0, "TelescopePreviewTitle",    { fg = c.base00, bg = c.base0D, bold = true })
          -- prompt : préfixe et compteur (orange base09 par défaut → base0D)
          set(0, "TelescopePromptPrefix",    { fg = c.base0D, bg = c.base01 })
          set(0, "TelescopePromptCounter",   { fg = c.base03, bg = c.base01 })
          -- sélection
          set(0, "TelescopeSelection",       { fg = c.base05, bg = c.base02 })
          set(0, "TelescopeSelectionCaret",  { fg = c.base0D, bg = c.base02 })
          set(0, "TelescopeMultiSelection",  { fg = c.base05, bg = c.base02 })
          set(0, "TelescopeMultiIcon",       { fg = c.base0D })
          -- match
          set(0, "TelescopeMatching",        { fg = c.base0A, bold = true })
        end
        tshl()
        -- Stylix charge son colorscheme (base16-nvim) potentiellement APRÈS ce
        -- bloc : on réapplique sur ColorScheme, et une fois l'UI prête, pour
        -- garantir qu'on passe en dernier.
        vim.api.nvim_create_autocmd("ColorScheme", { callback = tshl })
        vim.api.nvim_create_autocmd("VimEnter", {
          callback = function() vim.schedule(tshl) end,
        })

        local builtin = require("telescope.builtin")
        vim.keymap.set("n", "<leader>ff", builtin.find_files,       { desc = "Find files" })
        vim.keymap.set("n", "<leader>fg", builtin.live_grep,        { desc = "Live grep" })
        vim.keymap.set("n", "<leader>fb", builtin.buffers,          { desc = "Buffers" })
        vim.keymap.set("n", "<leader>fh", builtin.help_tags,        { desc = "Help tags" })
        vim.keymap.set("n", "<leader>fr", builtin.oldfiles,         { desc = "Recent files" })
        vim.keymap.set("n", "<leader>fs", builtin.lsp_document_symbols, { desc = "Document symbols" })
        vim.keymap.set("n", "<leader>fd", builtin.diagnostics,      { desc = "Diagnostics" })

        -- Treesitter (nouvelle API nvim-treesitter + built-in Neovim 0.10+)
        vim.api.nvim_create_autocmd("FileType", {
          callback = function(args)
            pcall(vim.treesitter.start, args.buf)
          end,
        })

        -- nvim-tree
        require("nvim-tree").setup({
          view = { width = 30 },
          renderer = { group_empty = true },
          filters = { dotfiles = false },
        })
        vim.keymap.set("n", "<leader>e", ":NvimTreeToggle<CR>", { desc = "Toggle file tree" })

        -- Gitsigns
        require("gitsigns").setup({
          signs = {
            add          = { text = "+" },
            change       = { text = "~" },
            delete       = { text = "_" },
            topdelete    = { text = "‾" },
            changedelete = { text = "~" },
          },
        })
        vim.keymap.set("n", "<leader>gh", ":Gitsigns preview_hunk<CR>",  { desc = "Preview hunk" })
        vim.keymap.set("n", "<leader>gb", ":Gitsigns blame_line<CR>",    { desc = "Blame line" })

        -- image.nvim : rendu d'images via le protocole graphique kitty.
        -- tmux_show_only_in_active_window + le passthrough tmux (cf. module tmux)
        -- sont nécessaires pour que les images traversent tmux correctement.
        require("image").setup({
          backend = "kitty",
          processor = "magick_rock",
          integrations = {
            markdown = {
              enabled = true,
              only_render_image_at_cursor = false,
              filetypes = { "markdown", "vimwiki" },
            },
          },
          max_width = nil,
          max_height = nil,
          window_overlap_clear_enabled = true,
          tmux_show_only_in_active_window = true,
        })

        -- Comment
        require("Comment").setup()

        -- Autopairs
        require("nvim-autopairs").setup()

        -- LSP (nouvelle API Neovim 0.11 : vim.lsp.config / vim.lsp.enable)
        local capabilities = require("cmp_nvim_lsp").default_capabilities()

        -- Capabilities communes à tous les serveurs
        vim.lsp.config("*", { capabilities = capabilities })

        -- nvim-lspconfig fournit les configs de base (cmd, filetypes, root_markers)
        -- dans runtimepath/lsp/<server>.lua ; on se contente de les activer.
        vim.lsp.enable({ "nil_ls", "pyright", "gopls", "lua_ls", "clangd" })

        -- Keymaps LSP au moment de l'attach
        vim.api.nvim_create_autocmd("LspAttach", {
          callback = function(args)
            local opts = { buffer = args.buf }
            vim.keymap.set("n", "gd",  vim.lsp.buf.definition,     opts)
            vim.keymap.set("n", "gr",  vim.lsp.buf.references,     opts)
            vim.keymap.set("n", "K",   vim.lsp.buf.hover,          opts)
            vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename,  opts)
            vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
            vim.keymap.set("n", "<leader>lf", function() vim.lsp.buf.format({ async = true }) end, opts)
          end,
        })

        -- Complétion (nvim-cmp)
        local cmp = require("cmp")
        local luasnip = require("luasnip")
        cmp.setup({
          snippet = {
            expand = function(args) luasnip.lsp_expand(args.body) end,
          },
          mapping = cmp.mapping.preset.insert({
            ["<C-Space>"] = cmp.mapping.complete(),
            ["<CR>"]      = cmp.mapping.confirm({ select = true }),
            ["<Tab>"]     = cmp.mapping(function(fallback)
              if cmp.visible() then cmp.select_next_item()
              elseif luasnip.expand_or_jumpable() then luasnip.expand_or_jump()
              else fallback() end
            end, { "i", "s" }),
            ["<S-Tab>"]   = cmp.mapping(function(fallback)
              if cmp.visible() then cmp.select_prev_item()
              elseif luasnip.jumpable(-1) then luasnip.jump(-1)
              else fallback() end
            end, { "i", "s" }),
          }),
          sources = cmp.config.sources({
            { name = "nvim_lsp" },
            { name = "luasnip" },
            { name = "buffer" },
            { name = "path" },
          }),
        })

        -- Keymaps généraux
        vim.keymap.set("n", "<leader>w",  ":w<CR>",          { desc = "Save" })
        vim.keymap.set("n", "<leader>q",  ":q<CR>",          { desc = "Quit" })
        vim.keymap.set("n", "<leader>bd", ":bd<CR>",         { desc = "Close buffer" })
        vim.keymap.set("n", "<C-h>",      "<C-w>h",          { desc = "Move left" })
        vim.keymap.set("n", "<C-l>",      "<C-w>l",          { desc = "Move right" })
        vim.keymap.set("n", "<C-j>",      "<C-w>j",          { desc = "Move down" })
        vim.keymap.set("n", "<C-k>",      "<C-w>k",          { desc = "Move up" })
        vim.keymap.set("n", "<leader>gg", ":Git<CR>",        { desc = "Fugitive" })
      '';
    };
  };
}
