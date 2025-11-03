{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.vscode;
  marketplaceExtensions = cfg.pkgs.vscode-utils.extensionsFromVscodeMarketplace [
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

    # python
    {
      name = "vscode-python-envs";
      publisher = "ms-python";
      version = "1.10.0";
      sha256 = "sha256-fhrV9sPjgwp1+ZDMu7iU7To2R0hcAF388w99yCMiHQA=";
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
  ];


  allVscodeExtensions = with cfg.pkgs.vscode-extensions; [
    # python
    ms-python.python
    ms-python.debugpy
    ms-python.python
    ms-python.vscode-pylance
    ms-toolsai.jupyter-keymap

    # c/cpp
    llvm-vs-code-extensions.vscode-clangd

    # go
    golang.go

    # nix
    bbenoist.nix

    # vim
    vscodevim.vim

    # git
    eamodio.gitlens

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
    pkief.material-icon-theme

    # databases
    cweijan.dbclient-jdbc


  ] ++ marketplaceExtensions;

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
        vscodeExtensions = allVscodeExtensions;
      })
    ];

    home.file = {
      ".config/Code/User/settings.json".source = ./vscode-config/settings.json;
      ".config/Code/User/keybindings.json".source = ./vscode-config/keybindings.json;
    };
  };
}