{ pkgs-stable, ... }:

{
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

  # Requis par la carte son du laptop.
  hardware.firmware = with pkgs-stable; [
    sof-firmware
  ];
}
