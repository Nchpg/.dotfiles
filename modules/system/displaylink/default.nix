{ config, lib, ... }:

# Dock USB DisplayLink (Dell D3100) : la vidéo ne sort pas du GPU, elle est
# compressée côté PC et décodée par la puce du dock → driver propriétaire
# `displaylink` + module kernel evdi requis, sinon le HDMI du dock est mort.
# Le zip du driver (licence Synaptics, requireFile dans nixpkgs) est téléchargé
# automatiquement via overlays/displaylink.nix — rien à faire sur un nouveau host.
# Spécifique au matériel → activé par le host, pas par le profil.
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
    # S'ajoute au "modesetting" déjà posé par intel-graphics (les listes
    # fusionnent) ; installe le paquet displaylink, charge evdi et lance
    # le service dlm.
    services.xserver.videoDrivers = [ "displaylink" ];
  };
}
