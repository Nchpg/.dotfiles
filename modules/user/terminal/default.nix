{
  config,
  lib,
  osConfig,
  ...
}:

let
  cfg = config.userSettings;

  graphical =
    osConfig.systemSettings.windowManager.sway.enable
    || osConfig.systemSettings.windowManager.gnome.enable;

  terminals = lib.attrNames (
    lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./.)
  );
in
{
  options = {
    userSettings.terminal = {
      default = lib.mkOption {
        type = lib.types.enum terminals;
        default = builtins.head terminals;
        description = "Terminal by default";
      };
    };
  };
  config = {
    assertions = lib.mkIf (cfg.user != "root" && graphical) (
      [
        {
          assertion = lib.any (terminalName: cfg.terminal.${terminalName}.enable) terminals;
          message = "Au moins un terminal doit être activé";
        }
        {
          assertion = cfg.terminal."${cfg.terminal.default}".enable;
          message = "Le terminal par défaut \"${cfg.terminal.default}\" doit être activé";
        }
      ]
      ++ (lib.map (
        terminalName:
        let
          terminalOpts = cfg.terminal.${terminalName};
        in
        {
          assertion = if terminalOpts.enable then cfg.shell."${terminalOpts.shell}".enable else true;
          message = "Pour le terminal \"${terminalName}\", le shell associé \"${terminalOpts.shell}\" n'est pas activé.";
        }
      ) terminals)
    );
  };
}
