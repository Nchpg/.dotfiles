{
  config,
  lib,
  myLib,
  ...
}:

# « Toujours ouvrir avec » est écrasé au rebuild : changer les défauts ici.
let
  cfg = config.userSettings.gui.defaultApps;

  craft = app: "ai.storyteller.${app}.desktop";

  codeTypes = [
    "text/plain"
    "application/octet-stream"
    "application/x-zerosize"
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

  # Pas de .doc : WordCraft ne le gère pas
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

  # nvim.desktop est en Terminal=true, ignoré par xdg-open
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
          "image/svg+xml" = craft "vectorcraft";
          "inode/directory" = "thunar.desktop";
          "x-scheme-handler/msteams" = "teams.desktop";
          "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
        };
    };
  };
}
