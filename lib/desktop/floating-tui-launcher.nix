lib:
let
  mkTerminalCmd = import ./terminal-cmd.nix lib;
in
{
  config,
  name,
  confName ? name,
  exec,
  env ? { },
  kittyExtraOpts ? "",
  preamble ? "",
  keybind,
  # Ancré ^…$ : sinon un onglet Firefox contenant le nom passait en flottant.
  title,
  width,
  height,
}:
let
  termCmd = mkTerminalCmd {
    inherit
      config
      exec
      title
      kittyExtraOpts
      ;
  };
  envPrefix = lib.concatMapAttrsStringSep "" (n: v: "${n}=${lib.escapeShellArg v} ") env;
in
{
  home.file.".config/sway/launchers/${name}" = {
    text = ''
      #!/bin/sh
      ${preamble}${envPrefix}exec ${termCmd}
    '';
    executable = true;
  };

  home.file.".config/sway/conf.d/${confName}.conf".text = ''
    bindsym ${keybind} exec ~/.config/sway/launchers/${name}
    for_window [title="^${title}$"] floating enable, resize set ${toString width} ${toString height}, border pixel 2
  '';
}
