{ ... }:

{
  config = {
    systemSettings = {
      stylix = {
        enable = true;
        variant = "dark";                  # ← interrupteur dark / light
        darkTheme = "gruvbox-dark-custom";
        lightTheme = "gruvbox-light-hard";
      };

      # nchpg détient la clé age qui déchiffre secrets/secrets.yaml.
      sops.keyOwner = "nchpg";

      users = [
        {
          name = "nchpg";
          isAdmin = true;
          allowDocker = true;
          allowLibvirt = true;
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
        # Pas de swap disque sur gram : zram (rapide, sans usure SSD) + earlyoom
        # (kill anticipé et ciblé plutôt qu'un freeze puis un OOM noyau aveugle).
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
