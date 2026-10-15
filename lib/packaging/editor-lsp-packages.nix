# Serveurs de langage communs à vim (coc, cf. vim-config/coc-settings.json) et
# neovim (lspconfig, cf. neovim/init.lua) : une liste, deux éditeurs. Chacun
# ajoute ensuite les siens.
pkgs: with pkgs; [
  nil # nix
  nixfmt # formateur de `nix fmt` et du hook pre-commit, pas nixpkgs-fmt
  clang-tools # c/cpp
  pyright # python
]
