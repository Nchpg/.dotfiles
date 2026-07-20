{
  config,
  lib,
  pkgs-unstable,
  inputs,
  ...
}:

let
  inherit (config.home) homeDirectory;
  cfg = config.userSettings.vscode;

  # Extensions marketplace (hors nixpkgs) : dans extensions.json, lisible et
  # réinscriptible par update.sh / vscode-update-extensions plus bas.
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

      # latex (compile + preview pdf auto)
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
    ++ lib.optional config.userSettings.wakatime.enable cfg.pkgs.vscode-extensions.wakatime.vscode-wakatime;

  # Contourne le binaire macOS arm64 embarqué dans le VSIX linux-x64 :
  # l'extension appelle `wrapper <binaire_inutilisable> [flags...]`, on skip
  # ce binaire et forward le reste au claude système.
  claudeWrapper = pkgs-unstable.writeShellScript "claude-vscode-wrapper" ''
    shift
    exec ${inputs.claude-code.packages.x86_64-linux.default}/bin/claude "$@"
  '';

  vscodePkg = cfg.pkgs.vscode-with-extensions.override {
    vscode = cfg.pkgs.vscode-fhs;
    vscodeExtensions = allVscodeExtensions;
  };

  # Masque les warnings cosmétiques stderr des flags Wayland injectés par
  # NIXOS_OZONE_WL (fonctionnent quand même, seul le validateur d'arguments
  # de VS Code râle). Ne filtre QUE ces lignes, les vraies erreurs passent.
  codeWrapper = pkgs-unstable.writeShellScriptBin "code" ''
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
  themes = import ../../themes lib inputs;
  colorTheme =
    {
      dark = "Gruvbox Dark Hard";
      light = "Gruvbox Light Hard";
    }
    .${themes.polarity config.userSettings.stylix.theme};

  # /!\ doit rester du JSON STRICT (pas de commentaires JSONC : le
  # deep-merge ci-dessous passe par jq).
  settingsTemplateContent = builtins.readFile ./vscode-config/settings.json;
  finalConfigContent =
    lib.replaceStrings
      [ "@shell@" "@claudeWrapper@" "@colorTheme@" ]
      [ config.userSettings.shell.default "${claudeWrapper}" colorTheme ]
      settingsTemplateContent;

  # Validé par jq au build : un commentaire dans le template fait échouer le
  # rebuild au lieu de casser silencieusement le merge à l'activation.
  settingsFile = cfg.pkgs.runCommand "vscode-settings.json" { } ''
    ${cfg.pkgs.jq}/bin/jq . ${cfg.pkgs.writeText "vscode-settings-raw.json" finalConfigContent} > $out
  '';

  # Bump version+sha256 des extensions qui ont bougé (API marketplace). Ramassée
  # automatiquement par `rebuild -u` et la CI hebdo (cf. update.sh).
  updateExtensionsCmd = cfg.pkgs.writeShellApplication {
    name = "vscode-update-extensions";
    runtimeInputs = with cfg.pkgs; [
      curl
      jq
      nix
    ];
    text = builtins.readFile ./update.sh;
  };

in
{
  options = {
    userSettings.vscode = {
      enable = lib.mkEnableOption "Enable vscode";
      pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [
      vscodePkg
      (lib.hiPrio codeWrapper) # l'emporte sur bin/code du paquet dans le PATH
      # LaTeX Workshop + paquets manquants utilisés par le CV
      (cfg.pkgs.texliveMedium.withPackages (
        ps: with ps; [
          enumitem
          titlesec
          eurosym
          parskip
        ]
      ))
      updateExtensionsCmd
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
      + import ../../../lib/deep-merge-json-activation.nix {
        inherit lib;
        pkgs = cfg.pkgs;
        targetPath = "${homeDirectory}/.config/Code/User/settings.json";
        sourceFile = settingsFile;
        label = "vscode";
      }
    );
  };
}
