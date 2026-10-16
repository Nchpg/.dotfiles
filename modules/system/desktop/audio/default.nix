{
  config,
  lib,
  ...
}:

lib.mkIf config.systemSettings.desktop.enable {
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
    jack.enable = true;

    # Sortie par défaut = plus haute priorité (Bluetooth > interne), pas épinglée.
    wireplumber.extraConfig."51-default-follow-priority" = {
      "wireplumber.settings" = {
        "node.restore-default-targets" = false;
      };
    };
  };
}
