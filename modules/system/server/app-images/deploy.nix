{
  config,
  lib,
  pkgs-stable,
  target,
  ...
}:

# Déploie seul les changements de sites, et rien d'autre. Toutes les minutes, think regarde la
# branche suivie : si les nouveaux commits ne touchent qu'apps.json et le lock des images ET
# partent de la version qui tourne, il les active. Sinon il ne touche à rien et prévient sur
# Discord : le reste se déploie par un `rebuild` à la main. Une version locale (non commitée, ou
# commits pas encore poussés) n'est donc jamais écrasée.
#
# Il tient aussi `status.json` à jour pour le dashboard : versions, décision, état du clone local.
let
  cfg = config.systemSettings.appImages;
  deploy = cfg.deploy;
  notify = config.systemSettings.notify.discord;

  # Les seuls fichiers qu'un commit peut toucher pour partir seul.
  sitePaths = [
    "profiles/server/apps.json"
    "profiles/server/apps.lock.json"
  ];

  script = pkgs-stable.writeShellApplication {
    name = "apps-deploy";
    runtimeInputs = [
      config.system.build.nixos-rebuild
      config.nix.package
      pkgs-stable.git
      pkgs-stable.curl
      pkgs-stable.jq
      pkgs-stable.coreutils
      pkgs-stable.util-linux
      pkgs-stable.getent
    ];
    text = ''
      repo=${lib.escapeShellArg deploy.repository}
      branch=${lib.escapeShellArg deploy.branch}
      checkout=${lib.escapeShellArg (toString deploy.checkout)}
      state="$STATE_DIRECTORY"

      umask 077
      conf=$(mktemp)
      # URL via un fichier de config curl, pas argv (lisible par tous).
      printf 'url = "%s"\n' "$(cat "$CREDENTIALS_DIRECTORY/webhook")" > "$conf"

      head=""
      deployed=""
      decision="inconnu"

      say() {
        jq -n --arg c "$1" '{content: $c, flags: 4}' \
          | curl --silent --show-error --max-time 20 --config "$conf" \
              --header 'Content-Type: application/json' --data @- > /dev/null \
          || echo "envoi Discord en échec" >&2
      }

      # Git au nom du propriétaire du clone ; hooks coupés : ceux du dépôt attendent une session
      # (commande `secrets`), pas un service.
      as_owner() {
        local owner
        owner=$(stat -c %U "$checkout")
        runuser -u "$owner" -- env HOME="$(getent passwd "$owner" | cut -d: -f6)" \
          git -C "$checkout" -c core.hooksPath=/dev/null "$@"
      }

      # Décision retenue pour un commit de tête : `seen` ne la fait prendre qu'une fois.
      decide() {
        decision=$1
        jq -n --arg head "$head" --arg state "$1" --argjson pending "''${2:-[]}" \
          '{$head, $state, $pending}' > "$state/decision.json"
      }

      # Lu par le dashboard (lisible par tous, sans secret) : refait à chaque passage.
      publish() {
        local clone=null raw
        # Copie locale de main à jour d'abord : sans elle, un push fait depuis une autre machine
        # compterait encore comme des commits « pas poussés ».
        if [ -n "$checkout" ] && [ -d "$checkout/.git" ] && [ -n "$head" ] \
          && [ "$(as_owner rev-parse --quiet --verify "refs/remotes/origin/$branch" 2> /dev/null || true)" != "$head" ]; then
          as_owner fetch --quiet "https://github.com/$repo.git" "+refs/heads/$branch:refs/remotes/origin/$branch" 2> /dev/null || true
        fi
        if [ -n "$checkout" ] && [ -d "$checkout/.git" ] \
          && raw=$(as_owner status --porcelain=v2 --branch 2> /dev/null); then
          clone=$(jq -Rn '[inputs] as $l | {
            branch: ($l | map(select(startswith("# branch.head "))) | first // "" | ltrimstr("# branch.head ")),
            modified: ($l | map(select(test("^[12u] "))) | length),
            untracked: ($l | map(select(startswith("? "))) | length),
            ahead: ($l | map(select(startswith("# branch.ab "))) | first // "" | capture("\\+(?<a>[0-9]+)").a // null | if . then tonumber else null end),
            behind: ($l | map(select(startswith("# branch.ab "))) | first // "" | capture("-(?<b>[0-9]+)").b // null | if . then tonumber else null end)
          }' <<< "$raw")
        fi
        local pending=[]
        if [ -f "$state/decision.json" ] && [ "$(jq -r .head "$state/decision.json")" = "$head" ]; then
          pending=$(jq -c .pending "$state/decision.json")
        fi
        jq -n --arg head "$head" --arg deployed "$deployed" --arg state "$decision" \
          --argjson pending "$pending" --argjson checkout "$clone" --argjson checked "$(date +%s)" \
          '{$checked, $head, $deployed, $state, $pending, $checkout}' > "$state/status.json.new"
        chmod 644 "$state/status.json.new"
        mv -f "$state/status.json.new" "$state/status.json"
      }

      trap 'publish || true; rm -f "$conf" "$conf.compare"' EXIT

      # Avance le clone local jusqu'au commit déployé, sans toucher aux changements en cours :
      # `merge --ff-only` refuse s'ils portent sur ces fichiers ou si le clone a ses propres
      # commits. Dans ce cas, le prochain `rebuild` proposera de récupérer les changements.
      sync_checkout() {
        [ -d "$checkout/.git" ] || return 0
        local local_branch out
        local_branch=$(as_owner symbolic-ref --quiet --short HEAD || true)
        if [ "$local_branch" != "$branch" ]; then
          say "ℹ️ sites déployés, mais \`$checkout\` est sur \`''${local_branch:-HEAD détachée}\` : changements pas récupérés dans le dossier."
          return 0
        fi
        if ! out=$(as_owner fetch --quiet "https://github.com/$repo.git" "+refs/heads/$branch:refs/remotes/origin/$branch" 2>&1) \
          || ! out=$(as_owner merge --ff-only --quiet "$head" 2>&1); then
          say "⚠️ sites déployés, mais \`$checkout\` n'a pas pu avancer jusqu'à \`''${head:0:7}\` (commits locaux, ou apps.json ou le lock modifiés à la main). Le prochain \`rebuild\` proposera de les récupérer.
      \`\`\`
      $(head -n 5 <<< "$out")
      \`\`\`"
        fi
      }

      deployed=$(/run/current-system/sw/bin/nixos-version --configuration-revision 2> /dev/null || true)

      # Réseau ou GitHub indisponible : nouvel essai à la minute suivante, sans bruit.
      head=$(git ls-remote "https://github.com/$repo.git" "refs/heads/$branch" | cut -f1) || exit 0
      [ -n "$head" ] || exit 0

      if [ "$head" = "$deployed" ]; then
        decision="a_jour"
        exit 0
      fi

      # Un seul traitement par commit de tête : déployé, refusé ou signalé.
      if [ "$(cat "$state/seen" 2> /dev/null || true)" = "$head" ]; then
        decision=$(jq -r '.state // "inconnu"' "$state/decision.json" 2> /dev/null || echo inconnu)
        exit 0
      fi
      echo "$head" > "$state/seen"

      short=''${head:0:7}
      case "$deployed" in
        "" | *-dirty)
          decide local
          say "⏸️ think tourne une version locale non commitée : \`$short\` sur $branch n'est pas déployé. \`rebuild\` à la main pour l'appliquer."
          exit 0
          ;;
      esac

      code=$(curl -sS --max-time 20 -o "$conf.compare" -w '%{http_code}' \
        "https://api.github.com/repos/$repo/compare/$deployed...$head" || true)
      case "$code" in
        200) compare=$(cat "$conf.compare") ;;
        404)
          decide non_pousse
          say "⏸️ la version de think (\`''${deployed:0:7}\`) est inconnue de GitHub (commits pas encore poussés ?) : \`$short\` n'est pas déployé. \`rebuild\` à la main."
          exit 0
          ;;
        *)
          # Quota, panne ou réseau : rien n'est tranché pour ce commit, nouvel essai à la minute suivante.
          echo "API GitHub en échec (''${code:-réseau}), nouvel essai" >&2
          rm -f "$state/seen"
          exit 0
          ;;
      esac

      pending=$(jq -c '[.commits[] | {sha, subject: (.commit.message | split("\n")[0])}]' <<< "$compare")

      if [ "$(jq -r .status <<< "$compare")" != ahead ]; then
        decide diverge "$pending"
        say "⏸️ $branch (\`$short\`) n'est pas dans la lignée de la version de think (\`''${deployed:0:7}\`) : rien n'est déployé. \`rebuild\` à la main."
        exit 0
      fi

      if ! jq -e --argjson ok ${lib.escapeShellArg (builtins.toJSON sitePaths)} \
        '[.files[].filename] - $ok | length == 0' <<< "$compare" > /dev/null; then
        decide attente "$pending"
        commits=$(jq -r '.[] | "• `\(.sha[0:7])` \(.subject)"' <<< "$pending")
        say "📦 nouveaux commits sur $branch, pas que des sites : \`rebuild\` à la main pour les appliquer.
      $commits"
        exit 0
      fi

      # Que des changements de sites : on active exactement ce commit (apps-announce suit).
      decide deploiement "$pending"
      publish
      echo "changements de sites : ''${deployed:0:7} → $short"
      if ! nixos-rebuild switch --flake "github:$repo/$head#${target.name}"; then
        decide echec "$pending"
        exit 1
      fi
      deployed=$head
      decide a_jour
      [ -z "$checkout" ] || sync_checkout
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
      description = "Branche suivie, celle où apps.yml commite.";
    };

    checkout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/nchpg/.dotfiles";
      description = ''
        Clone local du dépôt sur ce serveur, avancé jusqu'aux changements de sites déployés (avance rapide
        seulement, au nom de son propriétaire, changements non commités conservés). Sans lui, le
        dossier reste en retard et le prochain `rebuild` le signale.
      '';
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
        # status.json est lu par le dashboard, sous un autre utilisateur.
        StateDirectoryMode = "0755";
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
