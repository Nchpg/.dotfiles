{ config, lib, ... }:

let
  cfg = config.userSettings;

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
    # Le shell de chaque terminal a déjà `shell.default` comme défaut (option
    # `shell` de chaque module terminal). L'ancien genAttrs qui le re-posait ici
    # en priorité normale écrasait silencieusement les valeurs mkDefault des
    # profils (ex. guest : alacritty.shell = "bash" était ignoré).

    # ERROR HANDLING
    assertions = lib.mkIf (cfg.user != "root") (
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
