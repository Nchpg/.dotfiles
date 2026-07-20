{ config, lib, ... }:

# Socle léger, hors devshell (scripts ponctuels, uv run/uvx, venvs ad hoc).
# Le devshell python (devshells/python.nix) reste l'environnement de travail
# des projets (LD_LIBRARY_PATH pour les wheels compilés type numpy/torch).
let
  cfg = config.userSettings.python;
in
{
  options.userSettings.python = {
    enable = lib.mkEnableOption "Python + uv globaux (hors devshell)";
    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      # Même interpréteur que le devshell (python313) : venvs interchangeables.
      cfg.pkgs.python313
      cfg.pkgs.uv
    ];

    # uv préfère par défaut ses interpréteurs téléchargés (non-Nix, tournent
    # via nix-ld) : "system" inverse la préférence vers le python nix ci-dessus.
    xdg.configFile."uv/uv.toml".text = ''
      python-preference = "system"
    '';
  };
}
