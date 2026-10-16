{
  config,
  lib,
  pkgs-stable,
  ...
}:

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

            # Webhook via les credentials systemd, pas l'environnement (lisible dans /proc).
            webhook=$(cat "$CREDENTIALS_DIRECTORY/webhook")

            # `systemctl show` rend Result=success pour une unité inconnue : tester LoadState.
            load=$(systemctl show -p LoadState --value "$unit" 2> /dev/null || echo inconnu)

            if [ "$load" = "loaded" ]; then
              result=$(systemctl show -p Result --value "$unit" 2> /dev/null || echo inconnu)
              code=$(systemctl show -p ExecMainStatus --value "$unit" 2> /dev/null || echo "?")
            else
              result="unite introuvable (LoadState=$load)"
              code="-"
            fi

            # Course OnFailure=/Restart= : on décrit l'état au moment de l'envoi.
            etat=""
            if [ "$load" = "loaded" ]; then
              active=$(systemctl show -p ActiveState --value "$unit" 2> /dev/null || echo inconnu)
              restarts=$(systemctl show -p NRestarts --value "$unit" 2> /dev/null || echo "?")

              if [ "$active" = "active" ]; then
                etat="

      ✅ l'unité est **repartie toute seule** depuis (redémarrages : \`$restarts\`). L'échec a bien eu lieu, mais il n'a pas duré."
              else
                etat="

      état actuel : \`$active\` (redémarrages : \`$restarts\`)"
              fi
            fi

            umask 077
            conf=$(mktemp)
            body=$(mktemp)
            trap 'rm -f "$conf" "$body"' EXIT

            # URL via un fichier de config curl, pas argv (lisible par tous).
            printf 'url = "%s"\n' "$webhook" > "$conf"

            # SC2016 : `\($host)` est de l'interpolation jq.
            # shellcheck disable=SC2016
            jq -n \
              --arg host "$(uname -n)" \
              --arg unit "$unit" \
              --arg result "$result" \
              --arg code "$code" \
              --arg etat "$etat" \
              '{ content: "⚠️ **\($host)** : unité `\($unit)` en échec.\nrésultat : `\($result)`, code de sortie : `\($code)`\($etat)\n\n`journalctl -u \($unit) -n 50 --no-pager`" }' \
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
        Clé sops de l'URL du webhook (brute, secrets système).
      '';
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vaultwarden" ];
      description = ''
        Services systemd (sans `.service`) dont l'échec est signalé.
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
        Fragment à fusionner dans une unité pour signaler son échec :

        ```nix
        systemd.services.mon-service = config.systemSettings.notify.discord.onFailure;
        ```

        `%n` devient l'instance du gabarit ; `%i` serait vide ici.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      { systemd.services = lib.genAttrs cfg.units (_: cfg.onFailure); }
      {
        sops.secrets.${cfg.webhookKey} = {
          mode = "0400";
        };

        # Pas d'onFailure ici : une notification qui échoue boucle sur elle-même.
        systemd.services."notify-failure@" = {
          description = "Signale sur Discord l'échec de %i";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe notifier} %i";

            LoadCredential = "webhook:${config.sops.secrets.${cfg.webhookKey}.path}";

            DynamicUser = true;
            NoNewPrivileges = true;
            ProtectHome = true;
            PrivateDevices = true;
            # AF_UNIX : glibc interroge resolved et le journal par socket unix.
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
          };
        };
      }
    ]
  );
}
