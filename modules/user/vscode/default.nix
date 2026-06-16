{ config, lib, pkgs-stable, pkgs-unstable, inputs, ... }:

let
  cfg = config.userSettings.vscode;
  marketplaceExtensions = cfg.pkgs.vscode-utils.extensionsFromVscodeMarketplace [
    # claude code
    {
      name = "claude-code";
      publisher = "anthropic";
      version = "2.1.142";
      sha256 = "sha256-EZqihuVQZUVtW8lTM2nIvdX/CxMoS4Z2Cyu0ir4sALw=";
      targetPlatform = "linux-x64";
    }

    # outils
    {
      name = "shift-shift";
      publisher = "ahgood";
      version = "0.0.5";
      sha256 = "sha256-r6qzsQTQrTbZiloFdyH5XtT2P2Mf3uOV70iCNuJa6HQ=";
    }
    {
      name = "vscode-containers";
      publisher = "ms-azuretools";
      version = "2.2.0";
      sha256 = "sha256-UxWsu7AU28plnT0QMdpPJrcYZIV09FeC+rmYKf39a6M=";
    }
    {
      name = "remote-explorer";
      publisher = "ms-vscode";
      version = "0.5.0";
      sha256 = "sha256-BNsnetpddxv3Y9MjZERU5jOq1I2g6BNFF1rD7Agpmr8=";
    }

    # databases
    {
      name = "vscode-postgresql-client2";
      publisher = "cweijan";
      version = "8.4.2";
      sha256 = "sha256-fZa5PpIfYo8FIrEqVIW4uQPRv8tCf9WMLp5jZb1uhno=";
    }

    # c/cpp
    {
      name = "cpptools-themes";
      publisher = "ms-vscode";
      version = "2.0.0";
      sha256 = "sha256-YWA5UsA+cgvI66uB9d9smwghmsqf3vZPFNpSCK+DJxc=";
    }

    # nginx
    {
      name = "vscode-nginx";
      publisher = "william-voyek";
      version = "0.7.2";
      sha256 = "sha256-mAmncewwAeagVqwWWrmYosMyw2AT3W0sx8jl2mCeimg=";
    }

    # github copilot
    {
      name = "copilot-chat";
      publisher = "github";
      version = "0.31.5";
      sha256 = "sha256-D7k+hA786w7IZHVI+Og6vHGAAohpfpuOmmCcDUU0WsY=";
    }
    {
      name = "copilot";
      publisher = "github";
      version = "1.388.0";
      sha256 = "sha256-7RjK8+PNI+rIuRQfCwpvswAiz991dacRO2qYhcv1vhk=";
    }

    # icons
    {
      name = "gruvbox-material-icon-theme";
      publisher = "jonathanharty";
      version = "1.1.5";
      sha256 = "sha256-86UWUuWKT6adx4hw4OJw3cSZxWZKLH4uLTO+Ssg75gY=";
    }

    # cypher
    {
      name = "cypher-query-language";
      publisher = "jakeboone02";
      version = "2.0.0";
      sha256 = "sha256-oNjXfW7ndWDsc4GWb8p9QwoXAmW2IVIyUwCxY1qTQSc=";
    }
  ];


  allVscodeExtensions = with cfg.pkgs.vscode-extensions; [
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

  ] ++ marketplaceExtensions;

  # Wrapper script to bypass the macOS arm64 binary bundled in the linux-x64 VSIX.
  # The extension calls: wrapper <bundled_binary> [actual_flags...]
  # We skip the unusable binary and forward remaining args to the system claude.
  claudeWrapper = pkgs-unstable.writeShellScript "claude-vscode-wrapper" ''
    shift
    exec ${inputs.claude-code.packages.x86_64-linux.default}/bin/claude "$@"
  '';

  settingsTemplateContent = builtins.readFile ./vscode-config/settings.json;
  finalConfigContent = lib.replaceStrings
    ["@shell@" "@claudeWrapper@"]
    [config.userSettings.shell.default "${claudeWrapper}"]
    settingsTemplateContent;

in {
  options = {
    userSettings.vscode = {
      enable = lib.mkEnableOption "Enable vscode";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [
      (cfg.pkgs.vscode-with-extensions.override {
        vscode = cfg.pkgs.vscode-fhs;
        vscodeExtensions = allVscodeExtensions;
      })
      # distribution LaTeX (latexmk, pdflatex, ...) utilisée par LaTeX Workshop
      # avec les paquets supplémentaires (enumitem, titlesec, eurosym, parskip, ...)
      # manquants utilisés par le CV
      (cfg.pkgs.texliveMedium.withPackages (ps: with ps; [
        enumitem
        titlesec
        eurosym
        parskip
      ]))
    ];

    home.file = {
      ".config/Code/User/settings.json".text = finalConfigContent;
      ".config/Code/User/keybindings.json".source = ./vscode-config/keybindings.json;
    };
  };
}