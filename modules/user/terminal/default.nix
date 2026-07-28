{
  config,
  lib,
  osConfig,
  ...
}:

let
  cfg = config.userSettings;

  # Un émulateur de terminal n'a de sens que dans une session graphique.
  # Sur un profil headless (server), exiger qu'un user en ait un installerait
  # toute la pile GUI sur une machine sans écran.
  graphical =
    osConfig.systemSettings.windowManager.sway.enable
    || osConfig.systemSettings.windowManager.gnome.enable;

  # Un sous-dossier ici = un émulateur de terminal, sans exception : le
  # listing EST la liste des valeurs valides de `terminal.default`. Ne ranger
  # sous terminal/ que de vrais terminaux — tmux, longtemps `_tmux` pour être
  # écarté de cette enum, vit maintenant dans modules/user/tmux.
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
