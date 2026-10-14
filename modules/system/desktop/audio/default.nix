{
  config,
  lib,
  ...
}:

# Suit systemSettings.desktop.enable : sans écran ni haut-parleur, pipewire et
# le firmware de la carte son n'ont personne à servir.
lib.mkIf config.systemSettings.desktop.enable {
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
    jack.enable = true;

    # Sortie par défaut = celle de plus haute priorité (Bluetooth > haut-parleur
    # interne), pas épinglée : à la connexion Bluetooth, @DEFAULT_AUDIO_SINK@
    # (binds sway) bascule automatiquement dessus.
    wireplumber.extraConfig."51-default-follow-priority" = {
      "wireplumber.settings" = {
        "node.restore-default-targets" = false;
      };
    };
  };

  # sof-firmware (DSP de la carte son du laptop) : déjà fourni par
  # hardware.enableRedistributableFirmware (modules/system/configuration.nix).
}
