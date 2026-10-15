{
  config,
  lib,
  myLib,
  ...
}:

# Nextcloud vu par lui-même — comptes, partages, fichiers, stockage — par son
# API `serverinfo`. Demande un jeton créé à la main, cf.
# `apps.nextcloudTokenKey`.
let
  cfg = config.systemSettings.monitoring;
  nextcloud = config.systemSettings.nextcloud;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;
in
{
  # Comme les autres exporteurs applicatifs : `apps` ET le service observé, en
  # plus du jeton. Sans Nextcloud, l'exporteur collecterait en échec permanent.
  config =
    lib.mkIf (cfg.enable && cfg.apps.enable && nextcloud.enable && cfg.apps.nextcloudTokenKey != null)
      {
        services.prometheus.exporters.nextcloud = helpers.mkLocalExporter ports.nextcloudExporter // {
          # LE PREMIER NOM SUPPLÉMENTAIRE, jamais `hostName` : le nom public passe
          # par le portail sans exception, l'exporteur y récolte la page de connexion
          # d'Authelia et échoue sur « invalid character '<' » — du HTML là où il
          # attend du JSON. C'est sous le nom interne que vit le contournement, cf.
          # la règle `serverinfo` du profil (et l'assertion de default.nix).
          url = "https://${lib.head nextcloud.extraHostNames}";
          tokenFile = config.sops.secrets.${cfg.apps.nextcloudTokenKey}.path;
        };

        # `restartUnits` : l'exporteur lit le fichier une fois, au démarrage.
        sops.secrets.${cfg.apps.nextcloudTokenKey} = {
          mode = "0400";
          # 0400 n'a de sens qu'avec un propriétaire : par défaut le secret
          # appartient à root, et l'exporteur — qui tourne sous son propre compte —
          # se voit refuser la lecture.
          #
          # Possible ICI et pas pour alertmanager (cf. `LoadCredential` dans
          # alertmanager.nix) : le module amont de l'exporteur Nextcloud déclare un
          # utilisateur STATIQUE, donc un nom qu'un `owner` sops peut désigner.
          owner = "nextcloud-exporter";
          restartUnits = [ "prometheus-nextcloud-exporter.service" ];
        };

        systemSettings.monitoring.internal = {
          # L'exporteur interroge l'API `serverinfo`, qui recompte les fichiers :
          # c'est une opération LOURDE côté instance, à ne pas déclencher toutes les
          # trente secondes.
          scrapeJobs.nextcloud = helpers.localJob "nextcloud" ports.nextcloudExporter // {
            scrape_interval = "5m";
            scrape_timeout = "1m";
          };

          # `nextcloud_up` tombe à 0 dès que l'API refuse l'exporteur : un jeton
          # devenu faux, ou le contournement Authelia qui a cessé de correspondre
          # parce que l'application a déplacé son URL. Aucune des deux ne coupe le
          # service, donc rien d'autre ne le dirait — les panneaux se videraient en
          # silence, ce qui ressemble à une instance au repos.
          alertRules.MetriquesNextcloudAveugles = {
            alert = "MetriquesNextcloudAveugles";
            expr = "nextcloud_up == 0";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "L'exporteur Nextcloud n'obtient plus rien de l'API serverinfo : jeton invalide, ou chemin non contourné dans Authelia.";
          };

          # PAS de panneau « mises à jour en attente » :
          # `nextcloud_apps_updates_available_total` et
          # `nextcloud_system_update_available` existent dans le binaire de
          # l'exporteur mais ne sortent PAS ici — l'API ne renvoie cette section que
          # si l'application `updatenotification` la remplit. Un panneau sur ces
          # noms resterait vide, ce qui ressemble à « rien à mettre à jour » alors
          # que ça veut dire « je ne sais pas ».
          #
          # QUATRE PANNEAUX ET NON UN : l'unité est une propriété du PANNEAU, et
          # deux mesures d'ordres de grandeur trop différents font deux panneaux —
          # jamais un second axe, qui inventerait une corrélation entre elles.
          panels = {
            nextcloudComptes = mkTs {
              id = 28;
              title = "Nextcloud : comptes et partages";
              unit = "short";
              description = "Les partages sont ventilés par type plutôt que sommés : `link` est un partage PUBLIC, exposé à quiconque détient l'URL, là où `user` et `group` restent internes.";
              decimals = 0;
              targets = [
                {
                  expr = "nextcloud_users_total";
                  legend = "comptes";
                }
                {
                  expr = "nextcloud_active_users_daily_total";
                  legend = "actifs sur 24 h";
                }
                {
                  # VENTILÉ par `type`, une série par mécanisme de partage : sans le
                  # label dans la légende, Grafana affiche six fois « partages ».
                  expr = "nextcloud_shares_total";
                  legend = "partages {{ type }}";
                }
              ];
            };

            # À part des comptes : ~14 000 fichiers à côté de 5 comptes et 0
            # partage écraseraient les trois autres séries contre l'axe.
            nextcloudFichiers = mkTs {
              id = 33;
              title = "Nextcloud : fichiers";
              unit = "short";
              description = "Sa PENTE est ce qui compte : c'est le producteur d'inodes de la machine, à rapprocher du panneau « Inodes libres » de la section Stockage.";
              decimals = 0;
              targets = [
                {
                  expr = "nextcloud_files_total";
                  legend = "fichiers";
                }
              ];
            };

            # `bytes` comme les autres panneaux de volume du tableau : Grafana y rend
            # des multiples binaires (Kio, Mio, Gio), cohérent avec ce que
            # rapportent le noyau et `df`.
            nextcloudStockage = mkTs {
              id = 29;
              title = "Nextcloud : stockage";
              unit = "bytes";
              description = "Espace libre vu par l'instance elle-même, qui est celui de la racine : ce panneau et « Espace disque libre » décrivent le même disque par deux chemins différents.";
              targets = [
                {
                  expr = "nextcloud_free_space_bytes";
                  legend = "espace libre";
                }
              ];
            };

            # MÊME UNITÉ QUE LE PANNEAU VOISIN, ET POURTANT À PART : la base est
            # quelques milliers de fois plus petite que l'espace libre, et sa
            # croissance — la seule chose qu'on vient regarder — y serait invisible.
            nextcloudBase = mkTs {
              id = 34;
              title = "Nextcloud : base de données";
              unit = "bytes";
              description = "À part du panneau voisin bien qu'en octets comme lui : trois mille fois plus petit, il y serait une ligne collée à l'axe. C'est sa croissance qu'on vient voir.";
              targets = [
                {
                  expr = "nextcloud_database_size_bytes";
                  legend = "base de données";
                }
              ];
            };
          };
        };
      };
}
