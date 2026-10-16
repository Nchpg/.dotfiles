{
  config,
  lib,
  ...
}:

let
  cfg = config.userSettings.ssh;
in
{
  options.userSettings.ssh = {
    hosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          serveur = {
            HostName = "192.168.1.32";
            Port = 3249;
            User = "moi";
          };
        }
      '';
      description = ''
        Blocs de `programs.ssh.settings` : la clé est le motif `Host`, les
        attributs portent les noms d'options OpenSSH (`HostName`, `Port`, `User`).
        Préférer une adresse à un nom pour une machine à adresse statique.
      '';
    };
  };

  config = lib.mkIf (cfg.hosts != { }) {
    programs.ssh = {
      enable = true;
      settings = cfg.hosts;

      enableDefaultConfig = false;
    };
  };
}
