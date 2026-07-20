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

  # Extensions marketplace (hors nixpkgs) : données dans extensions.json plutôt
  # qu'en dur ici, pour être lisibles ET réinscriptibles par un script (cf.
  # update.sh / commande vscode-update-extensions plus bas).
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
    # WakaTime : suivi du temps de code, partage la cfg sops (~/.wakatime.cfg)
    ++ lib.optional config.userSettings.wakatime.enable cfg.pkgs.vscode-extensions.wakatime.vscode-wakatime;

  # Wrapper script to bypass the macOS arm64 binary bundled in the linux-x64 VSIX.
  # The extension calls: wrapper <bundled_binary> [actual_flags...]
  # We skip the unusable binary and forward remaining args to the system claude.
  claudeWrapper = pkgs-unstable.writeShellScript "claude-vscode-wrapper" ''
    shift
    exec ${inputs.claude-code.packages.x86_64-linux.default}/bin/claude "$@"
  '';

  # Paquet VS Code complet (avec extensions). Référencé par le wrapper ci-dessous
  # et conservé dans home.packages pour le fichier .desktop, les icônes, etc.
  vscodePkg = cfg.pkgs.vscode-with-extensions.override {
    vscode = cfg.pkgs.vscode-fhs;
    vscodeExtensions = allVscodeExtensions;
  };

  # Wrapper `code` qui masque les warnings cosmétiques émis sur stderr par le
  # binaire VS Code au démarrage (flags Wayland injectés par nixpkgs via
  # NIXOS_OZONE_WL : ozone-platform-hint, enable-features, enable-wayland-ime,
  # wayland-text-input-version). Ces flags fonctionnent quand même ; seul le
  # validateur d'arguments de VS Code râle. On ne filtre QUE ces lignes, les
  # vraies erreurs passent toujours.
  codeWrapper = pkgs-unstable.writeShellScriptBin "code" ''
    # Réinitialise SHLVL pour que le terminal intégré de VS Code reparte d'un
    # niveau bas (le prompt fish soustrait 1 quand TERM_PROGRAM=vscode).
    # Remplace l'ancien alias `code='env -u SHLVL code'` de shell/common.
    unset SHLVL
    exec ${vscodePkg}/bin/code "$@" \
      2> >(grep -v -F -- "is not in the list of known options, but still passed to Electron/Chromium" >&2)
  '';

  # Le target vscode de stylix ne sert à rien ici : il thémise via
  # programs.vscode.profiles.<n>.extensions de home-manager, alors qu'on
  # installe VS Code par home.packages avec notre propre merge de settings.
  # On se contente donc de suivre la POLARITÉ du thème stylix actif —
  # l'extension jdinhlife.gruvbox fournit les deux variantes. Approximation
  # assumée (le scheme dark est gruvbox-dark-custom, pas un Gruvbox amont) :
  # c'est un mapping par variante, pas les couleurs base16 réelles.
  themes = import ../../themes lib inputs;
  colorTheme =
    {
      dark = "Gruvbox Dark Hard";
      light = "Gruvbox Light Hard";
    }
    .${themes.polarity config.userSettings.stylix.theme};

  # /!\ vscode-config/settings.json doit rester du JSON STRICT (pas de
  # commentaires JSONC : le deep-merge ci-dessous passe par jq). Thèmes
  # alternatifs déjà installés si besoin : "Dracula Theme",
  # "material-icon-theme".
  settingsTemplateContent = builtins.readFile ./vscode-config/settings.json;
  finalConfigContent =
    lib.replaceStrings
      [ "@shell@" "@claudeWrapper@" "@colorTheme@" ]
      [ config.userSettings.shell.default "${claudeWrapper}" colorTheme ]
      settingsTemplateContent;

  # Validé par jq au build : réintroduire un commentaire dans le template fait
  # échouer le rebuild au lieu de casser silencieusement le merge à l'activation.
  settingsFile = cfg.pkgs.runCommand "vscode-settings.json" { } ''
    ${cfg.pkgs.jq}/bin/jq . ${cfg.pkgs.writeText "vscode-settings-raw.json" finalConfigContent} > $out
  '';

  # Commande `vscode-update-extensions` : interroge l'API du VS Code Marketplace
  # pour chaque extension d'extensions.json et bump version+sha256 (via `nix
  # store prefetch-file`) pour celles qui ont bougé. Ramassée automatiquement
  # par `rebuild -u` et la CI hebdo (cf. update.sh), en plus d'être invocable
  # à la main sous ce nom.
  updateExtensionsCmd = cfg.pkgs.writeShellApplication {
    name = "vscode-update-extensions";
    runtimeInputs = with cfg.pkgs; [
      curl
      jq
      nix
    ];
    # readFile inclut son propre shebang, redondant avec celui posé par
    # writeShellApplication : il devient un simple commentaire une fois en
    # 2e ligne (même pattern que mkScript dans modules/user/waybar).
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
      # priorité haute : le `code` du wrapper l'emporte sur celui du paquet
      # dans le PATH (sinon collision de bin/code)
      (lib.hiPrio codeWrapper)
      # distribution LaTeX (latexmk, pdflatex, ...) utilisée par LaTeX Workshop
      # avec les paquets supplémentaires (enumitem, titlesec, eurosym, parskip, ...)
      # manquants utilisés par le CV
      (cfg.pkgs.texliveMedium.withPackages (
        ps: with ps; [
          enumitem
          titlesec
          eurosym
          parskip
        ]
      ))
      # `vscode-update-extensions` : bump manuel de extensions.json (cf. let).
      updateExtensionsCmd
    ];

    home.file = {
      ".config/Code/User/keybindings.json".source = ./vscode-config/keybindings.json;
    };

    # settings.json en DEEP-MERGE au rebuild (même mécanique que le module
    # claude) : VS Code écrit lui-même dans ce fichier (réglages changés via
    # l'UI, window.zoomLevel au zoom clavier…) — l'ancien symlink read-only du
    # store cassait ces écritures. On impose seulement les clés du template
    # (déclaratives, ré-appliquées à chaque rebuild), le reste que VS Code gère
    # au runtime est préservé. VS Code n'écrit jamais de commentaires ; si une
    # édition MANUELLE ajoute du JSONC, jq ne peut plus parser → on n'impose
    # rien ce coup-ci et on prévient, plutôt que d'écraser le fichier.
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
