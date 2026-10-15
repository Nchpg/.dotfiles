{ lib, ... }:

# Options INTERNES du module de surveillance : le contrat entre les fichiers de
# ce dossier, pas une interface pour les profils.
#
# POURQUOI DES OPTIONS et non un gros `let` : sous modules/, chaque .nix est un
# module à part entière (cf. lib/modules/import-all.nix), donc deux fichiers ne
# partagent rien d'autre que `config`. Chaque composant (components/*.nix)
# DÉPOSE ici ses tâches de collecte, ses règles et ses panneaux ; prometheus.nix,
# loki.nix et dashboard.nix les RAMASSENT et les mettent en ordre.
#
# L'ORDRE vit chez le ramasseur, pas chez le composant : les entrées sont
# nommées (attrsOf), et une liste de noms fixe leur place dans le fichier
# produit. Une entrée déclarée mais absente de ces listes fait échouer
# l'évaluation — sans ça, elle disparaîtrait sans un mot, ce qui est
# exactement la panne que ce module passe son temps à traquer.
let
  internalOpt =
    args:
    lib.mkOption (
      {
        internal = true;
        type = lib.types.attrsOf lib.types.raw;
        default = { };
      }
      // args
    );
in
{
  options.systemSettings.monitoring.internal = {
    # Ports de BOUCLAGE, détails d'implémentation : rien ici n'est joignable de
    # l'extérieur, donc aucune de ces valeurs n'est une adresse à communiquer.
    # Constantes plutôt qu'options publiques, contrairement à `authelia.port` :
    # aucun autre module n'a de raison de les reprendre.
    ports = internalOpt {
      readOnly = true;
      type = lib.types.attrsOf lib.types.port;
      default = {
        prometheus = 9090;
        alertmanager = 9093;
        node = 9100;
        blackbox = 9115;
        grafana = 3000;
        smartctl = 9633;

        # Journaux. HORS des 9000 contrairement au reste du bloc, et c'est
        # délibéré : 3100 est le port par défaut de Loki, celui que toute la
        # documentation emploie. S'en écarter ferait gagner une cohérence
        # interne au prix d'une divergence avec tout ce qu'on lira ailleurs le
        # jour où quelque chose ne marchera pas.
        #
        # Le port gRPC ne sert à RIEN dans ce montage — il n'existe que pour la
        # communication entre composants d'un Loki distribué, et celui-ci tourne
        # en binaire unique. Loki l'ouvre quand même, on le fixe donc pour qu'il
        # soit sur la boucle locale et pas sur un port choisi au hasard.
        loki = 3100;
        lokiGrpc = 9096;

        # Exporteurs applicatifs. `nginxStatus` n'est PAS un exporteur mais le
        # `stub_status` de nginx lui-même : il lui faut un socket à lui, sur la
        # boucle locale, et surtout pas `services.nginx.statusPage`, qui écoute
        # sur 0.0.0.0:80 et pose un vhost `localhost`. Aucun vhost de cette
        # machine n'étant marqué `default`, en ajouter un sur le port 80
        # déplacerait le serveur par défaut de nginx — c'est-à-dire changerait
        # qui répond aux requêtes dont l'en-tête `Host` ne correspond à rien, ce
        # sur quoi repose le 404 neutre des partages Nextcloud.
        #
        # DANS LES 9000, comme tout ce bloc, et surtout pas dans les 8000 : les
        # applications de `systemSettings.apps` s'y servent, et rien ne fait
        # échouer le build en cas de collision — nginx démarrerait simplement en
        # « Address already in use », après déploiement, emportant tous les
        # vhosts avec lui.
        nginxStatus = 9114;
        nginx = 9113;
        phpfpm = 9253;
        wireguardExporter = 9586;
        autheliaMetrics = 9959;
        nextcloudExporter = 9205;

        # Ports PAR DÉFAUT de chacun de ces exporteurs, repris tels quels.
        #
        # `vector` est le seul qui ne vienne pas d'un module NixOS : Vector
        # n'expose rien par défaut, c'est un puits `prometheus_exporter` (cf.
        # vector.nix) qui ouvre ce port, et 9598 est la valeur que Vector emploie
        # lui-même.
        postgres = 9187;
        redis = 9121;
        dnsmasq = 9153;
        vector = 9598;
      };
    };

    # Fonctions partagées entre les composants.
    helpers = internalOpt {
      readOnly = true;
      default = rec {
        # SOCLE COMMUN DES EXPORTEURS. La deuxième ligne n'est pas un détail de
        # confort : c'est elle qui décide que rien de tout ça n'est joignable
        # depuis le réseau. Recopiée à chaque exporteur, elle est à la merci du
        # suivant ajouté sans elle — et l'oubli ne casse rien, il OUVRE, ce qui
        # ne se voit jamais dans un rebuild réussi.
        #
        # Prometheus et Alertmanager restent explicites, eux : ce ne sont pas
        # des exporteurs, et le commentaire qui justifie leur écoute locale se
        # lit mieux à côté de la ligne concernée.
        mkLocalExporter = port: {
          enable = true;
          listenAddress = "127.0.0.1";
          inherit port;
        };

        # Cible de collecte sur la boucle locale. Le `job_name` reste écrit à
        # côté de chaque appel : c'est lui qui porte le sens, et c'est le nom
        # qu'on lira dans une alerte.
        localTarget = port: [ { targets = [ "127.0.0.1:${toString port}" ]; } ];

        # Tâche de collecte locale complète, pour le cas courant.
        localJob = job_name: port: {
          inherit job_name;
          static_configs = localTarget port;
        };

        # SUFFIXE `_total` POSÉ À LA COLLECTE, sur des compteurs que leur
        # exporteur publie sans lui.
        #
        # LE PROBLÈME : ce sont bien des compteurs — ils ne font que croître —,
        # mais leur nom ignore la convention Prometheus. Toute requête `rate()`
        # ou `increase()` dessus fait alors écrire à Grafana, à chaque ouverture
        # du tableau :
        #
        #   metric might not be a counter, name does not end in
        #   _total/_sum/_count/_bucket
        #
        # Corrigé plutôt que toléré : un avertissement qu'on apprend à ignorer
        # est un avertissement qui masquera le suivant.
        #
        # LE PIÈGE que ce helper écrit une fois pour toutes : `${"$"}{1}` et non
        # `$1`, Prometheus employant l'expansion Go où `$1_total` désigne un
        # groupe nommé `1_total`, inexistant, donc remplacé par du vide.
        #
        # NE PRENDRE QUE DES COMPTEURS, vérifiés un par un : le type déclaré par
        # l'exporteur ne suffit pas à trancher. L'exporteur dnsmasq annonce
        # TOUTES ses métriques en `gauge`, y compris `hits` et `misses` qui sont
        # cumulatifs — relevé en les mesurant deux fois à douze secondes
        # d'intervalle. À l'inverse, `dnsmasq_cachesize` est une vraie jauge et
        # n'a rien à faire ici : la renommer casserait l'alerte
        # `MetriquesDnsmasqAbsentes`, qui la cherche par son nom exact.
        #
        # L'HISTORIQUE NE SUIT PAS : les points déjà écrits gardent l'ancien nom.
        # Un panneau qui passe au nom suffixé perd sa courbe d'avant le
        # déploiement, une fois.
        #
        # CE QUI N'EST PAS TRAITÉ, ET POURQUOI : `phpfpm_max_children_reached`,
        # `phpfpm_scrape_failures` et `smartctl_device_media_errors` ne sont lus
        # que par des RÈGLES — l'avertissement est un contrôle de l'éditeur de
        # Grafana, personne ne le verra jamais, et le renommage coûterait
        # l'historique pour rien. `smartctl_device_attribute` serait carrément
        # FAUSSE à renommer : le nom couvre tous les attributs SMART à la fois,
        # dont certains sont des compteurs et d'autres des jauges (température,
        # usure).
        suffixeTotal = noms: [
          {
            source_labels = [ "__name__" ];
            regex = "(${noms})";
            target_label = "__name__";
            replacement = "${"$"}{1}_total";
          }
        ];
      };
    };

    # Fragments de requête employés par PLUSIEURS fichiers. Ceux qui ne servent
    # qu'à un composant restent dans son `let`, à côté de la règle et du panneau
    # qui les partagent.
    q = internalOpt {
      readOnly = true;
      default = {
        # Les alertes qui brûlent, `Watchdog` exclu : il brûle en permanence par
        # construction (cf. components/meta.nix), et le laisser peindrait chaque
        # vue d'une alerte de fond devant laquelle on apprend à ne plus
        # regarder.
        alertesActives = ''ALERTS{alertstate="firing", alertname!="Watchdog"}'';

        # Le nom d'hôte d'une URL sondée, en étiquette `cible`. L'`instance`
        # d'une sonde est l'URL complète, trop longue pour une légende ou
        # l'étiquette d'une bande ; l'infobulle garde l'URL entière.
        parCible = expr: ''label_replace(${expr}, "cible", "$1", "instance", "https?://([^/]+).*")'';
      };
    };

    # Tâches de collecte Prometheus, par nom. Une valeur est une tâche, ou une
    # LISTE de tâches quand leur nombre n'est connu qu'à l'évaluation (blackbox).
    # Ordre : cf. prometheus.nix.
    scrapeJobs = internalOpt { };

    # Règles d'alerte Prometheus, par clé (le nom de l'alerte, sauf doublon).
    #
    # Un attribut `inhibits = { alertname; equal; }` sur une règle CRITIQUE
    # déclare l'avertissement qu'elle rend redondant (cf. alertmanager.nix) ; il
    # est retiré avant l'écriture des règles. Groupes et ordre : cf.
    # prometheus.nix.
    alertRules = internalOpt { };

    # Groupes de règles évaluées par le ruler de Loki, par nom. Le ruler n'est
    # monté que s'il en existe au moins un (cf. loki.nix).
    lokiRuleGroups = internalOpt { };

    # Panneaux du tableau de bord, par nom. Position : cf. dashboard.nix.
    panels = internalOpt { };
  };
}
