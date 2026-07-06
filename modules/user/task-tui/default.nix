{ config, lib, ... }:

let
  cfg = config.userSettings.taskTui;
  py = cfg.pkgs.python3Packages;
  term = config.userSettings.terminal.default;

  # tasks-tui hérite de la palette du terminal (curses) → thème Stylix
  # automatique via kitty, comme bluetui pour le bluetooth-picker.
  termCmd =
    if term == "alacritty" then
      "${term} --title tasks-tui -e tasks-tui"
    else
      "${term} --title tasks-tui tasks-tui";

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

    # Unifier la sortie avec les autres TUIs : Esc quitte comme q. On ajoute
    # le code touche 27 (Esc) à la condition de quit. On passe ainsi par le
    # MÊME chemin propre que q (synchro vers Google AVANT de fermer), contrairement
    # à une fermeture forcée de la fenêtre qui perdrait les modifs non synchronisées.
    postPatch = ''
      substituteInPlace tasks_tui/main.py \
        --replace "[ord('q'), ord('Q')]" "[ord('q'), ord('Q'), 27]"
    '';

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

in
{
  options.userSettings.taskTui = {
    enable = lib.mkEnableOption "task-tui (tasks-tui-app : TUI Google Tasks)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
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

    # Secrets OAuth Google (les MEMES que vdirsyncer/calendar-tui : source de
    # verite unique dans secrets/secrets.yaml sous `google:`). On ne stocke pas
    # le client_secrets.json complet : on le GENERE a partir des sous-cles, pour
    # eviter toute duplication des identifiants.
    sops.secrets."google/client_id" = { };
    sops.secrets."google/client_secret" = { };
    sops.secrets."google/project_id" = { };
    sops.templates."gtask-client-secrets" = {
      path = "${config.home.homeDirectory}/.gtask/client_secrets.json";
      content = builtins.toJSON {
        installed = {
          client_id = config.sops.placeholder."google/client_id";
          client_secret = config.sops.placeholder."google/client_secret";
          project_id = config.sops.placeholder."google/project_id";
          auth_uri = "https://accounts.google.com/o/oauth2/auth";
          token_uri = "https://oauth2.googleapis.com/token";
          auth_provider_x509_cert_url = "https://www.googleapis.com/oauth2/v1/certs";
          redirect_uris = [ "http://localhost" ];
        };
      };
    };
    # L'app lit ce client_secrets.json, puis ecrit ~/.gtask/token.json au 1er
    # lancement (flux navigateur) -- token runtime mutable, hors sops.
    #
    # Setup (une fois) : memes identifiants OAuth que calendar-tui, dans un projet
    # Google Cloud ou l'API « Google Tasks » est aussi activee. Renseigner via
    #   sops secrets/secrets.yaml   ->   google.client_id / client_secret / project_id
    # puis `nixos-rebuild switch`, puis `tasks-tui` (1er lancement = navigateur).
    #
    # Raccourcis : j/k naviguer, o ajouter, c cocher, w sync, q quitter, ? aide.
  };
}
