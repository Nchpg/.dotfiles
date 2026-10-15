{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.task;
  py = cfg.pkgs.python3Packages;

  # Version + hash épinglés automatiquement par update.sh
  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);

  # Publié sur PyPI, pas dans nixpkgs. unicurses est importé par
  # tasks_tui/main.py mais ABSENT du pyproject.toml upstream (bug
  # d'empaquetage) : rajouté à la main sinon l'app crash au démarrage.
  tasks-tui = py.buildPythonApplication rec {
    pname = "tasks-tui-app";
    inherit (pinned) version;
    pyproject = true;

    src = py.fetchPypi {
      # le sdist s'appelle tasks_tui_app-<ver>.tar.gz (underscores)
      pname = "tasks_tui_app";
      inherit version;
      inherit (pinned) hash;
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
      (myLib.desktop.mkFloatingTuiLauncher {
        name = "tasks";
        confName = "task-tui";
        inherit config;
        exec = "tasks-tui";
        keybind = "$mod+t";
        title = "tasks-tui";
        width = 1200;
        height = 850;
      })
      {
        assertions = myLib.sops.assertAvailable {
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
        # activée, via `secrets edit`.
        #
        # Elle le crée en 644 alors qu'il contient un refresh token : lisible
        # par tous, contrairement à celui de vdirsyncer. Remis en 600 (et le
        # dossier en 700) à chaque session.
        systemd.user.tmpfiles.rules = [
          "d %h/.gtask 0700 - - -"
          "z %h/.gtask/token.json 0600 - - -"
        ];
      }
    ]
  );
}
