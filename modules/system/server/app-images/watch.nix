{
  config,
  lib,
  pkgs-stable,
  ...
}:

# think repère lui-même une nouvelle image de ses apps et demande son épinglage (apps-bump.yml) :
# rien à poser dans les dépôts des apps, un seul jeton, ici.
let
  cfg = config.systemSettings.appImages;
  watch = cfg.watch;
  images = cfg.helpers;

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
    ];
    text = builtins.readFile ../../../../scripts/lib/registry.sh + ''
      apps=${watchedFile}
      state="$STATE_DIRECTORY"

      umask 077
      REG_WORK=$(mktemp -d)
      trap 'rm -rf "$REG_WORK"' EXIT

      GHCR_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/ghcr" 2>/dev/null || true)
      printf 'header = "Authorization: Bearer %s"\n' "$(cat "$CREDENTIALS_DIRECTORY/dispatch")" > "$REG_WORK/github"

      status=0
      for app in $(jq -r 'keys[]' "$apps"); do
        # Une requête HEAD par image tant que rien ne bouge.
        changed=0
        readable=1
        while read -r ref deployed; do
          if ! current=$(reg_digest "$ref" 2> /dev/null); then
            echo "$app : $ref illisible, nouvel essai au prochain passage" >&2
            readable=0
            break
          fi
          [ "$current" = "$deployed" ] || changed=1
        done < <(jq -r --arg a "$app" '.[$a][] | "\(.ref) \(.digest)"' "$apps")
        [ "$readable" = 1 ] && [ "$changed" = 1 ] || continue

        found="[]"
        for ref in $(jq -r --arg a "$app" '.[$a][].ref' "$apps"); do
          info=$(reg_inspect "$ref") || continue 2
          found=$(jq -c --arg ref "$ref" --argjson i "$info" '. + [$i + {$ref}]' <<< "$found")
        done

        # Les images d'un même dépôt partent ensemble : on attend qu'elles portent toutes le même commit.
        if ! jq -e 'group_by(.source) | all(map(.revision) | unique | length == 1)' <<< "$found" > /dev/null; then
          echo "$app : images de commits différents, la CI n'a pas fini de les publier"
          continue
        fi

        # Une seule demande par jeu de digests, réussie ou non : pas de rafale si GitHub refuse.
        key=$(jq -r 'map(.digest) | sort | join(",")' <<< "$found" | sha256sum | cut -c1-16)
        [ "$(cat "$state/$app" 2> /dev/null || true)" = "$key" ] && continue
        echo "$key" > "$state/$app"

        # Révision gardée seulement si elle vient d'un dépôt à soi (sinon : label hérité de l'image de base).
        payload=$(jq -c --arg owner "github.com/${owner}/" 'map({ref, digest, port,
          revision: (if (.source // "" | ascii_downcase | contains($owner)) then .revision else null end)})' <<< "$found")
        body=$(jq -nc --arg images "$payload" '{ref: "main", inputs: {images: $images, source: "think"}}')

        if curl -fsS --max-time 20 --config "$REG_WORK/github" -X POST \
             -H "Accept: application/vnd.github+json" --data "$body" \
             "https://api.github.com/repos/${watch.repository}/actions/workflows/apps-bump.yml/dispatches"; then
          echo "$app : nouvelle version, épinglage demandé"
        else
          echo "$app : épinglage refusé par GitHub (jeton ${watch.tokenKey} expiré ?) ; rattrapage : dots update apps" >&2
          status=1
        fi
      done

      exit "$status"
    '';
  };
in
{
  options.systemSettings.appImages.watch = {
    enable = lib.mkEnableOption "surveillance des tags par think, qui demande l'épinglage des nouvelles images";

    repository = lib.mkOption {
      type = lib.types.str;
      default = "Nchpg/.dotfiles";
      description = "Dépôt qui porte le lock et apps-bump.yml.";
    };

    tokenKey = lib.mkOption {
      type = lib.types.str;
      default = "github/dispatch_token";
      description = ''
        Clé sops d'un PAT fine-grained limité à `repository`, permission
        « Actions: Read and write » seule : il ne fait que lancer apps-bump.yml.
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
