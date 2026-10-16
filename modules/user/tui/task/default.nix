{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.task;
  py = cfg.pkgs.python3Packages;

  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);

  # Publié sur PyPI, pas dans nixpkgs. unicurses et python-dateutil sont
  # importés mais absents du pyproject upstream : ajoutés sinon crash au démarrage.
  tasks-tui = py.buildPythonApplication rec {
    pname = "tasks-tui-app";
    inherit (pinned) version;
    pyproject = true;

    src = py.fetchPypi {
      pname = "tasks_tui_app";
      inherit version;
      inherit (pinned) hash;
    };

    build-system = [ py.setuptools ];

    postPatch = ''
      substituteInPlace tasks_tui/main.py \
        --replace "[ord('q'), ord('Q')]" "[ord('q'), ord('Q'), 27]"
    '';

    dependencies = with py; [
      google-api-python-client
      google-auth-oauthlib
      google-auth-httplib2
      unicurses
      python-dateutil
    ];

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
        # L'app écrit ~/.gtask/token.json (refresh token) en 644 : remis en 600 à chaque session.
        systemd.user.tmpfiles.rules = [
          "d %h/.gtask 0700 - - -"
          "z %h/.gtask/token.json 0600 - - -"
        ];
      }
    ]
  );
}
