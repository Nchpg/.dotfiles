{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Un message Discord par app dont les images ont changé au dernier déploiement, une fois qu'elle répond.
let
  cfg = config.systemSettings.appImages;
  images = cfg.helpers;
  notify = config.systemSettings.notify.discord;

  deployed = lib.mapAttrs (_: app: {
    inherit (app) domain;
    port = app.hostPortEffective;
    images = map (c: images.image c.image) (lib.attrValues app.containers);
    revisions = lib.unique (
      lib.filter (r: r != null) (
        map (c: (images.entry c.image).revision or null) (lib.attrValues app.containers)
      )
    );
  }) config.systemSettings.apps;

  deployedFile = pkgs-stable.writeText "apps-deployed.json" (builtins.toJSON deployed);

  script = pkgs-stable.writeShellApplication {
    name = "apps-announce";
    runtimeInputs = with pkgs-stable; [
      curl
      jq
      coreutils
    ];
    text = ''
      current=${deployedFile}
      previous="$STATE_DIRECTORY/deployed.json"

      # Copie inscriptible (le fichier du store est en lecture seule), remplacée d'un coup.
      remember() {
        install -m 600 "$current" "$previous.new"
        mv -f "$previous.new" "$previous"
      }

      # Premier passage : on retient l'état sans annoncer toutes les apps.
      if [ ! -f "$previous" ]; then
        remember
        exit 0
      fi

      umask 077
      conf=$(mktemp)
      trap 'rm -f "$conf"' EXIT
      # URL via un fichier de config curl, pas argv (lisible par tous).
      printf 'url = "%s"\n' "$(cat "$CREDENTIALS_DIRECTORY/webhook")" > "$conf"

      for app in $(jq -r 'keys[]' "$current"); do
        now=$(jq -c --arg a "$app" '.[$a].images' "$current")
        before=$(jq -c --arg a "$app" '.[$a].images // null' "$previous")
        [ "$now" = "$before" ] && continue

        what="mise à jour"
        [ "$before" = null ] && what="en ligne"
        domain=$(jq -r --arg a "$app" '.[$a].domain' "$current")
        port=$(jq -r --arg a "$app" '.[$a].port' "$current")
        rev=$(jq -r --arg a "$app" '.[$a].revisions | map(.[0:7]) | join(", ")' "$current")

        # Jusqu'à 2 min pour démarrer (sonde de santé, base qui s'initialise).
        code=000
        for _ in $(seq 1 24); do
          code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/" || true)
          case "$code" in 2* | 3*) break ;; esac
          sleep 5
        done
        case "$code" in
          2* | 3*) state="répond ($code)" icon="🚀" ;;
          *) state="**ne répond pas** ($code)" icon="⚠️" ;;
        esac

        # flags 4 : pas d'aperçu du lien sous le message.
        jq -n --arg c "$icon **$app** $what : https://$domain''${rev:+ · commit \`$rev\`} · $state" '{content: $c, flags: 4}' \
          | curl --silent --show-error --max-time 20 --config "$conf" \
              --header 'Content-Type: application/json' --data @- > /dev/null \
          || echo "$app : envoi Discord en échec" >&2
      done

      remember
    '';
  };
in
{
  options.systemSettings.appImages.announce = lib.mkEnableOption "message Discord quand une app change de version";

  config = lib.mkIf (cfg.announce && config.systemSettings.apps != { }) {
    assertions = [
      {
        assertion = notify.enable;
        message = "systemSettings.appImages.announce passe par le webhook de systemSettings.notify.discord : active-le.";
      }
    ];

    # Relancé à chaque déploiement qui change une image. Il ne fait que lancer l'annonce sans
    # l'attendre : le switch ne dépend ni de Discord ni du temps que met une app à répondre.
    systemd.services.apps-announce = {
      description = "Déclenche l'annonce Discord des apps mises à jour";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ deployedFile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe' config.systemd.package "systemctl"} start --no-block apps-announce-run.service";
      };
    };

    # Après les conteneurs : la file de systemd l'ordonne derrière leurs redémarrages.
    systemd.services.apps-announce-run = {
      description = "Annonce sur Discord les apps qui ont changé de version";
      after = [
        "network-online.target"
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (
          appName: app: map (c: "podman-${appName}-${c}.service") (lib.attrNames app.containers)
        ) config.systemSettings.apps
      );
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe script;
        StateDirectory = "apps-announce";
        LoadCredential = "webhook:${config.sops.secrets.${notify.webhookKey}.path}";
        TimeoutStartSec = "15min";

        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
