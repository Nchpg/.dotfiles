{ ... }:

{
  config = {
    systemSettings = {
      stylix = {
        enable = true;
        # Pas de `variant` ici : portée par la CIBLE du flake (personal-gram
        # vs personal-gram-light), bascule via `theme` sans modifier la config.
        darkTheme = "gruvbox-dark-custom";
        lightTheme = "gruvbox-light";
      };

      # nchpg détient la clé age qui déchiffre secrets/secrets.yaml.
      sops.keyOwner = "nchpg";

      users = [
        {
          name = "nchpg";
          isAdmin = true;
          allowDocker = true;
          allowLibvirt = true;
          # Login TTY/SSH en fish, aligné sur userSettings.shell.default.
          shell = "fish";
        }
        {
          name = "guest";
          isAdmin = false;
          allowDocker = false;
        }
      ];

      window-manager = {
        sway.enable = true;
        gnome.enable = true;
      };

      swap = {
        # Pas de swap disque sur gram : zram + earlyoom.
        zram.enable = true;
        earlyoom.enable = true;
      };

      virtualisation = {
        docker.enable = true;
        libvirt.enable = true;
      };

      ollama.enable = true;
    };
  };
}
