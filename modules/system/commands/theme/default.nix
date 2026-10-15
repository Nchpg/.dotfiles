{
  lib,
  config,
  target,
  myLib,
  themes,
  ...
}:

let
  cfg = config.systemSettings.stylix;

  gallery = themes.galleryFor cfg.pkgs;
  firefox = "${cfg.pkgs.firefox}/bin/firefox";

  # Fichier réécrit par la galerie quand on applique un thème : le profil de
  # CETTE cible, qui déclare réellement darkTheme/lightTheme.
  profileFile = "profiles/${target.profile}/default.nix";

  # Versionnés dans le dépôt, écrits par le serveur de galerie ; pas dans la
  # config construite (sélection personnelle, pas état système).
  favoritesFile = "themes/gallery/favorites.json";
in
{
  config = lib.mkIf cfg.enable {
    # Entrée du catalogue de `dots` (cf. ../default.nix) : seulement avec
    # Stylix, comme la commande elle-même.
    systemSettings.commands.theme = {
      desc = "change de thème ou de variante dark/light";
      order = 3;
      examples = [
        [
          "theme"
          "ouvre la galerie des thèmes dans le navigateur"
        ]
        [
          "theme toggle"
          "bascule dark ↔ light puis rebuild"
        ]
        [
          "theme dark"
          "passe en sombre puis rebuild"
        ]
        [
          "theme light"
          "passe en clair puis rebuild"
        ]
      ];
    };

    environment.systemPackages = [
      (cfg.pkgs.writeShellApplication {
        name = "theme";
        # Le script lui-même : theme.sh, à côté. Seules les valeurs tirées de
        # la config viennent d'ici, en préambule.
        text = ''
          current=${lib.escapeShellArg cfg.variant}
          profileFile=${lib.escapeShellArg profileFile}
          favoritesFile=${lib.escapeShellArg favoritesFile}
          galleryServer=${gallery.server}
          browser=${firefox}
          ${myLib.flakeVar}
        ''
        + builtins.readFile ./theme.sh;
      })
    ];
  };
}
