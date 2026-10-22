{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Un message Discord par app qui a changé au dernier déploiement : nouvelle image, réglages
# modifiés, app ajoutée (une fois qu'elle répond) ou supprimée. Une app qui s'ouvre (devient
# publique, ou perd le portail) le dit en clair.
let
  cfg = config.systemSettings.appImages;
  images = cfg.helpers;
  notify = config.systemSettings.notify.discord;

  deployed = lib.mapAttrs (_: app: {
    inherit (app) domain expose;
    sso = app.sso.enable;
    port = app.hostPortEffective;
    probe = if app.probe == null then "/" else app.probe.path;
    images = map (c: images.image c.image) (lib.attrValues app.containers);
    revisions = lib.unique (
      lib.filter (r: r != null) (
        map (c: (images.entry c.image).revision or null) (lib.attrValues app.containers)
      )
    );
    # Ce que les réglages produisent, sans les images : une différence = « réglages appliqués ».
    settings = builtins.hashString "sha256" (
      builtins.toJSON {
        inherit (app)
          domain
          expose
          allowedNetworks
          internetAccess
          entrypoint
          probe
          ;
        sso = app.sso.enable;
        rateLimit = {
          inherit (app.rateLimit) enable paths;
        };
        containers = lib.mapAttrs (_: c: {
          inherit (c)
            memory
            dependsOn
            volumes
            environmentFiles
            ;
        }) app.containers;
      }
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

      post() {
        # flags 4 : pas d'aperçu du lien sous le message.
        jq -n --arg c "$1" '{content: $c, flags: 4}' \
          | curl --silent --show-error --max-time 20 --config "$conf" \
              --header 'Content-Type: application/json' --data @- > /dev/null \
          || echo "envoi Discord en échec" >&2
      }

      # Jusqu'à 2 min pour démarrer (sonde de santé, base qui s'initialise).
      answer() {
        local code=000
        for _ in $(seq 1 24); do
          code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$1$2" || true)
          case "$code" in 2* | 3*) break ;; esac
          sleep 5
        done
        echo "$code"
      }

      for app in $(jq -rn --slurpfile a "$current" --slurpfile b "$previous" '$a[0] + $b[0] | keys[]'); do
        now=$(jq -c --arg a "$app" '.[$a] // null' "$current")
        before=$(jq -c --arg a "$app" '.[$a] // null' "$previous")

        if [ "$now" = null ]; then
          domain=$(jq -r .domain <<< "$before")
          post "🗑️ **$app** supprimé : https://$domain ne répond plus. Ses données restent sur think."
          continue
        fi

        domain=$(jq -r .domain <<< "$now")
        rev=$(jq -r '.revisions | map(.[0:7]) | join(", ")' <<< "$now")

        if [ "$before" = null ]; then
          icon="🆕" what="en ligne"
        else
          # Ancien format d'état (sans `settings`) : seules les images comptent, pas de rafale au passage.
          images=$(jq -n --argjson a "$now" --argjson b "$before" '$a.images != $b.images')
          settings=$(jq -n --argjson a "$now" --argjson b "$before" '($b.settings // $a.settings) != $a.settings')
          if [ "$images" = true ]; then
            icon="🚀" what="mis à jour"
          elif [ "$settings" = true ]; then
            icon="⚙️" what="réglages appliqués"
          else
            continue
          fi
        fi

        code=$(answer "$(jq -r .port <<< "$now")" "$(jq -r .probe <<< "$now")")
        case "$code" in
          2* | 3*) state="répond ($code)" ;;
          *) state="**ne répond pas** ($code)" icon="⚠️" ;;
        esac

        message="$icon **$app** $what : https://$domain''${rev:+ · commit \`$rev\`} · $state"
        if [ "$before" != null ]; then
          old=$(jq -r .domain <<< "$before")
          [ "$old" = "$domain" ] || message+=$'\n'"↪️ nouvelle adresse (avant : $old)"
          if [ "$(jq -r '.expose // "public"' <<< "$before")" = vpn ] && [ "$(jq -r .expose <<< "$now")" = public ]; then
            message+=$'\n'"🔓 **$app** est maintenant **public** : ouvert à tout internet."
          fi
          if [ "$(jq -r '.sso // false' <<< "$before")" = true ] && [ "$(jq -r .sso <<< "$now")" = false ]; then
            message+=$'\n'"🔓 **$app** n'exige plus la connexion Authelia."
          fi
        fi
        post "$message"
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
