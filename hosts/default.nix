{ lib, target, ... }:

let
  hardwareConfig = ./. + "/${target.host}/hardware-configuration.nix";
in
{
  # Gardé par pathExists + assertion : sinon "path does not exist" cryptique.
  imports =
    lib.optional (builtins.pathExists hardwareConfig) hardwareConfig
    ++ (lib.optional (builtins.pathExists (./. + "/${target.host}/configuration.nix")) (
      ./. + "/${target.host}/configuration.nix"
    ));

  config = {
    assertions = [
      {
        assertion = builtins.pathExists hardwareConfig;
        message = "hosts/${target.host}/hardware-configuration.nix est introuvable : génère-le avec `nixos-generate-config` sur la machine.";
      }
    ];

    # LE PARC RÉEL, et c'est le seul endroit du dépôt qui le dise. `flake.nix`
    # construit ses cibles par produit cartésien : les huit combinaisons de
    # profil et de host existent et compilent, sans que rien ne distingue celles
    # qu'on active de celles qu'on ne fait que vérifier en CI.
    #
    # Cette distinction n'était nulle part, et son absence coûtait cher :
    # « quelles machines font tourner le profil server » n'ayant pas de réponse,
    # les secrets du serveur étaient scellés pour TOUT LE PARC — donc le
    # portable pouvait ouvrir la clé privée WireGuard du serveur, les
    # credentials du tunnel Cloudflare et les secrets de session d'Authelia,
    # pour n'avoir besoin que de ses deux clés de tunnel.
    #
    # Ici plutôt que dans modules/system/sops, où l'option est DÉCLARÉE : le
    # module dit comment le parc se traduit en destinataires, ce fichier dit de
    # quoi le parc est fait. C'est aussi ce qui rend l'ajout d'une machine
    # lisible — un host, une ligne, à côté de son dossier.
    #
    # Une machine peut porter PLUSIEURS profils. Le jour où gram doit pouvoir
    # reprendre le rôle de think, c'est `gram = [ "personal" "server" ]` ici,
    # puis `secrets policy` — et l'élargissement du rayon d'explosion est
    # alors un geste écrit, pas un effet de bord.
    systemSettings.sops.deployments = {
      think = [ "server" ];
      gram = [ "personal" ];
    };
  };
}
