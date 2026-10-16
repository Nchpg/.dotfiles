{
  mkTerminalShellOption =
    { config, lib }:
    lib.mkOption {
      type = lib.types.str;
      default = config.userSettings.shell.default;
      description = "Shell to use";
    };

  mkTerminalShellBin = { pkgs, shell }: "${pkgs."${shell}"}/bin/${shell}";
}
