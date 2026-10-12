{ config, lib, ... }:

# Dock USB DisplayLink (Dell D3100) : vidéo compressée côté PC, décodée par
# la puce du dock (driver propriétaire + module kernel evdi). Le zip du
# driver (licence Synaptics) est téléchargé automatiquement via
# overlays/displaylink.nix. Spécifique au matériel -> activé par le host.
let
  cfg = config.systemSettings.hardware.displaylink;
in
{
  options = {
    systemSettings.hardware.displaylink = {
      enable = lib.mkEnableOption "driver DisplayLink + evdi pour dock USB (Dell D3100)";
    };
  };

  config = lib.mkIf cfg.enable {
    # S'ajoute (fusion de liste) au "modesetting" posé par intel-graphics :
    # ne PAS le remettre ici, la liste ne déduplique pas.
    services.xserver.videoDrivers = [ "displaylink" ];

    # evdi gère mal le curseur matériel sous wlroots : un second curseur
    # figé reste affiché sur l'écran du dock. Curseur logiciel partout.
    environment.sessionVariables.WLR_NO_HARDWARE_CURSORS = "1";

    # dlm.service (DisplayLinkManager) n'est voulu QUE par la règle udev du
    # dock (SYSTEMD_WANTS). Restart=always le gardait en vie après
    # débranchement : ~5 % d'un cœur à scruter un dock absent. Arrêté dès que
    # plus rien ne le veut, relancé par udev au rebranchement.
    systemd.services.dlm.unitConfig.StopWhenUnneeded = true;
  };
}
