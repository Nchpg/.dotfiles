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

  marketplaceExtensions = cfg.pkgs.vscode-utils.extensionsFromVscodeMarketplace (
    builtins.attrValues (builtins.fromJSON (builtins.readFile ./extensions.json))
  );

  allVscodeExtensions =
    with cfg.pkgs.vscode-extensions;
    [
      ms-python.vscode-pylance
      ms-toolsai.jupyter

      ms-vscode.cpptools

      golang.go

      scala-lang.scala

      bbenoist.nix

      vscodevim.vim

      eamodio.gitlens

      james-yu.latex-workshop

      arjun.swagger-viewer
      redhat.vscode-yaml
      ritwickdey.liveserver
      usernamehw.errorlens
      ms-azuretools.vscode-docker
      ms-vscode-remote.remote-ssh
      ms-vscode-remote.remote-ssh-edit

      dracula-theme.theme-dracula
      jdinhlife.gruvbox
      pkief.material-icon-theme

      cweijan.dbclient-jdbc
    ]
    ++ marketplaceExtensions
    ++ lib.optional config.userSettings.editors.wakatime.enable cfg.pkgs.vscode-extensions.wakatime.vscode-wakatime;

  vscodePkg = cfg.pkgs.vscode-with-extensions.override {
    vscode = cfg.pkgs.vscode-fhs;
    vscodeExtensions = allVscodeExtensions;
  };

  codeWrapper = cfg.pkgs.writeShellScriptBin "code" ''
    # Le prompt fish soustrait 1 à SHLVL quand TERM_PROGRAM=vscode.
    unset SHLVL
    exec ${vscodePkg}/bin/code "$@" \
      2> >(grep -v -F -- "is not in the list of known options, but still passed to Electron/Chromium" >&2)
  '';

  # Le target vscode de stylix passe par programs.vscode (inutilisé) : on suit la polarité seulement.
  colorTheme =
    {
      dark = "Gruvbox Dark Hard";
      light = "Gruvbox Light Hard";
    }
    .${themes.polarity config.userSettings.stylix.theme};

  # settings.json doit rester du JSON strict (lu par importJSON).
  settings =
    lib.recursiveUpdate (lib.importJSON ./vscode-config/settings.json) {
      "workbench.colorTheme" = colorTheme;
      "terminal.integrated.defaultProfile.linux" = config.userSettings.shell.default;
      # Vide plutôt qu'absent : le merge ne retire jamais une clé, l'ancien chemin resterait.
      "claudeCode.claudeProcessWrapper" = "";
    }
    // lib.optionalAttrs config.programs.ssh.enable {
      # Passé en `-F`, donc sans le contrôle de propriétaire qui rejette ce lien vers le store
      # (appartenant à `nobody` dans le bac à sable de vscode-fhs).
      "remote.SSH.configFile" = "${homeDirectory}/.ssh/config";
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
      (lib.hiPrio codeWrapper)
    ];

    home.file = {
      ".config/Code/User/keybindings.json".source = ./vscode-config/keybindings.json;
    };

    home.activation.vscodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      ''
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
