# Chemin store du binaire shell choisi (option `shell` de mk-terminal-shell-option.nix),
# répété à l'identique dans les modules terminal/* (alacritty, foot, kitty).
{ pkgs, shell }:
"${pkgs."${shell}"}/bin/${shell}"
