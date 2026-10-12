{
  config,
  lib,
  myLib,
  pkgs-stable,
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

  # Code et texte structuré : nvim, pas un traitement de texte. Le texte brut
  # (text/plain) va à WordCraft.
  codeTypes = [
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

  imageTypes = [
    "image/png"
    "image/jpeg"
    "image/gif"
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

  # Types absents de shared-mime-info : sans eux ces fichiers sont du
  # `text/plain` et partent dans WordCraft. Base MIME du profil reconstruite
  # par home-manager (xdg.mime.enable, actif par défaut).
  extraMimeTypes = pkgs-stable.writeTextDir "share/mime/packages/dotfiles-code.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
      <mime-type type="text/x-nix">
        <sub-class-of type="text/plain"/>
        <comment>Nix expression</comment>
        <glob pattern="*.nix"/>
      </mime-type>
    </mime-info>
  '';

  # nvim dans le terminal par défaut : l'entrée nvim.desktop du paquet est en
  # Terminal=true, que xdg-open (mode générique) ignore -> nvim sans terminal.
  nvimInTerminal = myLib.mkTerminalCmd {
    inherit lib;
    term = config.userSettings.terminal.default;
    title = "nvim";
    exec = "nvim";
  };
in
{
  options.userSettings.gui.defaultApps = {
    enable = lib.mkEnableOption "applications par défaut déclarées (mimeapps.list)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ extraMimeTypes ];

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
        // to (craft "photocraft") imageTypes
        // to (craft "lightcraft") rawTypes
        // to "mpv.desktop" videoTypes
        // {
          "application/pdf" = craft "pdfcraft";
          "image/svg+xml" = craft "vectorcraft"; # vectoriel : Illustrator
          "text/plain" = craft "wordcraft";
          "inode/directory" = "thunar.desktop";
          "x-scheme-handler/msteams" = "teams.desktop";
          "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
        };
    };
  };
}
