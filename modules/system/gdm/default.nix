{ ... }:

{
  # Écran de login GDM (thémisé par Stylix, cf. modules/system/stylix).
  services.displayManager.gdm.enable = true;
  services.xserver.enable = true;

  # Trousseau de secrets (mots de passe Chrome, Wi-Fi, etc.). Le démon stocke la
  # clé qui chiffre les secrets ; le hook PAM sur gdm-password déverrouille le
  # trousseau « login » avec ton mot de passe de session à la connexion, sinon
  # Chrome réclame « Authentication required » au démarrage.
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.gdm-password.enableGnomeKeyring = true;

  # Touchpad (activé par défaut dans la plupart des desktopManager).
  services.libinput.enable = true;
}
