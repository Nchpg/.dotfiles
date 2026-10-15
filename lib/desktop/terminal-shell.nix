# Le shell lancé par les terminaux (modules terminal/* : alacritty, foot,
# kitty) et par tmux. Exposé sous myLib.desktop.
{
  # Option "shell" répétée à l'identique dans les modules terminal/* : quel
  # shell lancer dans ce terminal, par défaut celui de userSettings.shell.default.
  mkTerminalShellOption =
    { config, lib }:
    lib.mkOption {
      type = lib.types.str;
      default = config.userSettings.shell.default;
      description = "Shell to use";
    };

  # Chemin store du binaire de ce shell (`shell` : valeur de l'option
  # ci-dessus), avec le `pkgs` du module qui l'installe.
  mkTerminalShellBin = { pkgs, shell }: "${pkgs."${shell}"}/bin/${shell}";
}
