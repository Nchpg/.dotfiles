{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.task;
  py = cfg.pkgs.python3Packages;
  term = config.userSettings.terminal.default;

  termCmd = myLib.mkTerminalCmd {
    inherit lib term;
    title = "tasks-tui";
    exec = "tasks-tui";
  };

  # Publié sur PyPI, pas dans nixpkgs. unicurses est importé par
  # tasks_tui/main.py mais ABSENT du pyproject.toml upstream (bug
  # d'empaquetage) : rajouté à la main sinon l'app crash au démarrage.
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

    # Esc quitte comme q (code touche 27), même chemin propre (synchro
    # Google avant fermeture) plutôt qu'une fermeture forcée qui perdrait
    # les modifs non synchronisées.
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

    doCheck = false; # pas de tests amont
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
  options.userSettings.tui.task = {
    enable = lib.mkEnableOption "task-tui (tasks-tui-app : TUI Google Tasks)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.mkFloatingTuiLauncher {
        name = "tasks";
        confName = "task-tui";
        scriptBody = "exec ${termCmd}";
        keybind = "$mod+t";
        title = "tasks-tui";
        width = 1200;
        height = 850;
      })
      {
        assertions = myLib.assertSopsAvailable {
          inherit config;
          optionName = "userSettings.tui.task";
          need = "a besoin des secrets sops (Google Tasks)";
        };

        home.packages = [ tasks-tui ];

        # Mêmes secrets OAuth que vdirsyncer/calendar-tui (source unique
        # sous `google:`) : client_secrets.json généré depuis les sous-clés.
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
        # L'app écrit ~/.gtask/token.json au 1er lancement (flux navigateur),
        # token runtime mutable, hors sops. Setup : mêmes identifiants OAuth
        # que calendar-tui, projet Google Cloud avec l'API "Google Tasks"
        # activée, via `sops secrets/secrets.yaml`.
      }
    ]
  );
}
