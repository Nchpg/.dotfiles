{ config, lib, ... }:

# Dock USB DisplayLink (Dell D3100) : vidéo compressée côté PC, décodée par
# la puce du dock (driver propriétaire + module kernel evdi). Le zip du
# driver (licence Synaptics) est téléchargé automatiquement via
# overlays/displaylink.nix. Spécifique au matériel -> activé par le host.
let
  cfg = config.systemSettings.displaylink;
in
{
  options = {
    systemSettings.displaylink = {
      enable = lib.mkEnableOption "driver DisplayLink + evdi pour dock USB (Dell D3100)";
    };
  };

  config = lib.mkIf cfg.enable {
    # S'ajoute (fusion de liste) au "modesetting" posé par intel-graphics :
    # ne PAS le remettre ici, la liste ne déduplique pas.
    services.xserver.videoDrivers = [ "displaylink" ];
  };
}
