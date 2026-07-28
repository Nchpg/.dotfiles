{ ... }:

# Profil headless : ni session graphique ni GDM (cf. modules/system/gdm, dont
# le défaut suit la présence d'un window manager), une IP fixe et SSH. Prévu
# pour tourner sur le host think, cible `server-think`.
{
  config = {
    systemSettings = {
      # Thémise les TTY, seul rendu local d'un host sans session graphique :
      # sans ça la console garde la palette Linux par défaut et la même
      # commande n'a pas les mêmes couleurs sur l'écran de la machine et en
      # SSH depuis gram. Les targets GUI (GDM, overlay gnome-shell, et sa
      # recompilation) suivent systemSettings.desktop.enable, faux ici.
      stylix.enable = true;

      # nchpg détient la clé age qui déchiffre secrets/secrets.yaml.
      sops.keyOwner = "nchpg";

      users = [
        {
          name = "nchpg";
          isAdmin = true;
          # Login TTY/SSH en fish, aligné sur userSettings.shell.default.
          shell = "fish";
          # Clé de gram : c'est depuis ce poste qu'on administre la machine.
          sshKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtpLQKGuQttRPNQTdMOjLpx1kn5oM94wj97klIh5Upf nchpg@nixos"
          ];
        }
      ];

      ssh = {
        enable = true;
        # Hors du port 22 : ça n'apporte aucune sécurité (un scan trouve le
        # port en quelques secondes), mais ça vide le journal des tentatives
        # de bruteforce automatisées qui ne tapent que sur 22.
        port = 3249;
      };

      # Adressage posé par systemd-networkd, NetworkManager coupé : sur une
      # machine qu'on ne touche que par le réseau, l'adresse ne doit dépendre
      # ni du bail DHCP de la box ni de l'état persistant d'un démon.
      network.staticIPv4 = {
        address = "192.168.1.32";
        prefixLength = 24;
        gateway = "192.168.1.254";
      };
    };
  };
}
