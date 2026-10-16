lib:
{
  config,
  exec,
  title ? null,
  kittyExtraOpts ? "",
}:
let
  term = config.userSettings.terminal.default;
  extra = lib.optionalString (term == "kitty" && kittyExtraOpts != "") "${kittyExtraOpts} ";
  titleOpt = lib.optionalString (title != null) "--title ${lib.escapeShellArg title} ";
in
if term == "alacritty" then
  "${term} ${titleOpt}-e ${exec}"
else
  "${term} ${extra}${titleOpt}${exec}"
