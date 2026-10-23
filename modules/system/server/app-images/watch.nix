{
  config,
  lib,
  pkgs-stable,
  ...
}:

# think repère lui-même une nouvelle image de ses apps et demande son épinglage (apps.yml, action pin) :
# rien à poser dans les dépôts des apps, un seul jeton, ici.
let
  cfg = config.systemSettings.appImages;
  watch = cfg.watch;
  images = cfg.helpers;
  notify = config.systemSettings.notify.discord;

  # Le même que deploy.nix et apps.yml.
  lockPath = "profiles/server/apps.lock.json";

  owner = lib.toLower (lib.elemAt (lib.splitString "/" (toString cfg.registry)) 1);

  # { app = [ { ref; digest; } ]; } : images du registre propre, avec le digest déployé.
  watched = lib.filterAttrs (_: l: l != [ ]) (
    lib.mapAttrs (
      _: app:
      map (c: {
        ref = images.ref c.image;
        inherit ((images.entry c.image)) digest;
      }) (lib.filter (c: images.own c.image) (lib.attrValues app.containers))
    ) config.systemSettings.apps
  );

  watchedFile = pkgs-stable.writeText "apps-watched.json" (builtins.toJSON watched);

  script = pkgs-stable.writeShellApplication {
    name = "apps-watch";
    runtimeInputs = with pkgs-stable; [
      curl
      jq
      gnused
      gnugrep
      coreutils
      git
    ];
    text = builtins.readFile ../../../../scripts/lib/registry.sh + ''
      apps=${watchedFile}
      repo=${lib.escapeShellArg watch.repository}
      # La branche que suit apps-deploy : lock lu et épinglage demandé sur elle.
      branch=${lib.escapeShellArg cfg.deploy.branch}
      state="$STATE_DIRECTORY"
      now=$(date +%s)

      umask 077
      REG_WORK=$(mktemp -d)
      trap 'rm -rf "$REG_WORK"' EXIT

      GHCR_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/ghcr" 2>/dev/null || true)
      printf 'header = "Authorization: Bearer %s"\n' "$(cat "$CREDENTIALS_DIRECTORY/dispatch")" > "$REG_WORK/github"
      # URL via un fichier de config curl, pas argv (lisible par tous).
      printf 'url = "%s"\n' "$(cat "$CREDENTIALS_DIRECTORY/webhook")" > "$REG_WORK/webhook"

      # Un message par app tant que le problème dure : `$app.alerted` tombe avec lui (unstuck).
      warn() {
        [ -e "$state/$1.alerted" ] && return 0
        if jq -n --arg c "⚠️ **$1** : $2" '{content: $c, flags: 4}' \
          | curl --silent --show-error --max-time 20 --config "$REG_WORK/webhook" \
              --header 'Content-Type: application/json' --data @- > /dev/null; then
          touch "$state/$1.alerted"
        else
          echo "envoi Discord en échec" >&2
        fi
      }

      # Bloqué : silence la première demi-heure (une CI qui publie, un registre qui hoquette), puis alerte.
      stuck() {
        [ -f "$state/$1.stuck" ] || echo "$now" > "$state/$1.stuck"
        since=$(cat "$state/$1.stuck")
        echo "$1 : $2" >&2
        if [ $((now - since)) -ge 1800 ]; then
          warn "$1" "$2, depuis $(((now - since) / 60)) min : le site n'est pas mis à jour."
        fi
      }

      unstuck() {
        rm -f "$state/$1" "$state/$1.stuck" "$state/$1.alerted"
      }

      # Lock de la tête de ${watch.repository}, lu par son commit : pas de cache périmé.
      github_lock() {
        [ -s "$REG_WORK/lock" ] && return 0
        rev=$(git ls-remote "https://github.com/$repo.git" "refs/heads/$branch" | cut -f1)
        [ -n "$rev" ] || return 1
        curl -fsS --max-time 20 -o "$REG_WORK/lock" \
          "https://raw.githubusercontent.com/$repo/$rev/${lockPath}"
      }

      for app in $(jq -r 'keys[]' "$apps"); do
        # Une requête HEAD par image tant que rien ne bouge.
        changed=0
        while read -r ref deployed; do
          if ! current=$(reg_digest "$ref" 2> /dev/null); then
            stuck "$app" "image \`$ref\` illisible sur le registre (jeton \`ghcr/token\` ?)"
            continue 2
          fi
          [ "$current" = "$deployed" ] || changed=1
        done < <(jq -r --arg a "$app" '.[$a][] | "\(.ref) \(.digest)"' "$apps")
        if [ "$changed" = 0 ]; then
          unstuck "$app"
          continue
        fi

        found="[]"
        for ref in $(jq -r --arg a "$app" '.[$a][].ref' "$apps"); do
          if ! info=$(reg_inspect "$ref"); then
            stuck "$app" "image \`$ref\` illisible sur le registre"
            continue 2
          fi
          found=$(jq -c --arg ref "$ref" --argjson i "$info" '. + [$i + {$ref}]' <<< "$found")
        done

        # Les images d'un même dépôt partent ensemble : on attend qu'elles portent toutes le même commit.
        if ! jq -e 'group_by(.source) | all(map(.revision) | unique | length == 1)' <<< "$found" > /dev/null; then
          stuck "$app" "ses images viennent de commits différents (une CI a échoué ?)"
          continue
        fi

        # Déjà épinglé sur GitHub : le déploiement est l'affaire d'apps-deploy.
        if ! github_lock; then
          stuck "$app" "lock illisible sur GitHub"
          continue
        fi
        if jq -e --argjson f "$found" '. as $l | $f | all(.[]; $l[.ref].digest == .digest)' "$REG_WORK/lock" > /dev/null; then
          unstuck "$app"
          continue
        fi

        # Une demande par jeu de digests et par quart d'heure : apps.yml a le temps de passer, et
        # un appel perdu (workflow en échec, GitHub indisponible) est refait.
        key=$(jq -r 'map(.digest) | sort | join(",")' <<< "$found" | sha256sum | cut -c1-16)
        last_key="" last_at=0
        [ -f "$state/$app" ] && read -r last_key last_at < "$state/$app"
        if [ "$last_key" = "$key" ]; then
          [ $((now - ''${last_at:-0})) -lt 900 ] && continue
          warn "$app" "épinglage demandé il y a plus d'un quart d'heure, toujours absent du lock (\`apps.yml\` en échec ?). Nouvel essai tous les quarts d'heure."
        fi
        echo "$key $now" > "$state/$app"

        # Révision gardée seulement si elle vient d'un dépôt à soi (sinon : label hérité de l'image de base).
        payload=$(jq -c --arg owner "github.com/${owner}/" 'map({ref, digest, port,
          revision: (if (.source // "" | ascii_downcase | contains($owner)) then .revision else null end)})' <<< "$found")
        body=$(jq -nc --arg images "$payload" --arg ref "$branch" '{$ref, inputs: {action: "pin", images: $images, source: "think"}}')

        if curl -fsS --max-time 20 --config "$REG_WORK/github" -X POST \
             -H "Accept: application/vnd.github+json" --data "$body" \
             "https://api.github.com/repos/$repo/actions/workflows/apps.yml/dispatches"; then
          echo "$app : nouvelle version, épinglage demandé"
        else
          warn "$app" "épinglage refusé par GitHub (jeton \`${watch.tokenKey}\` expiré ?). Nouvel essai tous les quarts d'heure ; rattrapage à la main : \`dots update apps\`."
        fi
      done
    '';
  };
in
{
  options.systemSettings.appImages.watch = {
    enable = lib.mkEnableOption "surveillance des tags par think, qui demande l'épinglage des nouvelles images";

    repository = lib.mkOption {
      type = lib.types.str;
      default = "Nchpg/.dotfiles";
      description = "Dépôt qui porte le lock et apps.yml.";
    };

    tokenKey = lib.mkOption {
      type = lib.types.str;
      default = "github/dispatch_token";
      description = ''
        Clé sops d'un PAT fine-grained limité à `repository`, permission
        « Actions: Read and write » seule : il ne fait que lancer apps.yml.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
      description = "Écart entre deux passages (une requête HEAD par image).";
    };
  };

  config = lib.mkIf watch.enable {
    assertions = [
      {
        assertion = cfg.registry != null && cfg.lockFile != null;
        message = "systemSettings.appImages.watch exige `registry` et `lockFile`.";
      }
      {
        assertion = notify.enable;
        message = "systemSettings.appImages.watch prévient sur le webhook de systemSettings.notify.discord : active-le.";
      }
    ];

    sops.secrets.${watch.tokenKey} = { };

    systemd.services.apps-watch = {
      description = "Repère les nouvelles images des apps et demande leur épinglage";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe script;
        StateDirectory = "apps-watch";
        LoadCredential = [
          "dispatch:${config.sops.secrets.${watch.tokenKey}.path}"
          "webhook:${config.sops.secrets.${notify.webhookKey}.path}"
        ]
        ++ lib.optional (cfg.login != null) "ghcr:${config.sops.secrets.${cfg.login.passwordKey}.path}";

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

    systemd.timers.apps-watch = {
      description = "Surveillance des images des apps";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = watch.interval;
      };
    };

    systemSettings.notify.discord.units = [ "apps-watch" ];
  };
}
