{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  inherit (config.home) homeDirectory;
  cfg = config.userSettings.editors.vscode;

  # Extensions marketplace (hors nixpkgs) : dans extensions.json, lisible et
  # réinscriptible par update.sh (commande `update`). `arch` : VSIX propre à
  # une plateforme (?targetPlatform=, cf. mktplcRefAttrList de vscode-utils).
  marketplaceExtensions = cfg.pkgs.vscode-utils.extensionsFromVscodeMarketplace (
    builtins.attrValues (builtins.fromJSON (builtins.readFile ./extensions.json))
  );

  allVscodeExtensions =
    with cfg.pkgs.vscode-extensions;
    [
      # python
      #ms-python.python
      #ms-python.debugpy
      ms-python.vscode-pylance
      #ms-toolsai.jupyter-keymap
      ms-toolsai.jupyter

      # c/cpp
      #llvm-vs-code-extensions.vscode-clangd
      ms-vscode.cpptools

      # go
      golang.go

      # scala
      scala-lang.scala

      # nix
      bbenoist.nix

      # vim
      vscodevim.vim

      # git
      eamodio.gitlens

      # latex (compile + preview pdf auto ; TeX : userSettings.dev.latex)
      james-yu.latex-workshop

      # outils
      arjun.swagger-viewer
      redhat.vscode-yaml
      ritwickdey.liveserver
      usernamehw.errorlens
      ms-azuretools.vscode-docker
      ms-vscode-remote.remote-ssh
      ms-vscode-remote.remote-ssh-edit

      # themes & icons
      dracula-theme.theme-dracula
      jdinhlife.gruvbox
      pkief.material-icon-theme

      # databases
      cweijan.dbclient-jdbc

    ]
    ++ marketplaceExtensions
    ++ lib.optional config.userSettings.editors.wakatime.enable cfg.pkgs.vscode-extensions.wakatime.vscode-wakatime;

  vscodePkg = cfg.pkgs.vscode-with-extensions.override {
    vscode = cfg.pkgs.vscode-fhs;
    vscodeExtensions = allVscodeExtensions;
  };

  # Masque les warnings cosmétiques stderr des flags Wayland injectés par
  # NIXOS_OZONE_WL (fonctionnent quand même, seul le validateur d'arguments
  # de VS Code râle). Ne filtre QUE ces lignes, les vraies erreurs passent.
  codeWrapper = cfg.pkgs.writeShellScriptBin "code" ''
    # SHLVL : le terminal intégré VS Code repart d'un niveau bas (le prompt
    # fish soustrait 1 quand TERM_PROGRAM=vscode).
    unset SHLVL
    exec ${vscodePkg}/bin/code "$@" \
      2> >(grep -v -F -- "is not in the list of known options, but still passed to Electron/Chromium" >&2)
  '';

  # Le target vscode de stylix thémise via programs.vscode.profiles de HM,
  # inutilisé ici (VS Code installé par home.packages, merge de settings
  # maison). On suit juste la POLARITÉ (jdinhlife.gruvbox) : approximation
  # assumée, pas les couleurs base16 réelles.
  colorTheme =
    {
      dark = "Gruvbox Dark Hard";
      light = "Gruvbox Light Hard";
    }
    .${themes.polarity config.userSettings.stylix.theme};

  # /!\ settings.json doit rester du JSON STRICT (pas de commentaires
  # JSONC) : lu par importJSON, une erreur fait échouer l'éval au lieu de
  # casser silencieusement le merge à l'activation. Seules les valeurs qui
  # dépendent de la config sont posées ici.
  settings = lib.recursiveUpdate (lib.importJSON ./vscode-config/settings.json) {
    "workbench.colorTheme" = colorTheme;
    "terminal.integrated.defaultProfile.linux" = config.userSettings.shell.default;
    # Le VSIX linux-x64 (`arch`) embarque un claude ELF x86-64 (glibc
    # seule), qui tourne tel quel dans vscode-fhs : plus de wrapper. Vide plutôt
    # qu'absent : le merge à l'activation ne retire jamais une clé, l'ancien
    # chemin du wrapper resterait sinon dans settings.json (et vide = non
    # défini pour l'extension).
    "claudeCode.claudeProcessWrapper" = "";
  };
  settingsFile = cfg.pkgs.writeText "vscode-settings.json" (builtins.toJSON settings);

in
{
  options = {
    userSettings.editors.vscode = {
      enable = lib.mkEnableOption "Enable vscode";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [
      vscodePkg
      (lib.hiPrio codeWrapper) # l'emporte sur bin/code du paquet dans le PATH
    ];

    home.file = {
      ".config/Code/User/keybindings.json".source = ./vscode-config/keybindings.json;
    };

    # Deep-merge au rebuild (même mécanique que le module claude) : VS Code
    # écrit lui-même dans ce fichier, un symlink read-only casserait ça.
    home.activation.vscodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      ''
        # Migration : l'ancien déploiement laissait un symlink read-only du store.
        target="${homeDirectory}/.config/Code/User/settings.json"
        [ -L "$target" ] && rm "$target"
      ''
      + myLib.deepMergeJsonActivation {
        inherit lib;
        pkgs = cfg.pkgs;
        targetPath = "${homeDirectory}/.config/Code/User/settings.json";
        sourceFile = settingsFile;
        label = "vscode";
      }
    );
  };
}
