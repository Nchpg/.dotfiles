# Option "shell" répétée à l'identique dans les modules terminal/*
# (alacritty, foot, kitty) : quel shell lancer dans ce terminal, par défaut
# celui de userSettings.shell.default.
{ config, lib }:
lib.mkOption {
  type = lib.types.str;
  default = config.userSettings.shell.default;
  description = "Shell to use";
}
