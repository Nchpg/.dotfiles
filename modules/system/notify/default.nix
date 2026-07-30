{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Signale sur Discord l'échec d'une unité systemd.
#
# Raison d'être : sur une machine sans écran, une unité qui échoue en boucle ne
# se voit nulle part. `systemctl --failed` le dirait, mais personne ne le tape,
# et les timers réessaient chaque nuit sans un mot. Le cas qui a motivé ce
# module est le renouvellement ACME : lego réessaie tous les jours pendant les
# trente jours qui précèdent l'expiration, donc une panne durable ne se découvre
# qu'au moment où les navigateurs refusent la connexion. Les avis d'expiration
# de Let's Encrypt, qui servaient de filet, ont cessé le 4 juin 2025.
#
# Ce module ne surveille RIEN de lui-même : il fournit un fragment
# (`systemSettings.notify.discord.onFailure`) que les modules fusionnent dans
# les unités qu'ils veulent voir signalées. Même parti pris que
# `systemSettings.authelia.nginxAuthRequest` — la mécanique vit ici, la décision
# de l'appliquer reste chez celui qui connaît l'unité.
let
  cfg = config.systemSettings.notify.discord;

  notifier = pkgs-stable.writeShellApplication {
    name = "notify-failure";
    runtimeInputs = with pkgs-stable; [
      curl
      jq
      systemd
      coreutils
    ];
    text = ''
      unit=''${1:-}
      [ -n "$unit" ] || { echo "notify-failure : unite manquante" >&2; exit 1; }

      # Le webhook arrive par les credentials systemd, jamais par
      # l'environnement : /proc/<pid>/environ se lit, et une URL de webhook
      # laisse ecrire dans le salon a qui la detient.
      webhook=$(cat "$CREDENTIALS_DIRECTORY/webhook")

      # `systemctl show` ne distingue pas « cette unite va bien » de « cette
      # unite n'existe pas » : sur un nom inconnu il rend les valeurs par
      # defaut, Result=success et ExecMainStatus=0. Une alerte qui annonce
      # « success » est precisement ce qui apprend a ne plus les lire, donc on
      # interroge d'abord LoadState et on le dit quand il n'est pas `loaded`.
      # Constate au premier test de fumee, sur `notify-failure@test.service`.
      load=$(systemctl show -p LoadState --value "$unit" 2> /dev/null || echo inconnu)

      if [ "$load" = "loaded" ]; then
        result=$(systemctl show -p Result --value "$unit" 2> /dev/null || echo inconnu)
        code=$(systemctl show -p ExecMainStatus --value "$unit" 2> /dev/null || echo "?")
      else
        result="unite introuvable (LoadState=$load)"
        code="-"
      fi

      umask 077
      conf=$(mktemp)
      body=$(mktemp)
      trap 'rm -f "$conf" "$body"' EXIT

      # L'URL passe par un fichier de configuration curl et non par argv : la
      # ligne de commande d'un processus est lisible par tous les utilisateurs
      # de la machine le temps que la requete dure.
      printf 'url = "%s"\n' "$webhook" > "$conf"

      # AUCUN extrait de journal dans le message, a dessein. Discord est un
      # tiers, et le journal d'une unite qui manipule des secrets peut en
      # recracher un bout dans une trace d'erreur. Le nom, la cause et le code
      # suffisent a savoir qu'il faut aller regarder ; la commande pour le faire
      # est jointe.
      #
      # LA DIRECTIVE CI-DESSOUS N'EST PAS COSMETIQUE. `\($host)` est de
      # l'interpolation jq, pas du shell, donc les apostrophes simples sont
      # exactement ce qu'il faut ; shellcheck y voit un `$` non expanse et leve
      # SC2016. Et un avertissement sur cette ligne-la suffit a tuer la
      # construction : shellcheck tourne dans un bac a sable en locale C, il
      # meurt en tentant de reafficher une ligne qui porte un accent ou un
      # emoji (« commitBuffer: invalid argument »), sur un message qui ne parle
      # pas du vrai probleme. Constate.
      # shellcheck disable=SC2016
      jq -n \
        --arg host "$(uname -n)" \
        --arg unit "$unit" \
        --arg result "$result" \
        --arg code "$code" \
        '{ content: "⚠️ **\($host)** : unité `\($unit)` en échec.\nrésultat : `\($result)`, code de sortie : `\($code)`\n\n`journalctl -u \($unit) -n 50 --no-pager`" }' \
        > "$body"

      curl --silent --show-error --max-time 20 \
        --config "$conf" \
        --header 'Content-Type: application/json' \
        --data "@$body" > /dev/null
    '';
  };
in
{
  options.systemSettings.notify.discord = {
    enable = lib.mkEnableOption "signalement des échecs d'unités systemd sur Discord";

    webhookKey = lib.mkOption {
      type = lib.types.str;
      default = "discord/webhook";
      description = ''
        Clé sops de l'URL du webhook, dans les secrets SYSTÈME : l'unité qui la
        lit tourne en root, elle ne peut donc pas la prendre dans
        `/run/user/<uid>`. Contenu brut, l'URL complète que Discord donne.

        C'est un identifiant à part entière : qui la détient peut écrire dans le
        salon. Elle n'a rien à faire dans le dépôt public.
      '';
    };

    onFailure = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = {
        onFailure = [ "notify-failure@%n.service" ];
      };
      defaultText = lib.literalExpression ''{ onFailure = [ "notify-failure@%n.service" ]; }'';
      description = ''
        Fragment à fusionner dans une unité pour que son échec soit signalé :

        ```nix
        systemd.services.mon-service = config.systemSettings.notify.discord.onFailure;
        ```

        `%n` est le nom COMPLET de l'unité défaillante, suffixe `.service`
        compris, et c'est lui qui devient l'instance du gabarit. Ne pas le
        remplacer par `%i`, qui désigne l'instance de l'unité qui DÉCLARE la
        dépendance — donc une chaîne vide pour une unité ordinaire, et un
        gabarit instancié sur rien.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.${cfg.webhookKey} = {
      mode = "0400";
    };

    # Gabarit : une instance par unité défaillante, `%i` portant son nom.
    #
    # PAS de `onFailure` sur celle-ci, et ce n'est pas un oubli : une
    # notification qui échoue déclencherait sa propre notification, laquelle
    # échouerait pour la même raison. Un réseau coupé suffirait à lancer la
    # boucle.
    systemd.services."notify-failure@" = {
      description = "Signale sur Discord l'échec de %i";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe notifier} %i";

        # Lu par systemd en root AVANT l'abaissement de privilèges, puis exposé
        # dans $CREDENTIALS_DIRECTORY en lecture seule pour ce service seul.
        LoadCredential = "webhook:${config.sops.secrets.${cfg.webhookKey}.path}";

        # Compte jetable : ce service n'a besoin d'aucune identité persistante,
        # et rien de ce qu'il touche ne lui survit.
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectHome = true;
        PrivateDevices = true;
        # `AF_UNIX` n'est PAS décoratif malgré les apparences : c'est par une
        # socket unix que glibc interroge systemd-resolved et que le service
        # écrit au journal. Sans lui, la résolution de discord.com échoue et
        # l'erreur elle-même se perd, ce qui donne une notification muette qui
        # échoue en silence — exactement ce que ce module existe pour éviter.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
