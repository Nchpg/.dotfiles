{
  config,
  lib,
  osConfig,
  inputs,
  ...
}:

let
  keyOwner = osConfig.systemSettings.sops.keyOwner;

  # Réserve : root réutilise le keyFile du keyOwner (qui peut le remplacer) ; un secret sensible sous root doit passer par sops.secrets système.
  hasSopsAccess = config.userSettings.user == keyOwner || config.userSettings.user == "root";
in
{
  options.userSettings.sops.available = lib.mkOption {
    type = lib.types.bool;
    readOnly = true;
    description = ''
      Vrai si ce user a accès aux secrets sops (keyOwner ou root). Permet aux
      modules qui déclarent des secrets d'asserter avec un message clair. Ne
      vérifie que le droit d'accès, pas la présence de la clé.
    '';
  };

  # Hors du mkIf, avec un défaut seulement : une option ajoutée fuiterait dans le manifeste JSON.
  options.sops.secrets = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config.sopsFile = lib.mkDefault "${inputs.secrets}/${name}.yaml";
        }
      )
    );
  };

  config = {
    userSettings.sops.available = hasSopsAccess;

    home.packages = lib.mkIf (config.userSettings.user == keyOwner) (
      with config.userSettings.defaultPkgs;
      [
        sops
        age
        ssh-to-age
      ]
    );

    # `cloudflare/api_token` ne va qu'à think-sys, jamais à une clé de compte.
    sops = lib.mkIf hasSopsAccess {
      defaultSopsFormat = "yaml";

      age = {
        keyFile = "/home/${keyOwner}/.config/sops/age/keys.txt";
        generateKey = false;
      };
    };
  };
}
