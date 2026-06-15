{ config, lib, ... }:

let
  cfg = config.userSettings.calendarTui;
  term = config.userSettings.terminal.default;
  c = config.lib.stylix.colors.withHashtag;
  inherit (lib) concatStringsSep mapAttrsToList;

  termCmd =
    if term == "alacritty"
    then "${term} --title calendar-tui -e ikhal"
    else "${term} --title calendar-tui ikhal";

  vdirsyncerBin = "${cfg.pkgs.vdirsyncer}/bin/vdirsyncer";
  syncCmd = ''
    ${vdirsyncerBin} metasync
    ${vdirsyncerBin} sync
  '';

  khalCalendars = concatStringsSep "\n"
    (mapAttrsToList
      (name: calendar: ''
          [[${name}]]
            path = ~/.calendars/google/${calendar.collection}/
            color = ${calendar.color}
            readonly = ${if calendar.readonly then "True" else "False"}
      '')
      cfg.calendars);

  # vdirsyncer a besoin du client_id/client_secret Google directement dans sa
  # config. On fournit donc un template, mais pas le vrai fichier, pour éviter
  # de pousser des secrets OAuth dans Git ou dans le store Nix.
  vdirsyncerExample = ''
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
    client_id = "REMPLACE_MOI.apps.googleusercontent.com"
    client_secret = "REMPLACE_MOI"
    start_date = "datetime.now() - timedelta(days=${toString cfg.syncPastDays})"
    end_date = "datetime.now() + timedelta(days=${toString cfg.syncFutureDays})"
    item_types = ["VEVENT"]
  '';

in {
  options.userSettings.calendarTui = {
    enable = lib.mkEnableOption "calendar-tui (ikhal + vdirsyncer Google Calendar)";
    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
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
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          collection = lib.mkOption {
            type = lib.types.str;
            description = "Nom de collection vdirsyncer sous ~/.calendars/google.";
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
      });
      default = {
        perso = {
          collection = "nathanchampagne49@gmail.com";
          color = "light green";
        };
        epita = {
          collection = "0lp4mj4mb0vh4i10orso9rq697ng5q87@import.calendar.google.com";
          color = "light blue";
          readonly = true;
        };
        feries = {
          collection = "cpp2spjicln66q13d1nmoqb4c5sk0pridtqn0bjm5phm2r35dpi62shectnmuprcckn66rrd@virtual";
          color = "yellow";
          readonly = true;
        };
      };
      description = "Agendas Google exposés à khal, avec couleur par type.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with cfg.pkgs; [
      khal
      vdirsyncer
    ];

    xdg.configFile."khal/config".text = ''
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

    xdg.configFile."vdirsyncer/config.example".text = vdirsyncerExample;

    home.file.".calendars/google/.keep".text = "";

    home.file.".config/sway/launchers/calendar" = {
      text = ''
        #!/bin/sh
        set -eu

        if [ -f "$HOME/.config/vdirsyncer/config" ]; then
          ${syncCmd} >/tmp/calendar-tui-vdirsyncer.log 2>&1 || true
        fi

        exec ${termCmd}
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/calendar-tui.conf".text = ''
      bindsym $mod+c exec ~/.config/sway/launchers/calendar
      for_window [title="calendar-tui"] floating enable, resize set 1500 950, border pixel 2
    '';

    # Synchro périodique Google Calendar <-> vdir local. Le service ne fait rien
    # tant que ~/.config/vdirsyncer/config n'a pas été créé depuis le template.
    systemd.user.services.calendar-tui-sync = {
      Unit.Description = "Synchronisation Google Calendar pour ikhal";
      Service = {
        Type = "oneshot";
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

    # Setup OAuth, hors repo :
    #
    #   mkdir -p ~/.config/vdirsyncer
    #   cp ~/.config/vdirsyncer/config.example ~/.config/vdirsyncer/config
    #   chmod 600 ~/.config/vdirsyncer/config
    #
    # Dans Google Cloud Console :
    #   1. Activer l'API CalDAV (pas seulement Google Calendar API)
    #   2. Créer un OAuth Client ID de type "Desktop application"
    #   3. Coller client_id/client_secret dans ~/.config/vdirsyncer/config
    #   4. Lancer `vdirsyncer discover`, puis `vdirsyncer sync`
    #
    # Ensuite : Mod+c ouvre ikhal. La synchro tourne aussi via timer user.
  };
}
