{ config, lib, ... }:

# Python + uv disponibles PARTOUT (hors devshell) : scripts ponctuels,
# `uv run script.py`, `uvx <outil>`, venvs ad hoc. Le devshell python
# (devshells/python.nix) reste l'environnement de travail des projets
# (mkvenv/mkkernel/lab, LD_LIBRARY_PATH pour les wheels compilés type
# numpy/torch) — ici, uniquement le socle léger.
let
  cfg = config.userSettings.python;
in
{
  options.userSettings.python = {
    enable = lib.mkEnableOption "Python + uv globaux (hors devshell)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      # Même interpréteur que le devshell python (python313) : les venvs créés
      # dedans ou dehors pointent sur le même python → interchangeables.
      cfg.pkgs.python313
      cfg.pkgs.uv
    ];

    # uv préfère par défaut SES interpréteurs téléchargés (python-build-
    # standalone, binaires non-Nix qui ne tournent ici que grâce à nix-ld).
    # "system" inverse la préférence : le python nix ci-dessus d'abord, et le
    # téléchargement uv seulement en repli explicite quand on demande une
    # version que nix ne fournit pas (ex. `uv venv --python 3.12`).
    # Le cache (~/.cache/uv, défaut) est le même que celui du devshell :
    # wheels et interpréteurs partagés, installs par hardlinks.
    xdg.configFile."uv/uv.toml".text = ''
      python-preference = "system"
    '';
  };
}
