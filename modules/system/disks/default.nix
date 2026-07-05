{ pkgs-stable, ... }:

{
  # Disques externes : udisks2 (montage sans root) + udiskie (automount + icône
  # tray) + NTFS pour les disques Windows. Thunar comme gestionnaire de fichiers.
  services.udisks2.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  # udiskie n'est pas dans systemPackages : le service référence directement
  # son chemin dans le store.
  systemd.user.services.udiskie = {
    description = "udiskie automounter";
    wantedBy = [ "default.target" ];
    serviceConfig.ExecStart = "${pkgs-stable.udiskie}/bin/udiskie --tray"; # --tray affiche l'icône en bas à droite
  };

  programs.thunar.enable = true;
}
