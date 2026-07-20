{ ... }:

{
  services.displayManager.gdm.enable = true;
  services.xserver.enable = true;

  # Le hook PAM déverrouille le trousseau "login" avec le mot de passe de
  # session à la connexion, sinon Chrome réclame "Authentication required".
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.gdm-password.enableGnomeKeyring = true;
}
