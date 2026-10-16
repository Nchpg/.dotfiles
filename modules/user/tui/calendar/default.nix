{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.tui.calendar;
  c = (myLib.theme.schemeColors { inherit config themes; }).withHashtag;
  inherit (lib) concatStringsSep mapAttrsToList;

  vdirsyncerBin = "${cfg.pkgs.vdirsyncer}/bin/vdirsyncer";
  syncCmd = ''
    ${vdirsyncerBin} metasync
    ${vdirsyncerBin} sync
  '';

  khalCalendars = concatStringsSep "\n" (
    mapAttrsToList (name: calendar: ''
      [[${name}]]
        path = ~/.calendars/google/${config.sops.placeholder.${calendar.collectionSecret}}/
        color = ${calendar.color}
        readonly = ${if calendar.readonly then "True" else "False"}
    '') cfg.calendars
  );

  calendarSecrets = lib.listToAttrs (
    mapAttrsToList (_: calendar: lib.nameValuePair calendar.collectionSecret { }) cfg.calendars
  );

  vdirsyncerConfig = ''
    [general]
    status_path = "~/.local/state/vdirsyncer/status/"

    [pair google_calendar]
    a = "google_calendar_local"
    b = "google_calendar_remote"
    collections = ["from b"]
    metadata = ["color", "displayname"]

    [storage google_calendar_local]
    type = "filesystem"
    path = "~/.calendars/google/"
    fileext = ".ics"

    [storage google_calendar_remote]
    type = "google_calendar"
    token_file = "~/.config/vdirsyncer/google-token.json"
    client_id = "${config.sops.placeholder."google/client_id"}"
    client_secret = "${config.sops.placeholder."google/client_secret"}"
    start_date = "datetime.now() - timedelta(days=${toString cfg.syncPastDays})"
    end_date = "datetime.now() + timedelta(days=${toString cfg.syncFutureDays})"
    item_types = ["VEVENT"]
  '';
in
{
  options.userSettings.tui.calendar = {
    enable = lib.mkEnableOption "calendar-tui (ikhal + vdirsyncer Google Calendar)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
    syncInterval = lib.mkOption {
      type = lib.types.str;
      default = "2min";
      description = "Intervalle de synchronisation vdirsyncer via systemd user timer.";
    };
    syncPastDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Nombre de jours passés à synchroniser depuis Google Calendar.";
    };
    syncFutureDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 730;
      description = "Nombre de jours futurs à synchroniser depuis Google Calendar.";
    };
    timezone = lib.mkOption {
      type = lib.types.str;
      default = "Europe/Paris";
      description = "Fuseau horaire utilisé par khal.";
    };
    calendars = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            collectionSecret = lib.mkOption {
              type = lib.types.str;
              description = ''
                Nom du secret sops contenant l'ID de collection (= identifiant Google,
                PII) de cet agenda. La valeur est insérée dans la config khal à
                l'activation, jamais en clair dans le repo.
              '';
              example = "calendars/perso";
            };
            color = lib.mkOption {
              type = lib.types.str;
              description = "Couleur khal pour cet agenda.";
            };
            readonly = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Empêche l'édition de cet agenda depuis ikhal.";
            };
          };
        }
      );
      default = {
        perso = {
          collectionSecret = "calendars/perso";
          color = "light green";
        };
        epita = {
          collectionSecret = "calendars/epita";
          color = "light blue";
          readonly = true;
        };
        feries = {
          collectionSecret = "calendars/feries";
          color = "yellow";
          readonly = true;
        };
      };
      description = "Agendas Google exposés à khal (ID via sops), avec couleur par type.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.desktop.mkFloatingTuiLauncher {
        name = "calendar";
        confName = "calendar-tui";
        inherit config;
        exec = "ikhal";
        preamble = ''
          set -eu

          # XDG_RUNTIME_DIR (privé) ou $HOME en repli, jamais /tmp partagé.
          if [ -f "$HOME/.config/vdirsyncer/config" ]; then
            {
              ${syncCmd}
            } >"''${XDG_RUNTIME_DIR:-$HOME/.cache}/calendar-tui-vdirsyncer.log" 2>&1 || true
          fi

        '';
        keybind = "$mod+c";
        title = "calendar-tui";
        width = 1500;
        height = 950;
      })
      {
        assertions = myLib.sops.assertAvailable {
          inherit config;
          optionName = "userSettings.tui.calendar";
          need = "a besoin des secrets sops (Google Agenda)";
        };

        home.packages = with cfg.pkgs; [
          khal
          vdirsyncer
        ];

        sops.templates."khal-config" = {
          path = "${config.home.homeDirectory}/.config/khal/config";
          content = ''
            [calendars]
            ${khalCalendars}

            [locale]
              local_timezone = ${cfg.timezone}
              default_timezone = ${cfg.timezone}
              timeformat = %H:%M
              dateformat = %d/%m/%Y
              longdateformat = %d/%m/%Y
              datetimeformat = %d/%m/%Y %H:%M
              longdatetimeformat = %d/%m/%Y %H:%M

            [default]
              default_calendar = perso
              enable_mouse = false
              timedelta = 1h
              highlight_event_days = true
              show_all_days = true

            [keybindings]
              quit = q, Q, esc

            [palette]
              header = white, black, default, '${c.base05}', '${c.base00}'
              footer = white, black, default, '${c.base04}', '${c.base00}'
              line header = black, white, bold, '${c.base05}', '${c.base02}'
              alt header = white, black, bold, '${c.base05}', '${c.base00}'
              bright = yellow, black, bold, '${c.base05}', '${c.base02}'
              list = white, black, default, '${c.base05}', '${c.base00}'
              list focused = black, light blue, bold, '${c.base06}', '${c.base02}'
              edit = white, black, default, '${c.base05}', '${c.base01}'
              edit focus = black, light cyan, default, '${c.base06}', '${c.base02}'
              button = white, black, default, '${c.base05}', '${c.base02}'
              button focused = black, light green, bold, '${c.base06}', '${c.base03}'
              reveal focus = black, yellow, default, '${c.base06}', '${c.base02}'
              today focus = black, light blue, bold, '${c.base06}', '${c.base02}'
              today = light green, black, default, '${c.base0B}', '${c.base01}'
              date header = light gray, black, default, '${c.base04}', '${c.base00}'
              date header focused = black, light blue, bold, '${c.base06}', '${c.base02}'
              date header selected = black, light green, default, '${c.base05}', '${c.base01}'
              dayname = light gray, black, default, '${c.base04}', '${c.base00}'
              monthname = light gray, black, default, '${c.base04}', '${c.base00}'
              weeknumber_right = light gray, black, default, '${c.base03}', '${c.base00}'
              alert = white, dark red, bold, '${c.base00}', '${c.base08}'
              mark = black, light green, bold, '${c.base06}', '${c.base03}'
              frame = light gray, black, default, '${c.base03}', '${c.base00}'
              frame focus = light blue, black, bold, '${c.base05}', '${c.base00}'
              frame focus color = light blue, black, bold, '${c.base05}', '${c.base00}'
              frame focus top = light magenta, black, bold, '${c.base05}', '${c.base00}'
              eventcolumn = white, black, default, '${c.base05}', '${c.base00}'
              eventcolumn focus = white, black, default, '${c.base05}', '${c.base00}'
              calendar = white, black, default, '${c.base05}', '${c.base00}'
              calendar focus = white, black, default, '${c.base05}', '${c.base00}'
              editbx = white, black, default, '${c.base05}', '${c.base01}'
              editcp = black, light blue, standout, '${c.base06}', '${c.base03}'
              popupbg = white, black, default, '${c.base05}', '${c.base00}'
              popupper = black, light blue, bold, '${c.base06}', '${c.base02}'
              caption = light blue, black, bold, '${c.base05}', '${c.base00}'
          '';
        };

        sops.secrets = calendarSecrets // {
          "google/client_id" = { };
          "google/client_secret" = { };
        };
        sops.templates."vdirsyncer-config" = {
          content = vdirsyncerConfig;
          path = "${config.home.homeDirectory}/.config/vdirsyncer/config";
        };

        home.file.".calendars/google/.keep".text = "";

        systemd.user.services.calendar-tui-sync = {
          Unit.Description = "Synchronisation Google Calendar pour ikhal";
          Service = {
            Type = "oneshot";
            # Au réveil le Wi-Fi n'est souvent pas revenu : on réessaie.
            Restart = "on-failure";
            RestartSec = "30s";
            ExecStart = "${cfg.pkgs.writeShellScript "calendar-tui-sync" ''
              set -eu
              [ -f "$HOME/.config/vdirsyncer/config" ] || exit 0
              ${syncCmd}
            ''}";
          };
        };
        systemd.user.timers.calendar-tui-sync = {
          Unit.Description = "Synchronise périodiquement Google Calendar pour ikhal";
          Timer = {
            OnBootSec = "1min";
            OnUnitActiveSec = cfg.syncInterval;
          };
          Install.WantedBy = [ "timers.target" ];
        };

      }
    ]
  );
}
