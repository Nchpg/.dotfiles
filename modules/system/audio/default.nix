{ pkgs-stable, ... }:

{
  # Son via pipewire (remplace pulseaudio/jack/alsa, avec leurs compat).
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
    jack.enable = true;

    # Le périphérique par défaut suit la priorité (priority.session) au lieu d'être
    # épinglé. Les sorties Bluetooth ont une priorité plus haute que le haut-parleur
    # interne : à la connexion elles deviennent donc la sortie par défaut, et les
    # binds sway (wpctl ... @DEFAULT_AUDIO_SINK@) les contrôlent automatiquement.
    wireplumber.extraConfig."51-default-follow-priority" = {
      "wireplumber.settings" = {
        "node.restore-default-targets" = false;
      };
    };
  };

  # Firmware audio (Sound Open Firmware, requis par la carte son du laptop).
  hardware.firmware = with pkgs-stable; [
    sof-firmware
  ];
}
