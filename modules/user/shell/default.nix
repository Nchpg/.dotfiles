{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.shell;
  
  shells = lib.attrNames (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./.));
in {
  options = {
    userSettings.shell = {
      default = lib.mkOption {
          type = lib.types.enum shells;
          default = builtins.head shells;
          description = "Shell by default";
      };
      list = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          readOnly = true;
          description = "List of available shells";
      };
    };
  };

  config = {
    userSettings.shell.list = shells;

    # ERROR HANDLING
    assertions = [
      {
        assertion = lib.any 
          (shellName: cfg."${shellName}".enable) 
          shells;
        message = "Au moins un shell doit être activé";
      }
      {
        assertion = cfg."${cfg.default}".enable;
        message = "Le shell par défaut \"${cfg.default}\" doit être activé";
      }
    ];
  };
}