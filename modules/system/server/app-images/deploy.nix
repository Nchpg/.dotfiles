{
  config,
  lib,
  pkgs-stable,
  target,
  ...
}:

# Déploie seul les mises à jour de sites, et rien d'autre. Toutes les minutes, think regarde la
# branche suivie : si les nouveaux commits ne touchent que le lock des images ET partent de la
# version qui tourne, il les active. Sinon il ne touche à rien et prévient sur Discord : le reste
# se déploie par un `rebuild` à la main. Une version locale (non commitée, ou commits pas encore
# poussés) n'est donc jamais écrasée.
let
  cfg = config.systemSettings.appImages;
  deploy = cfg.deploy;
  notify = config.systemSettings.notify.discord;

  lockPath = "profiles/server/apps.lock.json";

  script = pkgs-stable.writeShellApplication {
    name = "apps-deploy";
    runtimeInputs = [
      config.system.build.nixos-rebuild
      config.nix.package
      pkgs-stable.git
      pkgs-stable.curl
      pkgs-stable.jq
      pkgs-stable.coreutils
    ];
    text = ''
      repo=${lib.escapeShellArg deploy.repository}
      branch=${lib.escapeShellArg deploy.branch}
      state="$STATE_DIRECTORY"

      umask 077
      conf=$(mktemp)
      trap 'rm -f "$conf"' EXIT
      # URL via un fichier de config curl, pas argv (lisible par tous).
      printf 'url = "%s"\n' "$(cat "$CREDENTIALS_DIRECTORY/webhook")" > "$conf"

      say() {
        jq -n --arg c "$1" '{content: $c, flags: 4}' \
          | curl --silent --show-error --max-time 20 --config "$conf" \
              --header 'Content-Type: application/json' --data @- > /dev/null \
          || echo "envoi Discord en échec" >&2
      }

      # Réseau ou GitHub indisponible : nouvel essai à la minute suivante, sans bruit.
      head=$(git ls-remote "https://github.com/$repo.git" "refs/heads/$branch" | cut -f1) || exit 0
      [ -n "$head" ] || exit 0

      deployed=$(/run/current-system/sw/bin/nixos-version --configuration-revision 2> /dev/null || true)
      [ "$head" = "$deployed" ] && exit 0

      # Un seul traitement par commit de tête : déployé, refusé ou signalé.
      [ "$(cat "$state/seen" 2> /dev/null || true)" = "$head" ] && exit 0
      echo "$head" > "$state/seen"

      short=''${head:0:7}
      case "$deployed" in
        "" | *-dirty)
          say "⏸️ think tourne une version locale non commitée : \`$short\` sur $branch n'est pas déployé. \`rebuild\` à la main pour l'appliquer."
          exit 0
          ;;
      esac

      if ! compare=$(curl -fsS --max-time 20 "https://api.github.com/repos/$repo/compare/$deployed...$head"); then
        say "⏸️ la version de think (\`''${deployed:0:7}\`) est inconnue de GitHub (commits pas encore poussés ?) : \`$short\` n'est pas déployé. \`rebuild\` à la main."
        exit 0
      fi

      status=$(jq -r .status <<< "$compare")
      if [ "$status" != ahead ]; then
        say "⏸️ $branch (\`$short\`) n'est pas dans la lignée de la version de think (\`''${deployed:0:7}\`, $status) : rien n'est déployé. \`rebuild\` à la main."
        exit 0
      fi

      files=$(jq -r '[.files[].filename] | unique | join(" ")' <<< "$compare")
      if [ "$files" != ${lib.escapeShellArg lockPath} ]; then
        commits=$(jq -r '.commits[] | "• `\(.sha[0:7])` \(.commit.message | split("\n")[0])"' <<< "$compare")
        say "📦 nouveaux commits sur $branch, pas que des sites : \`rebuild\` à la main pour les appliquer.
      $commits"
        exit 0
      fi

      # Que des mises à jour de sites : on active exactement ce commit (apps-announce suit).
      echo "mise à jour des sites : ''${deployed:0:7} → $short"
      nixos-rebuild switch --flake "github:$repo/$head#${target.name}"
    '';
  };
in
{
  options.systemSettings.appImages.deploy = {
    enable = lib.mkEnableOption "déploiement automatique des seules mises à jour de sites";

    repository = lib.mkOption {
      type = lib.types.str;
      default = "Nchpg/.dotfiles";
      description = "Dépôt GitHub suivi (public : lu sans jeton).";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branche suivie, celle où apps-bump.yml commite.";
    };
  };

  config = lib.mkIf deploy.enable {
    assertions = [
      {
        assertion = notify.enable;
        message = "systemSettings.appImages.deploy prévient sur le webhook de systemSettings.notify.discord : active-le.";
      }
    ];

    # Root : il active une nouvelle génération. Un échec de build signale l'unité (notify).
    systemd.services.apps-deploy = {
      description = "Déploie les mises à jour de sites poussées sur ${deploy.branch}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Il remplace la génération courante : pas de redémarrage de l'unité par son propre switch.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe script;
        StateDirectory = "apps-deploy";
        LoadCredential = "webhook:${config.sops.secrets.${notify.webhookKey}.path}";
      };
    };

    systemd.timers.apps-deploy = {
      description = "Surveillance de ${deploy.branch} pour les mises à jour de sites";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "1min";
      };
    };

    systemSettings.notify.discord.units = [ "apps-deploy" ];
  };
}
