{ ... }:

{
  config = {
    systemSettings = {
      stylix = {
        enable = true;
        # Pas de `variant` ici : la variante dark/light est portée par la
        # CIBLE du flake (personal-gram vs personal-gram-light) — bascule via
        # la commande `theme`, sans modifier la config.
        # Thèmes explicites au niveau profil (couche d'intention) : on voit ici
        # quel thème est actif sans aller lire le défaut du module. Le module
        # garde les mêmes valeurs par défaut, en repli pour un profil qui ne les
        # préciserait pas.
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
