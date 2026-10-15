{
  config,
  lib,
  myLib,
  ...
}:

# Applications par défaut (xdg-open, Thunar, liens des apps Electron/kitty...).
#
# Sans déclaration, le choix se faisait au hasard des installations : les apps
# ArtCraft revendiquent beaucoup de types et passaient devant (cache MIME local
# régénéré par leur synchro de menu), et `inode/directory` revenait à Nautilus
# (GNOME, session de secours) au lieu de Thunar. ~/.config/mimeapps.list était
# écrit à la main par Firefox et Teams.
#
# home-manager prend la main sur ~/.config/mimeapps.list : un « Toujours ouvrir
# avec » choisi dans une app est écrasé au rebuild suivant. C'est ICI qu'on
# change un défaut.
let
  cfg = config.userSettings.gui.defaultApps;

  # Ids des entrées générées par la synchro ArtCraft (modules/user/apps/artcraft) :
  # tant que l'app n'est pas installée, le type retombe sur la suite de la liste
  # du cache MIME, comme sans défaut.
  craft = app: "ai.storyteller.${app}.desktop";

  # Tout ce qui est texte sans être un document de traitement de texte, et tout
  # ce qu'on ne reconnaît pas : nvim. Règle : WordCraft seulement quand on est
  # SÛR que c'est un document (wordTypes), nvim dans le doute. Les fichiers sans
  # type propre (Dockerfile, .conf, .ini, .nix...) sont du text/plain, les
  # inconnus de l'application/octet-stream.
  codeTypes = [
    "text/plain"
    "application/octet-stream"
    "application/x-zerosize" # fichier vide
    "text/markdown"
    "text/x-markdown"
    "text/x-csrc"
    "text/x-chdr"
    "text/x-c++src"
    "text/x-c++hdr"
    "text/x-python"
    "text/x-python3"
    "text/x-script.python"
    "text/x-java"
    "text/x-go"
    "text/rust"
    "text/x-rust"
    "text/x-nix"
    "text/x-lua"
    "text/x-sql"
    "text/x-makefile"
    "text/x-cmake"
    "text/x-shellscript"
    "application/x-shellscript"
    "text/javascript"
    "application/javascript"
    "text/x-typescript"
    "application/typescript"
    "text/css"
    "application/json"
    "application/x-yaml"
    "text/x-yaml"
    "application/yaml"
    "application/toml"
    "text/x-toml"
    "application/xml"
    "text/xml"
    "text/x-diff"
    "text/x-patch"
  ];

  # Documents de traitement de texte (formats que WordCraft déclare savoir
  # ouvrir). Pas de .doc : WordCraft ne le gère pas.
  wordTypes = [
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" # .docx
    "application/vnd.oasis.opendocument.text" # .odt
    "application/rtf"
    "text/rtf"
  ];

  imageTypes = [
    "image/png"
    "image/jpeg"
    "image/webp"
    "image/bmp"
    "image/tiff"
    "image/avif"
    "image/heif"
    "image/x-portable-pixmap"
  ];

  # Photos brutes d'appareil : développement RAW, c'est LightCraft (Lightroom).
  rawTypes = [
    "image/x-dcraw"
    "image/x-canon-cr2"
    "image/x-canon-cr3"
    "image/x-nikon-nef"
    "image/x-sony-arw"
    "image/x-fuji-raf"
    "image/x-panasonic-rw2"
    "image/x-olympus-orf"
    "image/x-adobe-dng"
  ];

  # GIF à part : des animations, pas des images à retoucher, lues en boucle
  # dans mpv (cf. le profil extension.gif du module mpv).
  gifTypes = [ "image/gif" ];

  videoTypes = [
    "video/mp4"
    "video/x-matroska"
    "video/webm"
    "video/quicktime"
    "video/x-msvideo"
    "video/mpeg"
    "video/ogg"
  ];

  # Navigateur : repris de l'ancien mimeapps.list (écrit par Firefox).
  webTypes = [
    "text/html"
    "application/xhtml+xml"
    "x-scheme-handler/http"
    "x-scheme-handler/https"
    "x-scheme-handler/chrome"
    "application/x-extension-htm"
    "application/x-extension-html"
    "application/x-extension-shtml"
    "application/x-extension-xhtml"
    "application/x-extension-xht"
  ];

  to = app: types: lib.genAttrs types (_: app);

  # nvim dans le terminal par défaut : l'entrée nvim.desktop du paquet est en
  # Terminal=true, que xdg-open (mode générique) ignore -> nvim sans terminal.
  nvimInTerminal = myLib.desktop.mkTerminalCmd {
    inherit config;
    title = "nvim";
    exec = "nvim";
  };
in
{
  options.userSettings.gui.defaultApps = {
    enable = lib.mkEnableOption "applications par défaut déclarées (mimeapps.list)";
  };

  config = lib.mkIf cfg.enable {
    xdg.desktopEntries.nvim-terminal = {
      name = "Neovim";
      genericName = "Éditeur de texte";
      exec = "${nvimInTerminal} %F";
      icon = "nvim";
      terminal = false;
      # Cible des associations seulement : rofi a déjà l'entrée nvim du paquet.
      noDisplay = true;
      categories = [
        "Utility"
        "TextEditor"
      ];
    };

    xdg.mimeApps = {
      enable = true;
      defaultApplications =
        to "firefox.desktop" webTypes
        // to "nvim-terminal.desktop" codeTypes
        // to (craft "wordcraft") wordTypes
        // to (craft "photocraft") imageTypes
        // to (craft "lightcraft") rawTypes
        // to "mpv.desktop" gifTypes
        // to "vlc.desktop" videoTypes
        // {
          "application/pdf" = craft "pdfcraft";
          "image/svg+xml" = craft "vectorcraft"; # vectoriel : Illustrator
          "inode/directory" = "thunar.desktop";
          "x-scheme-handler/msteams" = "teams.desktop";
          "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
        };
    };
  };
}
