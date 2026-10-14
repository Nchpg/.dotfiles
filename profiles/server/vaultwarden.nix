{ config, ... }:

# Coffre-fort de mots de passe.
let
  domain = import ./domain.nix;
  wireguard = config.systemSettings.vpn.wireguard;

  # Sources admises sur les services réservés à TES appareils dans le tunnel
  # (le coffre, MyETF), pas aux téléphones de la famille : les peers marqués
  # `trusted` (cf. vpn.nix).
  #
  # Plus la source sous laquelle think SE VOIT elle-même, pour la sonde de
  # surveillance seule : elle vise 10.8.0.1 mais ressort masquée en adresse du
  # LAN (cf. `selfSource` dans modules/system/server/vpn/wireguard).
  mesAppareils = wireguard.trustedSources ++ [ wireguard.selfSource ];
in
{
  systemSettings = {
    # Coffre-fort de mots de passe, joignable UNIQUEMENT par le tunnel
    # WireGuard : aucune route dans le tunnel Cloudflare, et nginx refuse
    # toute source hors de la plage du VPN. Cf. l'en-tête du module pour ce
    # qu'il faudrait ajouter — Authelia en tête — le jour où on le publierait.
    #
    # PRÉCONDITION HORS DÉPÔT, à poser avant le rebuild : un enregistrement A
    # `vault.vpn.nathanchampagne.com` vers 10.8.0.1 chez Cloudflare, en « DNS
    # only » (nuage gris), exactement comme `cloud.vpn.`. Sans lui le nom ne
    # résout nulle part, et la sonde que le module ajoute à
    # `monitoring.blackbox.targets` le dira bruyamment.
    vaultwarden = {
      enable = true;
      hostName = "vault.vpn.${domain}";

      # TES APPAREILS, ET PAS TOUT LE TUNNEL. Le défaut du module autorise la
      # plage entière, donc les six peers — y compris les téléphones de la
      # famille, qui n'ont aucune raison d'atteindre ton coffre. Trois de
      # moins devant la page de connexion, et ce sont justement les trois que
      # tu ne maîtrises pas.
      allowedNetworks = mesAppareils;

      # FERMÉE depuis la création du premier compte. Les suivants — la famille
      # — passent par une invitation envoyée depuis une organisation du
      # coffre : `INVITATIONS_ALLOWED` reste actif, donc un invité peut
      # s'enregistrer alors même que l'inscription libre est close. C'est le
      # chemin à préférer, il nomme le destinataire au lieu d'ouvrir la porte.
      #
      # La rouvrir se fait en repassant cette ligne à `true` le temps d'un
      # rebuild ; un avertissement s'affiche tant qu'elle l'est, pour qu'on
      # n'oublie pas de refermer.
      signups.enable = false;
    };
  };
}
