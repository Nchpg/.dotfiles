{ config, lib, ... }:

let
  cfg = config.userSettings.taskTui;
  py = cfg.pkgs.python3Packages;
  term = config.userSettings.terminal.default;

  # tasks-tui hérite de la palette du terminal (curses) → thème Stylix
  # automatique via kitty, comme bluetui pour le bluetooth-picker.
  termCmd =
    if term == "alacritty"
    then "${term} --title tasks-tui -e tasks-tui"
    else "${term} --title tasks-tui tasks-tui";

  # tasks-tui-app (huiiy/GTask) : TUI curses pour Google Tasks, publié sur PyPI.
  # Pas dans nixpkgs, donc on le package ici via buildPythonApplication.
  # Source de vérité : pyproject.toml setuptools, entry point
  #   tasks-tui = tasks_tui.main:cli
  # Dépendances : les libs Google + unicurses. NB : unicurses est importé par
  # tasks_tui/main.py mais ABSENT du pyproject.toml upstream (bug d'empaquetage),
  # on le rajoute donc à la main sinon l'app crash au démarrage.
  tasks-tui = py.buildPythonApplication rec {
    pname = "tasks-tui-app";
    version = "0.1.7";
    pyproject = true;

    src = py.fetchPypi {
      # le sdist s'appelle tasks_tui_app-<ver>.tar.gz (underscores)
      pname = "tasks_tui_app";
      inherit version;
      hash = "sha256-MtqWZ2ajQSCmfIAWA4kEpQ2YcC9tVP1+5/o/03ufTuM=";
    };

    build-system = [ py.setuptools ];

    dependencies = with py; [
      google-api-python-client
      google-auth-oauthlib
      google-auth-httplib2
      unicurses # dép manquante du pyproject upstream (cf. note ci-dessus)
      python-dateutil # idem : importé (dateutil) mais absent du pyproject
    ];

    # Le paquet n'embarque pas de tests. On importe tasks_tui.main pour valider
    # toute la chaîne d'imports (dont unicurses) au build.
    doCheck = false;
    pythonImportsCheck = [ "tasks_tui.main" ];

    meta = {
      description = "TUI curses pour gérer Google Tasks";
      homepage = "https://pypi.org/project/tasks-tui-app/";
      license = lib.licenses.mit;
      mainProgram = "tasks-tui";
    };
  };

in {
  options.userSettings.taskTui = {
    enable = lib.mkEnableOption "task-tui (tasks-tui-app : TUI Google Tasks)";
    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ tasks-tui ];

    # Launcher partagé (bind sway + clic swaybar éventuel), comme les autres pickers.
    home.file.".config/sway/launchers/tasks" = {
      text = ''
        #!/bin/sh
        exec ${termCmd}
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/task-tui.conf".text = ''
      bindsym $mod+t exec ~/.config/sway/launchers/tasks
      for_window [title="tasks-tui"] floating enable, resize set 1200 850, border pixel 2
    '';

    # NOTE secret Google (OAuth) :
    # L'app lit ~/.gtask/client_secrets.json et écrit ~/.gtask/token.json au
    # premier lancement (flux navigateur). Comme tu n'as pas de gestionnaire de
    # secrets (sops/agenix), ce JSON n'est PAS géré par Nix : dépose-le
    # toi-même, hors du repo git :
    #
    #   1. Google Cloud Console → API « Google Tasks » activée
    #   2. Identifiants → OAuth client ID, type « Application de bureau »
    #   3. Télécharge le JSON → ~/.gtask/client_secrets.json
    #   4. `tasks-tui` (1er lancement ouvre le navigateur pour autoriser)
    #
    # Raccourcis : j/k naviguer, o ajouter, c cocher, w sync, q quitter, ? aide.
  };
}
