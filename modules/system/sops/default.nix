{ config, lib, ... }:

{
  # Déclare qui détient la clé age de la machine. Consommé par le module
  # home-manager modules/user/sops (chemin du keyFile + installation des
  # outils d'édition pour ce user uniquement). Défini par le profil.
  options = {
    systemSettings.sops = {
      keyOwner = lib.mkOption {
        type = lib.types.str;
        example = "nchpg";
        description = ''
          Utilisateur qui détient la clé age (~/.config/sops/age/keys.txt,
          dérivée de sa clé SSH). Les autres users (dont root) réutilisent
          cette clé pour déchiffrer leurs secrets.
        '';
      };
    };
  };

  config.assertions = [
    {
      assertion = lib.any (
        user: user.name == config.systemSettings.sops.keyOwner
      ) config.systemSettings.users;
      message = "systemSettings.sops.keyOwner doit correspondre à un utilisateur déclaré dans systemSettings.users.";
    }
  ];
}
