{ ... }:

let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    # Tunnel créé depuis gram (login/create exigent un navigateur) ; ici seul le démon tourne.
    cloudflared = {
      enable = true;
      tunnelId = "4c8a6f06-b1cd-4a64-ba62-021113f68bda";
    };

    authelia = {
      enable = true;
      # Domaine racine : le Universal SSL gratuit ne couvre qu'un niveau de joker ;
      # le cookie de session part vers tous les sous-domaines.
      inherit domain;
      portalHost = "auth.${domain}";

      # Le secret fait foi : un compte ajouté y est semé, un compte retiré quitte le fichier vivant
      # (mots de passe gardés pour les autres).
      mutableUsers = true;
      # Sinon on reste bloqué sur le portail après un lien d'enrôlement.
      defaultRedirect = "https://cloud.${domain}";

      # Services de think ouverts à chaque compte (page Authelia du dashboard, apps.yml).
      accountsFile = ./authelia-accounts.json;
    };
  };
}
