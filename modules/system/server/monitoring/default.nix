{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Surveillance du host : métriques, alertes, et une interface pour regarder les
# courbes.
#
# CE QUE ÇA COMPLÈTE, et pourquoi ce n'est pas redondant. `systemSettings.notify.discord`
# signale un ÉVÉNEMENT — une unité qui échoue — et `acme-expiry-check` vérifie
# un ÉTAT précis, celui du certificat servi. Ni l'un ni l'autre ne voit venir
# une panne : un disque à 92 %, une mémoire qui part en swap, une unité qui
# échoue une fois par nuit sans que personne ne relie les occurrences. C'est ce
# trou-là que ce module ferme, et c'est le seul.
#
# LES BRIQUES, chacune avec un rôle qui ne recouvre pas les autres. Les quatre
# premières sont le socle et sont toujours là ; les deux suivantes s'allument par
# option, sur des hosts qui ont quelque chose à leur donner à regarder :
#
#   - node_exporter  : ce que la machine sait d'elle-même (disque, mémoire,
#                      charge, état des unités systemd, dérive d'horloge).
#   - blackbox       : ce qu'un client voit en tapant sur une URL — code de
#                      retour, temps de réponse, expiration du certificat.
#   - Prometheus     : collecte, historique, et ÉVALUATION DES RÈGLES. C'est lui
#                      qui décide qu'il y a un problème.
#   - Alertmanager   : regroupe, dédoublonne, et pousse vers Discord.
#   - `apps`         : ce que les SERVICES savent d'eux-mêmes et que la machine
#                      ignore — un pool PHP saturé, un portail qui refuse tout
#                      le monde. Le processeur va très bien pendant ce temps-là.
#   - `logs`         : Vector lit le journal, Loki le range. Tout le reste ici
#                      mesure des nombres, et un nombre ne dit jamais POURQUOI.
#                      Loki sert aussi de second moteur d'alerte, mais seulement
#                      pour ce qu'aucune métrique ne peut voir (cf.
#                      `logs.kernelAlerts`).
#
# Grafana n'est PAS dans cette liste, et ce n'est pas un oubli : il ne fait que
# regarder. Rien de ce qui prévient ne dépend de lui, on peut l'arrêter sans
# perdre une alerte.
#
# LA LIMITE, à garder en tête avant de s'y fier : tout ça tourne SUR la machine
# surveillée. Si think s'arrête, Prometheus s'arrête avec, et le silence qui
# suit ressemble exactement à « tout va bien ». C'est la raison d'être de
# `deadManSwitch` plus bas, seule pièce dont la défaillance se voit depuis
# l'extérieur.
#
# AUCUN PORT OUVERT : chaque composant écoute sur la boucle locale, et le seul
# accès est le vhost Grafana, derrière le tunnel et Authelia comme Nextcloud.
let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  cloudflared = config.systemSettings.cloudflared;
  dns = config.systemSettings.dns;
  notify = config.systemSettings.notify.discord;
  nextcloud = config.systemSettings.nextcloud;
  proxy = config.systemSettings.proxy;
  wireguard = config.systemSettings.vpn.wireguard;

  # Chaque exporteur applicatif suit le service qu'il observe : allumer celui de
  # PHP-FPM sur une machine sans Nextcloud ne produirait pas une erreur, mais
  # une tâche de collecte en échec permanent, donc une alerte `CibleInjoignable`
  # qui hurle sans rien signaler.
  appsOn = svc: cfg.apps.enable && svc;

  # Le nom lisible des pairs WireGuard n'est PAS dans l'interface : `wg show` ne
  # connaît que des clés publiques. L'exporteur sait les traduire, à condition
  # qu'on lui donne un fichier au format wg-quick portant des commentaires
  # `# friendly_name`. Cette machine monte wg0 par systemd-networkd et n'a donc
  # aucun fichier de ce genre — on le fabrique depuis la même liste de pairs qui
  # sert à configurer l'interface, ce qui garantit qu'il ne peut pas diverger.
  #
  # AUCUN SECRET DEDANS, et c'est ce qui permet de le poser dans le store : que
  # des clés PUBLIQUES et des noms. Les clés pré-partagées, elles, restent dans
  # sops et ne passent pas par ici.
  # LE COMMENTAIRE VA DEDANS, après `[Peer]`, et l'ordre n'est pas une question
  # de style : l'exporteur rattache `# friendly_name` à la section OUVERTE au
  # moment où il le lit. Placé avant `[Peer]`, chaque nom glisse sur le pair
  # suivant et le dernier n'en reçoit aucun — c'est arrivé, et ça se voit très
  # bien une fois les noms comparés aux adresses.
  wireguardNames = pkgs-stable.writeText "wg0-peer-names.conf" (
    lib.concatMapStrings (p: ''
      [Peer]
      # friendly_name = ${p.name}
      PublicKey = ${p.publicKey}
      AllowedIPs = ${p.address}/32

    '') wireguard.peers
  );

  # Ports de BOUCLAGE, détails d'implémentation : rien ici n'est joignable de
  # l'extérieur, donc aucune de ces valeurs n'est une adresse à communiquer.
  # Constantes plutôt qu'options, contrairement à `authelia.port` : aucun autre
  # module n'a de raison de les reprendre.
  ports = {
    prometheus = 9090;
    alertmanager = 9093;
    node = 9100;
    blackbox = 9115;
    grafana = 3000;
    smartctl = 9633;

    # Journaux. HORS des 9000 contrairement au reste du bloc, et c'est
    # délibéré : 3100 est le port par défaut de Loki, celui que toute la
    # documentation et tous les exemples emploient. S'en écarter ferait gagner
    # une cohérence interne au prix d'une divergence avec tout ce qu'on lira
    # ailleurs le jour où quelque chose ne marchera pas.
    #
    # La mise en garde qui accompagne ce bloc ne s'applique pas ici : elle vise
    # les 8000, où les applications de `systemSettings.apps` se servent. 3100 et
    # 9096 ne sont pris par personne, vérifié contre les ports ci-dessus.
    #
    # Le port gRPC ne sert à RIEN dans ce montage — il n'existe que pour la
    # communication entre composants d'un Loki distribué, et celui-ci tourne en
    # binaire unique. Loki l'ouvre quand même, on le fixe donc pour qu'il soit
    # sur la boucle locale et pas sur un port choisi au hasard.
    loki = 3100;
    lokiGrpc = 9096;

    # Exporteurs applicatifs. `nginxStatus` n'est PAS un exporteur mais le
    # `stub_status` de nginx lui-même : il lui faut un socket à lui, sur la
    # boucle locale, et surtout pas `services.nginx.statusPage`, qui écoute sur
    # 0.0.0.0:80 et pose un vhost `localhost`. Aucun vhost de cette machine
    # n'étant marqué `default`, en ajouter un sur le port 80 déplacerait le
    # serveur par défaut de nginx — c'est-à-dire changerait qui répond aux
    # requêtes dont l'en-tête `Host` ne correspond à rien, ce sur quoi repose le
    # 404 neutre des partages Nextcloud. Un port dédié ne touche à rien.
    #
    # DANS LES 9000, comme tout ce bloc, et surtout pas dans les 8000 : les
    # applications de `systemSettings.apps` s'y servent (8080, 8081, 8222 sont
    # pris), et rien ne fait échouer le build en cas de collision — nginx
    # démarrerait simplement en « Address already in use », après déploiement,
    # emportant tous les vhosts avec lui.
    nginxStatus = 9114;
    nginx = 9113;
    phpfpm = 9253;
    wireguardExporter = 9586;
    autheliaMetrics = 9959;
    nextcloudExporter = 9205;

    # Ports PAR DÉFAUT de chacun de ces exporteurs, repris tels quels : ils sont
    # dans les 9000 comme le reste du bloc, et s'en écarter ne ferait diverger
    # ce fichier de toute la documentation amont sans rien gagner.
    #
    # `vector` est le seul qui ne vienne pas d'un module NixOS : Vector n'expose
    # rien par défaut, c'est un puits `prometheus_exporter` déclaré plus bas qui
    # ouvre ce port, et 9598 est la valeur que Vector emploie lui-même.
    postgres = 9187;
    redis = 9121;
    dnsmasq = 9153;
    vector = 9598;
  };

  # SOCLE COMMUN DES EXPORTEURS. Sept d'entre eux répétaient ces trois lignes à
  # l'identique, et la deuxième n'est pas un détail de confort : c'est elle qui
  # décide que rien de tout ça n'est joignable depuis le réseau. Écrite sept
  # fois, elle est à la merci d'un huitième exporteur ajouté sans elle — et
  # l'oubli ne casse rien, il OUVRE, ce qui ne se voit jamais dans un rebuild
  # réussi.
  #
  # Même raisonnement que `mkHttpProber` plus bas : ce qui doit valoir pour tous
  # s'écrit une fois.
  #
  # Prometheus et Alertmanager restent explicites, eux : ce ne sont pas des
  # exporteurs, leurs blocs portent d'autres réglages, et le commentaire qui
  # justifie leur écoute locale se lit mieux à côté de la ligne concernée.
  localExporter = port: {
    enable = true;
    listenAddress = "127.0.0.1";
    inherit port;
  };

  # Cible de collecte sur la boucle locale, dix fois recopiée telle quelle. Le
  # `job_name` reste écrit à côté de chaque appel : c'est lui qui porte le sens,
  # et c'est le nom qu'on lira dans une alerte.
  localTarget = port: [ { targets = [ "127.0.0.1:${toString port}" ]; } ];

  # Répertoire où systemd dépose les credentials de l'unité alertmanager.
  #
  # Écrit en dur parce qu'il le faut : le fichier de configuration vit dans le
  # store et ne peut pas contenir `%d`, qui n'est développé que dans les
  # directives d'unité. Le chemin est celui que systemd garantit et expose par
  # $CREDENTIALS_DIRECTORY (systemd.exec) — c'est déjà l'hypothèse que fait le
  # notifieur de modules/system/notify.
  #
  # POURQUOI PASSER PAR LÀ plutôt que lire /run/secrets directement : le module
  # amont fait tourner alertmanager en `DynamicUser`, donc sous un uid qui
  # change à chaque démarrage. Aucun `owner` sops ne peut désigner ce compte.
  # systemd, lui, lit le secret en root AVANT d'abaisser les privilèges et le
  # remet en lecture seule pour cette unité-là seulement.
  amCredentials = "/run/credentials/alertmanager.service";

  # SEUILS EMBOÎTÉS : les couples de règles qui décrivent le MÊME symptôme à deux
  # hauteurs. La critique déclenche toujours l'autre avec elle — un disque à 96 %
  # dépasse aussi 85 % — donc sans inhibition, deux messages partent pour un seul
  # problème, dont un qui le minimise.
  #
  # POURQUOI CETTE LISTE PLUTÔT QUE LA RÈGLE GÉNÉRIQUE qui vivait ici, et qui
  # n'inhibait RIEN. Elle était écrite ainsi, ce qui est l'exemple canonique de la
  # documentation d'Alertmanager :
  #
  #   source severity="critical" → target severity="warning", equal = [ alertname, instance ]
  #
  # Cet exemple suppose qu'une MÊME règle émette tantôt `warning` tantôt
  # `critical`, en portant la gravité dans une étiquette calculée. Ici, chaque
  # règle a un nom ET une gravité fixes : il n'existe pas une seule paire
  # d'alertes partageant un `alertname` avec deux gravités différentes — vérifié
  # sur les quarante-sept règles du fichier. La condition `equal` ne pouvait donc
  # jamais être satisfaite, et l'inhibition ne s'est jamais appliquée depuis
  # qu'elle est écrite. Le doublon qu'elle prétendait supprimer partait bel et
  # bien sur Discord.
  #
  # Les paires sont donc NOMMÉES. C'est plus verbeux et c'est vérifiable : chacune
  # se lit contre les règles correspondantes, et une paire ajoutée sans son entrée
  # ici se voit à la première alerte en double.
  #
  # `equal` porte sur ce qui identifie l'OBJET, pas sur l'alerte : deux points de
  # montage qui se remplissent en même temps doivent rester deux alertes.
  seuilsEmboites = [
    {
      critique = "DisquePresquePlein";
      avertissement = "DisqueBientotPlein";
      equal = [
        "instance"
        "mountpoint"
      ];
    }
    {
      critique = "CertificatExpireImminent";
      avertissement = "CertificatBientotExpire";
      equal = [ "instance" ];
    }
    {
      # Une sonde qui échoue est aussi comptée LENTE : elle échoue le plus
      # souvent par expiration du délai, à dix secondes, donc bien au-delà des
      # cinq de `SondeLente`. Les deux partent ensemble sur la même URL.
      critique = "SondeEnEchec";
      avertissement = "SondeLente";
      equal = [ "instance" ];
    }
    {
      # Zéro connexion vers l'edge est aussi « moins de quatre ». Le tunnel coupé
      # emportait donc son propre avertissement de redondance entamée.
      critique = "TunnelCloudflareCoupe";
      avertissement = "TunnelCloudflareDegrade";
      equal = [ "instance" ];
    }
  ];

  # SUFFIXE `_total` POSÉ À LA COLLECTE, sur des compteurs que leur exporteur
  # publie sans lui.
  #
  # LE PROBLÈME, identique pour les trois exporteurs concernés : ce sont bien des
  # compteurs — ils ne font que croître —, mais leur nom ignore la convention
  # Prometheus. Toute requête `rate()` ou `increase()` dessus fait alors écrire à
  # Grafana, à chaque ouverture du tableau :
  #
  #   metric might not be a counter, name does not end in
  #   _total/_sum/_count/_bucket
  #
  # Corrigé plutôt que toléré, et c'est le même raisonnement partout dans ce
  # fichier : un avertissement qu'on apprend à ignorer est un avertissement qui
  # masquera le suivant.
  #
  # ÉCRIT UNE FOIS parce qu'il l'était TROIS, à l'identique et avec le même piège
  # à chaque copie — `${"$"}{1}` et non `$1`, Prometheus employant l'expansion Go
  # où `$1_total` désigne un groupe nommé `1_total`, inexistant, donc remplacé
  # par du vide. Trois copies d'un piège, c'est trois occasions de le rater.
  #
  # NE PRENDRE QUE DES COMPTEURS, et la vérification n'est pas facultative : le
  # type déclaré par l'exporteur ne suffit pas à trancher. L'exporteur dnsmasq
  # annonce TOUTES ses métriques en `gauge`, y compris `hits` et `misses` qui
  # sont cumulatifs — relevé en les mesurant deux fois à douze secondes
  # d'intervalle. À l'inverse, `dnsmasq_cachesize` est une vraie jauge et n'a
  # rien à faire ici : la renommer casserait l'alerte `MetriquesDnsmasqAbsentes`,
  # qui la cherche par son nom exact.
  #
  # L'HISTORIQUE NE SUIT PAS : les points déjà écrits gardent l'ancien nom, les
  # nouveaux prennent le nouveau. Un panneau qui passe au nom suffixé perd donc
  # sa courbe d'avant le déploiement, une fois.
  #
  # CE QUI N'EST PAS TRAITÉ ICI, ET POURQUOI — la liste est volontairement plus
  # courte que celle de tous les compteurs mal nommés du parc. Quatre autres
  # existent (`phpfpm_max_children_reached`, `phpfpm_scrape_failures`,
  # `smartctl_device_media_errors`, `smartctl_device_attribute`), et aucune ne
  # gagnerait à passer par là :
  #
  #   - les trois premières ne sont lues que par des RÈGLES. L'avertissement est
  #     un contrôle de l'éditeur de Grafana, il n'existe pas côté Prometheus :
  #     personne ne le verra jamais, et le renommage coûterait l'historique pour
  #     rien ;
  #   - `smartctl_device_attribute` serait carrément FAUSSE à renommer. Le nom
  #     couvre tous les attributs SMART à la fois, dont certains sont des
  #     compteurs (secteurs réalloués) et d'autres des jauges (température,
  #     usure). Le panneau « Disques : usure et réserve » la lit d'ailleurs sans
  #     `rate()`, sur l'attribut 202 : la suffixer casserait ce panneau tout en
  #     mentant sur la moitié des attributs.
  #
  # Autrement dit, ce helper se pose sur des noms VÉRIFIÉS un par un, jamais sur
  # une famille entière par symétrie.
  suffixeTotal = noms: [
    {
      source_labels = [ "__name__" ];
      regex = "(${noms})";
      target_label = "__name__";
      replacement = "${"$"}{1}_total";
    }
  ];

  # Filtre commun aux règles sur les systèmes de fichiers.
  #
  # `/nix/store` en est EXCLU, et ça n'a rien d'esthétique : sur NixOS c'est un
  # montage lié en lecture seule de la racine, donc node_exporter le rapporte
  # comme un système de fichiers à part alors qu'il partage les mêmes octets.
  # Sans cette exclusion, chaque alerte de remplissage partirait en double, sur
  # deux points de montage qui désignent le même disque.
  #
  # `/boot` est gardé À DESSEIN, alors qu'on l'oublie souvent : c'est la
  # partition qui se remplit toute seule sur cette distribution, une génération
  # à la fois, et son remplissage casse le rebuild suivant.
  fsSelector = ''fstype!~"tmpfs|ramfs|overlay|nsfs|squashfs|fuse.*",mountpoint!="/nix/store"'';

  # SOCLE COMMUN des sondes HTTP. Les deux modules ne diffèrent que par le code
  # de retour attendu ; tout le reste — la version du protocole, le refus de
  # suivre les redirections, l'exigence de TLS, la famille d'adresses — porte une
  # décision qui doit valoir pour TOUTES les sondes.
  #
  # Écrit une fois plutôt que recopié : deux blocs jumeaux finissent toujours par
  # diverger sur la ligne qu'on a oublié de reporter, et la divergence ne se voit
  # pas — la sonde continue de répondre, simplement elle ne vérifie plus la même
  # chose.
  mkHttpProber = valid_status_codes: {
    prober = "http";
    timeout = "10s";
    http = {
      method = "GET";
      valid_http_versions = [
        "HTTP/1.1"
        "HTTP/2.0"
      ];
      inherit valid_status_codes;

      # NE PAS SUIVRE les redirections, alors que blackbox le fait par défaut.
      # Les suivre menait tout droit à la page de connexion du portail, qui
      # répond 200 : la sonde de `cloud.` validait donc Authelia à la place du
      # service qu'elle était censée surveiller, et serait restée verte avec
      # Nextcloud à terre. Sans ce réglage, une sonde ne dit plus « ce service
      # répond » mais « quelque chose répond au bout de la chaîne ».
      follow_redirects = false;

      fail_if_not_ssl = true;

      # Pas d'IPv6 sur ce parc (les annonces de routeur sont refusées, cf.
      # modules/system/network) : sans ce réglage la sonde tente d'abord une
      # famille qui ne répond pas et compte l'échec.
      preferred_ip_protocol = "ip4";
      ip_protocol_fallback = false;
    };
  };

  blackboxConfig = pkgs-stable.writeText "blackbox.yml" (
    builtins.toJSON {
      modules = {
        # Le service répond vraiment. Liste VIDE = le défaut de blackbox, soit
        # 2xx et rien d'autre.
        http_2xx = mkHttpProber [ ];

        # Nom protégé par Authelia, sondé DEPUIS le host. L'adresse source n'est
        # ni celle du VPN ni rien qu'une règle `bypass` reconnaisse, donc le
        # portail répond 302 vers la page de connexion.
        #
        # LE 302 ET RIEN D'AUTRE, et c'est ce qui rend cette sonde utile dans les
        # DEUX SENS. Un 200 sur un nom protégé ne serait pas une bonne nouvelle :
        # il voudrait dire que le portail ne s'interpose plus. L'accepter, c'est
        # écrire une sonde qui reste verte pendant que la protection tombe.
        http_authelia = mkHttpProber [ 302 ];
      };
    }
  );

  probes = lib.attrValues cfg.blackbox.targets;
  probeModules = lib.unique (map (p: p.module) probes);
  urlsFor = m: map (p: p.url) (lib.filter (p: p.module == m) probes);

  # Une tâche de collecte par module blackbox employé : le module est un
  # PARAMÈTRE de requête, il ne peut donc pas varier à l'intérieur d'une tâche.
  #
  # Les `relabel_configs` sont la mécanique standard et non négociable de cet
  # exporteur : l'adresse de la cible doit devenir le paramètre `target`, puis
  # l'adresse réellement contactée doit être remplacée par celle de l'exporteur.
  # Sans la troisième règle, Prometheus irait interroger l'URL surveillée
  # elle-même en lui demandant des métriques.
  blackboxJobs = map (m: {
    job_name = "blackbox-${m}";
    metrics_path = "/probe";
    params.module = [ m ];
    # Moins souvent que le reste : une sonde ouvre une vraie connexion TLS vers
    # un service tiers, on ne le fait pas toutes les trente secondes.
    scrape_interval = "1m";
    scrape_timeout = "15s";
    static_configs = [ { targets = urlsFor m; } ];
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        source_labels = [ "__param_target" ];
        target_label = "instance";
      }
      {
        target_label = "__address__";
        replacement = "127.0.0.1:${toString ports.blackbox}";
      }
    ];
  }) probeModules;

  # RÈGLES D'ALERTE. C'est la seule partie de ce module qui décide de quelque
  # chose : Prometheus fraîchement installé collecte en silence et ne dit jamais
  # rien tant que rien n'est écrit ici.
  #
  # Deux réglages portent tout le poids et méritent qu'on y revienne quand une
  # alerte agace : le SEUIL, et surtout le `for`, qui exige que la condition
  # tienne pendant toute la durée. C'est lui qui fait la différence entre une
  # alerte qu'on lit et une alerte qu'on apprend à ignorer.
  alertRules = {
    groups = [
      {
        name = "host";
        rules = [
          {
            alert = "CibleInjoignable";
            expr = "up == 0";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "La cible {{ $labels.instance }} (tâche {{ $labels.job }}) ne répond plus depuis 5 minutes.";
          }
          {
            alert = "DisqueBientotPlein";
            expr = "100 * (1 - node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}) > 85";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.mountpoint }} occupé à {{ $value | printf \"%.1f\" }} %.";
          }
          {
            alert = "DisquePresquePlein";
            expr = "100 * (1 - node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}) > 95";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.mountpoint }} occupé à {{ $value | printf \"%.1f\" }} %, la machine va commencer à casser.";
          }
          {
            # La SEULE règle qui prévient AVANT que le seuil soit atteint :
            # elle extrapole la pente des six dernières heures. Le second terme
            # n'est pas décoratif — sans lui, un disque à 4 % d'occupation qui
            # gagne un mégaoctet déclencherait l'alerte au moindre bruit de
            # mesure.
            alert = "DisquePleinEnTroisJours";
            expr = "predict_linear(node_filesystem_avail_bytes{${fsSelector}}[6h], 3 * 24 * 3600) < 0 and node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}} < 0.4";
            for = "1h";
            labels.severity = "warning";
            annotations.summary = "Au rythme actuel, {{ $labels.mountpoint }} sera plein d'ici trois jours.";
          }
          {
            # Se remplit indépendamment de l'espace, et le message d'erreur qui
            # en découle (« No space left on device » sur un disque à moitié
            # vide) est parmi les plus déroutants qui soient.
            alert = "InodesEpuises";
            expr = "node_filesystem_files_free{${fsSelector}} / node_filesystem_files{${fsSelector}} * 100 < 10";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.mountpoint }} : plus que {{ $value | printf \"%.1f\" }} % d'inodes libres.";
          }
          {
            # Bascule que le noyau opère seul quand il trouve une corruption. La
            # machine continue de tourner et de répondre, mais plus rien ne
            # s'écrit — c'est la panne la plus silencieuse de la liste.
            alert = "SystemeDeFichiersEnLectureSeule";
            expr = "node_filesystem_readonly{${fsSelector}} == 1";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.mountpoint }} est passé en lecture seule.";
          }
          {
            # `MemAvailable` et pas `MemFree` : le noyau garde volontairement peu
            # de mémoire libre, l'essentiel servant de cache. Seul le premier dit
            # ce qu'une application pourrait réellement obtenir.
            alert = "MemoireFaible";
            expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100 < 10";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "Mémoire disponible à {{ $value | printf \"%.1f\" }} %.";
          }
          {
            alert = "SwapSollicite";
            expr = "(node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes) / node_memory_SwapTotal_bytes * 100 > 50";
            for = "1h";
            labels.severity = "warning";
            annotations.summary = "Swap occupé à {{ $value | printf \"%.1f\" }} % : quelque chose ne tient plus en mémoire.";
          }
          {
            # Sans `for` : un tueur de mémoire a déjà fait son travail quand on
            # l'apprend, attendre une confirmation n'aurait aucun sens.
            alert = "ProcessusTuePourMemoire";
            expr = "increase(node_vmstat_oom_kill_total[15m]) > 0";
            labels.severity = "critical";
            annotations.summary = "Le noyau a tué au moins un processus faute de mémoire.";
          }
          {
            # Rapportée au NOMBRE DE CŒURS, faute de quoi le seuil ne veut rien
            # dire : une charge de 4 est confortable sur huit cœurs et
            # catastrophique sur un.
            alert = "ChargeElevee";
            expr = "node_load15 > 2 * count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "Charge sur 15 minutes à {{ $value | printf \"%.1f\" }}, soit plus du double des cœurs disponibles.";
          }
          {
            # RECOUVRE partiellement `notify.discord`, et c'est voulu : celui-ci
            # signale la TRANSITION vers l'échec, celle-là l'ÉTAT qui dure. Une
            # unité tombée pendant que Discord était injoignable n'apparaît que
            # dans la seconde.
            alert = "UniteSystemdEnEchec";
            expr = "node_systemd_unit_state{state=\"failed\"} == 1";
            for = "10m";
            labels.severity = "warning";
            annotations.summary = "L'unité {{ $labels.name }} est en échec.";
          }
          {
            # LE SERVICE QUI RENAÎT SANS JAMAIS MOURIR. `UniteSystemdEnEchec`
            # juste au-dessus voit l'état `failed` ; celle-ci voit ce qui ne
            # l'atteint jamais.
            #
            # Un conteneur dont l'amont disparaît par intermittence redémarre
            # toutes les minutes sans épuiser `StartLimitBurst` : il reste
            # `active` en permanence, aucune règle d'état ne le remarque, et la
            # sonde HTTP le trouve debout entre deux morts. Le seul symptôme est
            # ce compteur qui monte.
            #
            # TROIS PAR HEURE comme seuil, et pas un : un rebuild redémarre
            # chaque service une fois, et une nuit d'`autoUpgrade` ne doit pas
            # sonner. Au-delà de trois, ce n'est plus un déploiement.
            #
            # Volontairement SANS filtre sur le nom : le mode de panne n'a rien
            # de propre aux conteneurs, il vaut pour tout ce qui porte une
            # politique de redémarrage.
            alert = "ServiceRedemarreEnBoucle";
            expr = "increase(node_systemd_service_restart_total[1h]) > 3";
            for = "10m";
            labels.severity = "warning";
            annotations.summary = "L'unité {{ $labels.name }} a redémarré {{ $value | printf \"%.0f\" }} fois en une heure : elle tourne, mais elle n'arrête pas de renaître.";
          }
          {
            # LE PLAFOND QUI NE PRÉVIENT PAS. La table de suivi de connexions du
            # noyau a une taille finie ; une fois pleine, le noyau REFUSE les
            # nouvelles connexions et écrit une ligne dans son journal, mais rien
            # ne tombe en panne : les services tournent, les sondes locales
            # passent, et depuis l'extérieur les connexions échouent au hasard.
            # C'est une des pannes les plus déroutantes qui soient.
            #
            # PARTICULIÈREMENT SUR CETTE MACHINE, qui multiplie les sources de
            # connexions suivies : le tunnel Cloudflare, les pairs WireGuard, le
            # NAT du VPN et le résolveur, chacun avec ses flux UDP dont les
            # entrées expirent lentement.
            #
            # SUR LE RAPPORT et non sur un nombre : la limite est calculée par le
            # noyau depuis la mémoire disponible (262 144 ici), donc un seuil
            # absolu serait faux sur toute autre machine. À 234 entrées, la marge
            # actuelle est de trois ordres de grandeur — cette alerte est faite
            # pour dormir, exactement comme celles des disques.
            #
            # PAS D'ÉQUIVALENT POUR LES DESCRIPTEURS DE FICHIERS, et c'est
            # vérifié plutôt que supposé : `node_filefd_maximum` vaut ici 9,2
            # milliards de milliards, la limite que systemd pose quand il n'y en
            # a pas. Une règle sur ce rapport serait vraie « jamais », donc
            # inerte — le genre de surveillance qui rassure sans rien couvrir.
            alert = "TableDeConnexionsPresquePleine";
            expr = "node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100 > 80";
            for = "15m";
            labels.severity = "warning";
            annotations.summary = "Table de suivi des connexions occupée à {{ $value | printf \"%.0f\" }} % : au plafond, le noyau refusera les nouvelles connexions sans qu'aucun service ne tombe.";
          }
          {
            # Pas un détail de confort sur CETTE machine : les codes TOTP
            # d'Authelia sont calculés sur l'heure, et une dérive suffisante les
            # fait tous refuser sans que rien n'explique pourquoi.
            alert = "HorlogeDerive";
            expr = "abs(node_timex_offset_seconds) > 0.05";
            for = "15m";
            labels.severity = "warning";
            annotations.summary = "Horloge décalée de {{ $value | printf \"%.3f\" }} s : les codes TOTP finiront par être refusés.";
          }
          {
            # LA CHALEUR, QUI NE FAIT ÉCHOUER AUCUNE UNITÉ. Le tableau montrait
            # les températures depuis toujours, mais un graphique ne réveille
            # personne — et c'est le genre de dérive qui s'installe sur des
            # semaines : de la poussière qui s'accumule, un ventilateur qui
            # ralentit, un été. Rien ne casse, jusqu'au jour où le processeur se
            # bride ou où le disque abrège sa vie.
            #
            # AU SEUIL DU CONSTRUCTEUR et non à un chiffre choisi au hasard :
            # `node_hwmon_temp_crit_celsius` est la limite que le matériel
            # déclare lui-même — 100 °C sur cette machine. Alerter à 90 % de
            # cette valeur laisse une marge réelle sans supposer quoi que ce soit
            # d'un matériel qu'on ne connaît pas. Même raisonnement que
            # `DisqueReserveEpuisee`, qui s'appuie sur le seuil du disque plutôt
            # que sur un pourcentage inventé.
            #
            # LE `on(chip, sensor)` PORTE SUR LA COMPARAISON, pas sur la
            # multiplication : `0.9 * on(…) métrique` ne s'analyse pas, un
            # modificateur d'appariement ne pouvant pas s'appliquer entre un
            # scalaire et un vecteur. Écrit ainsi, PromQL rend un résultat vide
            # sans erreur — vérifié, et corrigé avant d'arriver ici.
            #
            # Les capteurs sans limite déclarée sont ignorés d'eux-mêmes : la
            # jointure ne les apparie à rien.
            alert = "MachineTropChaude";
            expr = "node_hwmon_temp_celsius >= on(chip, sensor) (0.9 * node_hwmon_temp_crit_celsius)";
            for = "15m";
            labels.severity = "warning";
            annotations.summary = "Capteur {{ $labels.chip }} à {{ $value | printf \"%.0f\" }} °C, soit 90 % de la limite constructeur : vérifie la poussière et les ventilateurs.";
          }
          {
            # LE TIMER QUI CESSE DE SE DÉCLENCHER, panne que ce dépôt nomme
            # depuis longtemps sans l'avoir instrumentée. Le commentaire de
            # modules/system/server/proxy la décrit mot pour mot : « Un timer qui
            # ne se déclenche plus n'échoue pas. Le silence ressemble au
            # succès. »
            #
            # C'est le mode d'échec le plus sournois du lot, parce qu'il ne
            # produit RIEN : pas d'unité en échec, pas de log, pas de métrique
            # qui bouge. Sur `nixos-upgrade`, il veut dire que les correctifs de
            # sécurité ont cessé d'arriver ; sur `acme-renew-*`, que les
            # certificats expireront dans trente jours sans un mot.
            #
            # QUARANTE-HUIT HEURES pour des timers QUOTIDIENS (vérifié :
            # `OnCalendar=*-*-*` sur les trois familles visées). Deux fois la
            # période laisse passer un décalage, un `Persistent` qui rattrape, ou
            # une machine éteinte une nuit — sans laisser filer une panne réelle.
            #
            # `> 0` N'EST PAS DÉCORATIF : un timer jamais déclenché depuis le
            # démarrage rapporte zéro, et `time() - 0` rendrait l'heure Unix
            # courante, soit cinquante-six ans de retard. C'est exactement le
            # piège qui rendait le panneau WireGuard illisible.
            #
            # Restreint aux timers dont le silence coûte quelque chose. Les
            # hebdomadaires (`fstrim`, `nix-gc`) sont volontairement exclus : ils
            # demanderaient un autre seuil, et leur arrêt ne casse rien
            # d'immédiat.
            alert = "TimerNeSeDeclenchePlus";
            expr = "(time() - node_systemd_timer_last_trigger_seconds{name=~\"nixos-upgrade.timer|acme-.+\"} > 172800) and (node_systemd_timer_last_trigger_seconds > 0)";
            for = "1h";
            labels.severity = "critical";
            annotations.summary = "Le timer {{ $labels.name }} ne s'est pas déclenché depuis plus de 48 h : ce qu'il devait faire ne se fait plus, et rien d'autre ne le dirait.";
          }
        ]
        ++ lib.optionals (cloudflared.metricsAddress != null) [
          {
            # LA PANNE QUE `up` NE VOIT PAS, et le module cloudflared l'annonce
            # déjà : « L'unité systemd reste `active` dans ce cas — le démon
            # tourne, il n'a simplement plus de chemin vers internet ». Sa page
            # de métriques répond donc parfaitement pendant que le site est
            # injoignable depuis l'extérieur.
            #
            # Les sondes blackbox ne le voient pas non plus pour la plupart :
            # elles visent des noms que dnsmasq réécrit vers le LAN, donc elles
            # tapent sur nginx sans traverser le tunnel. Seules celles du
            # portfolio et de RLkart passent par l'edge.
            #
            # Nom de métrique RELEVÉ sur la page /metrics du démon et non deviné,
            # les noms de cloudflared s'assemblant à l'exécution et ne se lisant
            # pas dans le binaire : `cloudflared_tunnel_ha_connections`, qui vaut
            # 4 en fonctionnement normal.
            alert = "TunnelCloudflareCoupe";
            expr = "cloudflared_tunnel_ha_connections == 0";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "Le tunnel Cloudflare n'a plus aucune connexion vers l'edge : tout ce qui est publié sur internet est injoignable, alors que le démon tourne.";
          }
          {
            # REDONDANCE ENTAMÉE, pas encore de panne. cloudflared maintient
            # quatre connexions vers l'edge ; en perdre une n'interrompt rien,
            # mais annonce souvent la suite.
            #
            # Une heure de `for`, parce qu'une reconnexion ponctuelle fait
            # descendre le compte quelques secondes et n'a rien d'anormal. Ce
            # qu'on veut attraper est l'état qui DURE.
            alert = "TunnelCloudflareDegrade";
            expr = "cloudflared_tunnel_ha_connections < 4";
            for = "1h";
            labels.severity = "warning";
            annotations.summary = "Le tunnel Cloudflare n'a plus que {{ $value | printf \"%.0f\" }} connexions sur 4 : le service passe encore, la redondance non.";
          }
        ];
      }

      {
        name = "sondes";
        rules = [
          {
            alert = "SondeEnEchec";
            expr = "probe_success == 0";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.instance }} ne répond pas comme attendu.";
          }
          {
            alert = "SondeLente";
            expr = "probe_duration_seconds > 5";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.instance }} répond en {{ $value | printf \"%.1f\" }} s.";
          }
          {
            # DOUBLON ASSUMÉ avec `acme-expiry-check` (cf. modules/system/server/proxy),
            # et les deux méritent d'exister : la sonde du proxy vérifie le
            # certificat servi sur la boucle locale et n'a besoin de rien d'autre
            # que d'openssl, celle-ci passe par le même chemin qu'un vrai client
            # et garde un historique. Si l'une des deux tombe, l'autre couvre.
            #
            # Même seuil que là-bas — 21 jours — pour la même raison : lego
            # renouvelle à 30 jours, alerter plus tôt sonnerait à chaque fenêtre
            # de renouvellement normale.
            alert = "CertificatBientotExpire";
            expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400 < 21";
            for = "1h";
            labels.severity = "warning";
            annotations.summary = "Le certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours.";
          }
          {
            alert = "CertificatExpireImminent";
            expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400 < 7";
            for = "10m";
            labels.severity = "critical";
            annotations.summary = "Le certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours, le renouvellement ne se fait plus.";
          }
        ];
      }
    ]
    ++ lib.optional cfg.disks.enable {
      # SANTÉ PHYSIQUE DES DISQUES. C'est le seul groupe de ce module dont les
      # alertes annoncent une perte de DONNÉES et non une interruption de
      # service : tout le reste se répare en redémarrant quelque chose.
      #
      # Il double `smartd`, déjà actif (cf. modules/system/storage/disks), et ça
      # ne fait pas doublon pour autant : smartd n'a que `systembus-notify` comme
      # canal, c'est-à-dire une notification de bureau sur une machine qui n'a
      # aucune session graphique. Il détecte, et personne ne l'entend.
      #
      # Tous les noms de métriques ci-dessous ont été relevés dans le binaire de
      # l'exporteur, pas devinés — une règle qui vise une métrique inexistante
      # ne fait jamais échouer quoi que ce soit, elle ne protège simplement de
      # rien, en silence.
      #
      # ET CE N'EST PAS SUFFISANT, la leçon ayant été apprise à froid : exister
      # dans le binaire ne veut pas dire être publié pour LE disque qu'on a.
      # `percentage_used`, `available_spare`, `critical_warning` et
      # `media_errors` viennent du health log NVMe et ne sortent QUE pour un
      # NVMe. Sur le SATA de cette machine, quatre des cinq règles d'origine
      # étaient inertes — sur le seul groupe dont les alertes annoncent une
      # perte de données. D'où les doublons ATA plus bas.
      #
      # Les deux familles cohabitent volontairement : les règles NVMe restent
      # inoffensives ici (leur métrique est absente, elles ne s'évaluent sur
      # rien) et redeviennent utiles le jour où un NVMe est branché, sans avoir
      # à y repenser.
      #
      # Côté ATA, le sélecteur porte sur `attribute_id` et NON sur
      # `attribute_name` : les identifiants sont à peu près standards, les noms
      # sont inventés par chaque constructeur — ce disque annonce
      # `Reallocate_NAND_Blk_Cnt` là où la littérature dit
      # `Reallocated_Sector_Ct`. Filtrer sur le nom, c'est refaire exactement la
      # panne silencieuse qu'on vient de corriger.
      name = "disques";
      rules = [
        {
          # Le verdict d'ensemble du disque : 0 signifie qu'il s'annonce
          # lui-même comme défaillant. Sur un NVMe, ça n'arrive pas avant que
          # plusieurs indicateurs soient déjà partis.
          alert = "DisqueSmartEnEchec";
          expr = "smartctl_device_smart_status == 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} se déclare défaillant (SMART). Sauvegarde ce qui compte AVANT de chercher à comprendre.";
        }
        {
          # Bits d'avertissement du contrôleur NVMe : réserve épuisée,
          # température hors plage, média en lecture seule, sauvegarde volatile
          # perdue. N'importe lequel mérite qu'on regarde tout de suite.
          alert = "DisqueAvertissementCritique";
          expr = "smartctl_device_critical_warning > 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} lève un avertissement critique NVMe (code {{ $value }}).";
        }
        {
          # Blocs de secours sous le seuil que le CONSTRUCTEUR a lui-même fixé,
          # plutôt qu'un pourcentage choisi au hasard : le disque sait mieux que
          # nous à partir de quand il n'a plus de marge.
          alert = "DisqueReserveEpuisee";
          expr = "smartctl_device_available_spare < smartctl_device_available_spare_threshold";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : blocs de secours sous le seuil constructeur, la fin est proche.";
        }
        {
          # Erreurs de média NON CORRIGÉES : chacune est une donnée que le
          # disque n'a pas pu relire. Sans `for`, parce qu'il n'y a rien à
          # confirmer — c'est déjà arrivé.
          alert = "DisqueErreursDeMedia";
          expr = "increase(smartctl_device_media_errors[24h]) > 0";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} erreur(s) de média non corrigée(s) en 24 h.";
        }
        {
          # Usure d'écriture, en pourcentage de l'endurance prévue. À 85 % le
          # disque fonctionne encore parfaitement : c'est une alerte pour
          # COMMANDER un remplaçant, pas pour intervenir dans l'heure.
          alert = "DisqueUsureElevee";
          expr = "smartctl_device_percentage_used > 85";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a consommé {{ $value | printf \"%.0f\" }} % de son endurance d'écriture.";
        }

        # --- Équivalents ATA/SATA des quatre règles NVMe ci-dessus ---------

        {
          # Attribut 202, pendant exact de `percentage_used` : la valeur BRUTE
          # est le pourcentage CONSOMMÉ (27 % au moment où cette règle est
          # écrite), la valeur normalisée étant son complément. Sémantique
          # Crucial/Micron, qui est ce qui est branché ; un autre constructeur
          # peut loger autre chose sous 202, à revérifier au changement de
          # disque.
          alert = "DisqueUsureElevee";
          expr = "smartctl_device_attribute{attribute_id=\"202\",attribute_value_type=\"raw\"} > 85";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a consommé {{ $value | printf \"%.0f\" }} % de son endurance d'écriture.";
        }
        {
          # Secteurs définitivement NON RELUS : 187 remontés au système, 198
          # découverts par l'analyse hors ligne. L'équivalent ATA de
          # `media_errors`. Ces deux-là ne font que MONTER, donc le seuil est
          # zéro et un `for` court suffit — il n'y a rien à confirmer, c'est
          # déjà arrivé.
          alert = "DisqueSecteursIllisibles";
          expr = "smartctl_device_attribute{attribute_id=~\"187|198\",attribute_value_type=\"raw\"} > 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} secteur(s) illisible(s) (attribut {{ $labels.attribute_id }}).";
        }
        {
          # Secteurs EN ATTENTE de relecture (197), séparés des deux précédents
          # parce que leur nature est différente : ce compteur monte ET
          # redescend, le disque retirant un secteur de la liste dès qu'il
          # parvient à le réécrire. Sur ce disque il oscille déjà entre 0 et 1.
          #
          # D'où le `for` d'une heure, seul paramètre qui distingue les deux
          # cas : un secteur récupéré disparaît en quelques minutes, un secteur
          # réellement mort reste en attente indéfiniment. À 5 minutes cette
          # règle sonnerait sur du bruit, et une alerte qui crie pour rien est
          # pire que pas d'alerte du tout.
          alert = "DisqueSecteursEnAttente";
          expr = "smartctl_device_attribute{attribute_id=\"197\",attribute_value_type=\"raw\"} > 0";
          for = "1h";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} secteur(s) en attente depuis plus d'une heure, donc non récupérable(s).";
        }
        {
          # Blocs réalloués, sur leur PROGRESSION et non leur valeur absolue :
          # un disque de remplacement peut arriver avec un compteur non nul
          # d'usine, alors qu'une réallocation qui CONTINUE est le signe que la
          # NAND lâche.
          alert = "DisqueBlocsRealloues";
          expr = "increase(smartctl_device_attribute{attribute_id=\"5\",attribute_value_type=\"raw\"}[24h]) > 0";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a réalloué {{ $value | printf \"%.0f\" }} bloc(s) en 24 h : commander un remplaçant.";
        }
        {
          # LA TEMPÉRATURE DU DISQUE, qui n'a pas de seuil constructeur exposé
          # contrairement aux capteurs de la carte — d'où un chiffre écrit ici.
          #
          # 55 °C sur une plage de fonctionnement de 0 à 70 pour un SSD SATA
          # grand public : quinze degrés de marge avant la limite, ce qui laisse
          # le temps d'ouvrir le boîtier. Au-delà de 70, l'électronique se bride
          # et l'endurance de la NAND chute — sans que rien ne tombe en panne,
          # ce qui est précisément le problème.
          #
          # Ce disque tourne à 38 °C, donc le seuil ne risque pas de sonner pour
          # une variation saisonnière. À revoir si un NVMe le remplace : ils
          # chauffent nettement plus et tolèrent davantage.
          #
          # `temperature_type="current"` N'EST PAS REDONDANT, même si ce disque
          # ne publie que ce type-là aujourd'hui (vérifié sur son /metrics).
          # L'exporteur sort aussi `drive_trip` — la température à laquelle le
          # disque se coupe, soit 70 °C et plus — quand le matériel la déclare,
          # ce que font les NVMe. Sans le filtre, brancher un NVMe allumerait
          # cette alerte en permanence sur une CONSTANTE, et une alerte
          # perpétuelle est une alerte qu'on coupe. Le panneau des températures
          # porte déjà le même filtre.
          alert = "DisqueTropChaud";
          expr = "smartctl_device_temperature{temperature_type=\"current\"} > 55";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} à {{ $value | printf \"%.0f\" }} °C : au-delà de 70 il se bride et son endurance chute, sans jamais tomber en panne.";
        }
        {
          # Erreurs CRC de la LIAISON SATA (attribut 199), pas du média : c'est
          # le câble, le connecteur ou l'alimentation, pas la NAND. Les données
          # sont retransmises, donc rien n'est perdu — mais un lien qui se
          # dégrade finit par faire tomber le disque du bus, ce qui, sur une
          # machine à disque unique, arrête tout.
          #
          # Sur la PROGRESSION, impérativement : le compteur est cumulatif
          # depuis la sortie d'usine et vaut déjà plusieurs milliers ici, hérité
          # d'un câblage antérieur. Une règle sur la valeur absolue serait
          # allumée en permanence, donc ignorée, donc inutile.
          alert = "DisqueLiaisonSataDegradee";
          expr = "increase(smartctl_device_attribute{attribute_id=\"199\",attribute_value_type=\"raw\"}[24h]) > 0";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} erreur(s) CRC sur la liaison SATA en 24 h. Câble ou connecteur, pas le disque.";
        }
      ];
    }
    ++ lib.optional cfg.apps.enable {
      name = "applications";
      rules = [
        {
          # LE PORTAIL EST TA PORTE D'ENTRÉE PUBLIQUE, et rien n'alertait dessus.
          # Le panneau « Authelia : requêtes filtrées par minute » montre les
          # refus depuis toujours, mais un graphique ne réveille personne.
          #
          # C'est la seule surface de ton montage qu'un inconnu peut attaquer
          # sans clé WireGuard : le coffre est derrière le VPN, SSH est sur un
          # port décalé, mais `auth.nathanchampagne.com` répond à tout internet
          # par construction — il faut bien que le formulaire de connexion soit
          # atteignable.
          #
          # SEUIL À VINGT PAR MINUTE, mesuré et non supposé. La ligne de base de
          # cette machine est remarquablement stable : 2 refus/min sur 5 min, sur
          # 1 h et sur 24 h, avec un maximum observé à 2,44. Ces deux-là sont tes
          # PROPRES sondes — `http_authelia` interroge deux noms protégés chaque
          # minute et reçoit deux 302, comptés comme des refus.
          #
          # Vingt est donc dix fois la normale et huit fois le pic jamais atteint.
          # Aucune chance de sonner pour du bruit, et impossible de rater une
          # campagne de bourrage d'identifiants, qui se compte en centaines.
          #
          # `code != "200"` plutôt qu'un code précis : un refus est un refus,
          # qu'Authelia réponde 401 sur une session absente ou 403 sur une règle.
          alert = "PortailRefusEnRafale";
          expr = "sum(rate(authelia_authz_total{code!=\"200\"}[5m])) * 60 > 20";
          for = "10m";
          labels.severity = "critical";
          annotations.summary = "{{ $value | printf \"%.0f\" }} refus par minute sur le portail, contre 2 en temps normal : quelqu'un insiste sur la seule porte ouverte à internet.";
        }
        {
          # `max_children_reached` est un compteur : PHP-FPM l'incrémente
          # chaque fois qu'il aurait voulu démarrer un processus de plus et
          # n'a pas pu. Sa valeur absolue ne dit rien — elle date peut-être du
          # mois dernier — donc la règle porte sur la PROGRESSION.
          #
          # C'est la traduction mesurable de « Nextcloud rame » : le pool est
          # au plafond, les requêtes attendent, et rien côté machine ne le
          # montre puisqu'un processus en attente ne consomme rien.
          alert = "PoolPhpSature";
          expr = "increase(phpfpm_max_children_reached[15m]) > 0";
          for = "5m";
          labels.severity = "warning";
          annotations.summary = "Le pool PHP-FPM de Nextcloud a atteint son plafond de processus : les requêtes attendent.";
        }
        {
          # L'exporteur joint sa cible mais s'en fait rejeter — socket absent,
          # `pm.status_path` disparu, `stub_status` retiré. `CibleInjoignable`
          # ne l'attrape PAS : de son point de vue l'exporteur répond très
          # bien, il répond juste du vide.
          #
          # DEUX FORMES parce que les deux exporteurs ne comptent pas pareil, et
          # ça se vérifie dans les binaires plutôt que par symétrie : nginx
          # publie un `nginx_up` (« Status of the last metric scrape »), php-fpm
          # n'a AUCUN `phpfpm_up` mais un compteur d'échecs cumulatif, donc une
          # progression.
          alert = "SondeApplicativeAveugle";
          expr = "nginx_up == 0 or increase(phpfpm_scrape_failures[15m]) > 0";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Un exporteur applicatif ne parvient plus à lire sa source : la courbe est plate, pas calme.";
        }
        {
          # MÊME NATURE que la règle ci-dessus, pour les deux bases. `pg_up` et
          # `redis_up` sont publiés par les exporteurs eux-mêmes et valent 0
          # quand ils joignent leur port mais pas leur base — mot de passe,
          # socket disparu, ou droits perdus sur le socket.
          #
          # Noms RELEVÉS sur les `/metrics` en fonctionnement, pas supposés :
          # les binaires de ces deux exporteurs assemblent leurs noms à
          # l'exécution et ne les révèlent pas à la lecture.
          alert = "BaseDeDonneesInjoignable";
          expr = "pg_up == 0 or redis_up == 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "Un exporteur de base de données n'atteint plus sa source ({{ $labels.job }}) : les courbes se vident sans que le service tombe.";
        }
      ]
      ++ lib.optional dns.enable {
        # `absent()` ET NON `== 0`, et c'est toute la leçon du 19 août 2026 :
        # l'exporteur dnsmasq visait `localhost:53`, résolu en `::1` où
        # dnsmasq n'écoute pas. Il répondait parfaitement sur son propre port
        # — donc `up` valait 1 — mais ne publiait AUCUNE mesure de DNS.
        #
        # Il n'existe pas de `dnsmasq_up` à comparer à zéro : la seule trace
        # de la panne est que la métrique n'existe pas du tout. `absent()` est
        # la seule construction qui sache dire ça.
        #
        # Recouvre `CibleInjoignable` quand l'exporteur est vraiment arrêté,
        # et c'est sans importance : l'inhibition par `severity` regroupe, et
        # une alerte de trop vaut mieux que le silence qu'on vient d'observer.
        #
        # CONDITIONNÉE À `dns.enable`, ET C'EST OBLIGATOIRE — contrairement aux
        # règles voisines, qui peuvent rester écrites sans leur service. Une
        # règle sur une métrique absente ne s'évalue sur rien et dort ; une
        # règle `absent()` sur une métrique absente est VRAIE, donc sonne sans
        # discontinuer. Sur un host où `apps` est actif sans dnsmasq — le cas
        # de n'importe quelle machine sans résolveur local — celle-ci partait
        # sur Discord toutes les douze heures pour signaler l'absence d'un
        # exporteur qui n'a jamais été demandé.
        alert = "MetriquesDnsmasqAbsentes";
        expr = "absent(dnsmasq_cachesize)";
        for = "15m";
        labels.severity = "warning";
        annotations.summary = "Aucune métrique DNS de dnsmasq n'arrive : l'exporteur répond mais ne mesure rien.";
      }
      ++ lib.optional dns.enable {
        # LA RÉSOLUTION QUI NE RÉSOUT PLUS, et rien ne la surveillait. La règle
        # ci-dessus vérifie que dnsmasq MESURE ; celle-ci vérifie qu'il
        # RÉUSSIT. Ce n'est pas la même chose, et l'écart entre les deux est une
        # panne complète : dnsmasq répond parfaitement, son cache fonctionne,
        # ses métriques arrivent — mais tous ses résolveurs amont échouent, donc
        # plus aucun nom EXTERNE ne se résout.
        #
        # RIEN D'AUTRE NE LE VERRAIT, vérifié cible par cible : les sondes
        # blackbox visent des noms que dnsmasq réécrit vers le LAN, donc elles
        # n'interrogent jamais l'amont ; `CibleInjoignable` regarde des adresses
        # de bouclage ; et les services qui en souffrent — le tunnel qui se
        # reconnecte, Nextcloud qui appelle une API — échouent sans faire tomber
        # leur unité.
        #
        # SUR LE RAPPORT ET NON SUR UN COMPTE, pour deux raisons. Un timeout
        # isolé arrive et ne veut rien dire ; c'est la PROPORTION qui distingue
        # l'incident du réseau de la panne du résolveur. Et un seuil absolu
        # dépendrait du trafic, qui varie du simple au décuple entre la nuit et
        # une journée d'usage.
        #
        # LA MOITIÉ des requêtes en échec est un seuil volontairement haut : la
        # ligne de base mesurée sur cette machine est de ZÉRO échec pour 18 700
        # requêtes amont cumulées. Il ne s'agit donc pas de détecter une
        # dégradation fine, mais de ne pas rater une panne franche.
        #
        # AUCUN FAUX POSITIF LA NUIT, et c'est vérifié plutôt que supposé : sans
        # trafic, la division rend `NaN`, et `NaN > 0.5` ne rend aucune série.
        alert = "ResolutionDnsEnEchec";
        expr = "rate(dnsmasq_servers_queries_failed_total[15m]) / rate(dnsmasq_servers_queries_total[15m]) > 0.5";
        for = "15m";
        labels.severity = "critical";
        # `server` au singulier, relevé sur le /metrics : il porte l'adresse du
        # résolveur amont, `1.1.1.1#53` par exemple. La règle rend une série par
        # résolveur, donc l'alerte nomme celui qui est tombé.
        annotations.summary = "Le résolveur amont {{ $labels.server }} échoue sur {{ $value | printf \"%.0f\" }} % des requêtes : dnsmasq répond toujours, mais plus rien d'externe ne se résout.";
      }
      ++ lib.optional (cfg.apps.nextcloudTokenKey != null) {
        # `nextcloud_up` tombe à 0 dès que l'API refuse l'exporteur, et les deux
        # causes valent d'être signalées : un jeton devenu faux, ou le
        # contournement Authelia qui a cessé de correspondre parce que
        # l'application a déplacé son URL. Aucune des deux ne coupe le service,
        # donc rien d'autre ne le dirait — les panneaux se videraient en
        # silence, ce qui ressemble à une instance au repos.
        alert = "MetriquesNextcloudAveugles";
        expr = "nextcloud_up == 0";
        for = "30m";
        labels.severity = "warning";
        annotations.summary = "L'exporteur Nextcloud n'obtient plus rien de l'API serverinfo : jeton invalide, ou chemin non contourné dans Authelia.";
      };
    }
    ++ lib.singleton {
      name = "meta";
      # CONDITIONNÉE AU DEAD MAN'S SWITCH, seul consommateur qu'elle ait.
      #
      # Elle est toujours en échec par construction, et c'est tout son intérêt :
      # elle ne prévient d'aucun problème, elle PROUVE QUE LA CHAÎNE FONCTIONNE —
      # Prometheus évalue, Alertmanager route, le réseau sort. Alertmanager
      # l'envoie en boucle au tiers ; c'est son ARRÊT qui alerte, hors de cette
      # machine.
      #
      # Sans destinataire, elle n'a plus rien à prouver à personne : elle
      # resterait affichée en permanence dans Alertmanager et dans la source de
      # données Grafana, c'est-à-dire une alerte de fond en face de laquelle on
      # apprend à ne plus regarder. C'est exactement ce qu'une alerte ne doit
      # jamais devenir.
      rules =
        lib.optional cfg.deadManSwitch.enable {
          alert = "Watchdog";
          expr = "vector(1)";
          labels.severity = "none";
          annotations.summary = "Battement de cœur : cette alerte doit être en échec en permanence.";
        }
        ++ [
          {
            # IRONIE ASSUMÉE : si Discord est injoignable, cette alerte part vers
            # Discord. Elle n'a donc de valeur que pour les pannes PARTIELLES —
            # jeton révoqué, salon supprimé, limitation de débit — où le reste
            # passe encore. La panne totale est couverte par le watchdog, pas par
            # elle.
            alert = "AlertmanagerNEnvoiePlus";
            expr = "rate(alertmanager_notifications_failed_total[15m]) > 0";
            for = "15m";
            labels.severity = "critical";
            annotations.summary = "Alertmanager échoue à notifier ({{ $labels.integration }}) : des alertes sont peut-être perdues.";
          }
          {
            # Une règle qui n'arrive plus à s'évaluer ne dit rien, et son silence
            # ressemble à l'absence de problème.
            alert = "EvaluationDeReglesEnEchec";
            expr = "increase(prometheus_rule_evaluation_failures_total[1h]) > 0";
            for = "10m";
            labels.severity = "warning";
            annotations.summary = "Prometheus n'arrive plus à évaluer certaines règles : elles ne protègent plus de rien.";
          }
        ]
        # LA BRIQUE QUI COLLECTE LE JOURNAL, surveillée ici et non dans le
        # groupe `applications` où ces règles vivaient. Ce n'est pas un
        # rangement : elles y étaient conditionnées à `apps.enable`, avec quoi
        # elles n'ont aucun rapport — un host qui active `logs` sans `apps`
        # n'avait donc AUCUNE surveillance de sa collecte de journaux, et rien
        # ne le disait. Vector est de la surveillance, sa place est dans `meta`.
        ++ lib.optionals cfg.logs.enable [
          {
            # LA COLLECTE DE JOURNAUX QUI SE CASSE SANS S'ARRÊTER. Vector actif
            # mais qui rejette ce qu'il lit — Loki qui refuse, un puits saturé,
            # une ligne illisible — laisse l'unité `active` et la cible `up`. Les
            # panneaux se vident lentement, ce qui ressemble à une machine calme.
            #
            # Compteur ABSENT tant qu'aucune erreur n'est survenue, et c'est le
            # comportement voulu : la règle ne s'évalue sur rien et ne peut donc
            # pas déclencher à tort. Elle prend vie au premier incident.
            #
            # Nom relevé sur le `/metrics` de Vector en fonctionnement.
            alert = "CollecteDeJournauxEnErreur";
            expr = "increase(vector_component_errors_total[15m]) > 0";
            for = "10m";
            labels.severity = "warning";
            annotations.summary = "Vector rejette des événements ({{ $labels.component_id }}) : les journaux arrivent incomplets sans que rien ne tombe.";
          }
          {
            # LA MÊME PANNE, DANS SA FORME SILENCIEUSE — et c'est celle que la
            # règle ci-dessus ne peut pas voir. Un rejet PRODUIT une erreur, donc
            # un compteur. Une collecte qui s'arrête n'en produit aucune : rien
            # n'échoue, il n'arrive simplement plus rien.
            #
            # Le cas est nommé deux fois dans ce fichier sans avoir jamais été
            # instrumenté. Il suffit que Vector perde l'accès au journal — c'est
            # exactement le piège que documente le `mkForce` des
            # `SupplementaryGroups` plus bas, où oublier `systemd-journal` laisse
            # « Vector démarrer et se déclarer en bonne santé en ne lisant plus
            # une seule ligne ». L'unité reste `active`, `up` vaut 1, le
            # compteur d'erreurs reste à zéro, et Grafana affiche une page qui
            # fonctionne parfaitement et qui est vide.
            #
            # SIX HEURES, et le seuil ne peut pas être plus court sans risque :
            # la fenêtre doit dépasser le plus long silence NORMAL de la
            # machine. Il n'y en a pas, en pratique — la sonde blackbox tape sur
            # nginx chaque minute et remplit l'access.log en permanence — mais
            # `excludeUnits` peut faire taire une source, et six heures laissent
            # la marge pour ça. Une panne de collecte n'est de toute façon pas
            # urgente à la minute : ce qu'on veut, c'est ne pas la découvrir un
            # mois plus tard en cherchant une ligne qui n'a jamais été écrite.
            #
            # Sur le PUITS et non sur la source : c'est le dernier maillon, celui
            # qui prouve que la ligne est vraiment arrivée chez Loki.
            alert = "CollecteDeJournauxArretee";
            expr = "increase(vector_component_sent_events_total{component_id=\"loki\",component_kind=\"sink\"}[6h]) == 0";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "Vector n'a expédié aucune ligne vers Loki depuis six heures : la page des journaux reste fonctionnelle et vide, ce qui ressemble à une machine calme.";
          }
        ]
        ++ lib.optional lokiRuler {
          # LE MÊME CONTRÔLE, POUR L'AUTRE MOTEUR DE RÈGLES. Celle du dessus ne
          # regarde que Prometheus ; depuis que Loki évalue les siennes — les
          # erreurs ATA du noyau, les rafales sur le coffre et sur SSH, que les
          # métriques ne voient pas — il existe un SECOND endroit où une règle
          # peut cesser de s'évaluer sans que personne ne le sache.
          #
          # Suit `lokiRuler` et non `kernelAlerts` : elle doit exister dès qu'un
          # ruler tourne, quelle que soit la règle qui l'a fait naître.
          #
          # Nom de métrique RELEVÉ sur le `/metrics` de Loki en fonctionnement,
          # pas supposé : `loki_prometheus_rule_evaluation_failures_total`,
          # étiqueté par `rule_group` et par `user`.
          alert = "EvaluationDeReglesLokiEnEchec";
          expr = "increase(loki_prometheus_rule_evaluation_failures_total[1h]) > 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "Loki n'évalue plus ses règles ({{ $labels.rule_group }}) : l'alerte sur les erreurs disque du noyau ne protège plus de rien.";
        };
    };
  };

  # TABLEAU DE BORD écrit à la main plutôt qu'importé.
  #
  # Le réflexe est d'importer « Node Exporter Full » (identifiant 1860), qui est
  # excellent — et qui pèse deux cent mille lignes de JSON produites par une
  # machine. Le poser dans ce dépôt-ci, c'est y verser un artefact que personne
  # ne relira jamais en revue, pour cent quatre-vingts panneaux dont on en
  # regarde six.
  #
  # Celui-ci s'ouvre sur six chiffres — dont un seul réclame une action, le
  # compte d'alertes — puis descend vers ce dont on a besoin quand on cherche
  # pourquoi, section par section : la machine, le stockage, ce qui est publié,
  # les services, les journaux, et pour finir la surveillance elle-même. Chaque
  # panneau porte une DESCRIPTION lisible dans l'interface, cf. `mkDescription` :
  # le raisonnement reste ici, la clé de lecture part là-bas.
  #
  # Il reste possible d'importer 1860 à la main depuis l'interface le jour où
  # l'on creuse quelque chose de précis — il vivra alors dans l'état de Grafana,
  # pas ici.
  promDs = {
    type = "prometheus";
    uid = "prometheus";
  };

  lokiDs = {
    type = "loki";
    uid = "loki";
  };

  # Panneau de JOURNAL, à ne pas confondre avec un panneau de courbes qui
  # tracerait un volume de journal. Son schéma d'options n'a rien de commun avec
  # celui de `mkTs` — pas de `fieldConfig`, pas d'axes, pas de légende — d'où un
  # constructeur à lui plutôt qu'un paramètre de plus sur l'autre.
  #
  # À LAISSER SEUL DANS SA BANDE, la largeur venant désormais de la disposition :
  # une ligne de journal fait couramment cent cinquante caractères, et la couper
  # en deux colonnes la rend illisible sans rien gagner. Lui donner un voisin
  # n'échouerait pas, ça produirait un panneau inutilisable.
  mkLogs =
    {
      id,
      title,
      expr,
      # Une phrase affichée sous le « ⓘ » du panneau, cf. `mkDescription`.
      description ? null,
      h ? 12,
    }:
    {
      inherit id title h;
      type = "logs";
      datasource = lokiDs;
      options = {
        # L'horodatage est la raison d'être du panneau : c'est lui qui permet de
        # recoller une ligne à un décrochage vu sur une courbe au-dessus.
        showTime = true;

        # Les étiquettes RESTENT masquées dans la liste, et se dépliENT ligne par
        # ligne (`enableLogDetails`). Affichées en permanence, elles occupent la
        # moitié de la largeur avec la même valeur répétée cent fois.
        showLabels = false;
        showCommonLabels = false;

        # Le message entier plutôt qu'une ligne tronquée : une trace d'erreur
        # coupée à la largeur du panneau ne sert à rien.
        wrapLogMessage = true;
        prettifyLogMessage = false;

        enableLogDetails = true;
        dedupStrategy = "none";

        # Le plus RÉCENT en haut. L'ordre inverse obligerait à faire défiler
        # jusqu'en bas pour voir ce qui vient de se passer, ce qui est
        # précisément ce qu'on ouvre le panneau pour lire.
        sortOrder = "Descending";
      };
      targets = [
        {
          refId = "1";
          datasource = lokiDs;
          inherit expr;
          queryType = "range";
        }
      ];
    }
    // mkDescription description;

  mkStat =
    {
      id,
      title,
      unit,
      steps,
      # Une phrase affichée sous le « ⓘ » du panneau, cf. `mkDescription`. Elle
      # vaut plus encore sur un chiffre-clé que sur une courbe : la boîte ne
      # porte qu'un nombre et un titre de deux mots, donc tout le reste — sur
      # quoi il est calculé, à partir de quand il faut s'en inquiéter — n'est
      # écrit nulle part dans l'interface.
      description ? null,
      # UNE mesure — le cas de tous les chiffres-clés sauf un.
      expr ? null,
      # PLUSIEURS mesures dans la même boîte, chacune avec son libellé. Grafana
      # les dispose côte à côte dans le panneau, ce qui donne une fiche
      # signalétique plutôt qu'un chiffre isolé.
      #
      # Employé pour le matériel, où trois nombres n'ont de sens qu'ensemble :
      # une machine, ce n'est pas « 4 » ni « 14 Gio », c'est les deux et le
      # disque. Les séparer en trois tuiles occuperait la moitié du bandeau
      # pour dire une seule chose.
      targets ? null,
      # Surcharges par série, nécessaires dès que les mesures d'une même boîte
      # ne partagent pas la même unité : un compte de cœurs à côté d'octets.
      overrides ? [ ],
      # Courbe de fond derrière le chiffre.
      #
      # UTILE quand la valeur bouge — elle donne la tendance sans coûter de
      # place, et c'est tout l'intérêt d'un chiffre-clé sur un tableau de bord.
      # INUTILE sur une CONSTANTE : tracer une droite plate derrière « 4 cœurs »
      # n'apprend rien et remplit la boîte de décor. Le cas se corse quand
      # plusieurs constantes d'ordres de grandeur différents partagent le
      # panneau, où le fond devient franchement trompeur.
      graph ? true,
    }:
    {
      inherit id title;
      type = "stat";
      datasource = promDs;
      # Hauteur seulement : la POSITION est calculée par `placeSections`, cf. le
      # bloc « disposition » plus bas. Un chiffre-clé tient en quatre lignes de
      # grille, moitié moins qu'une courbe.
      h = 4;
      fieldConfig = {
        defaults = {
          inherit unit;
          color.mode = "thresholds";
          thresholds = {
            mode = "absolute";
            inherit steps;
          };
        };
        inherit overrides;
      };
      options = {
        colorMode = "value";
        graphMode = if graph then "area" else "none";
        justifyMode = "auto";
        # `value_and_name` dès qu'il y a plusieurs mesures : sans le nom, trois
        # nombres côte à côte ne disent pas lequel est lequel. Sur une mesure
        # unique le titre du panneau suffit, d'où `auto`.
        textMode = if targets == null then "auto" else "value_and_name";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
      };
      targets =
        if targets == null then
          [
            {
              refId = "A";
              datasource = promDs;
              inherit expr;
            }
          ]
        else
          lib.imap0 (i: t: {
            refId = toString (i + 1);
            datasource = promDs;
            expr = t.expr;
            legendFormat = t.legend;
          }) targets;
    }
    // mkDescription description;

  # CE QUE LA DESCRIPTION RÈGLE, et qui n'était réglé nulle part : tout ce que
  # ce fichier sait d'un panneau est écrit dans ses commentaires Nix, c'est-à-dire
  # à l'endroit exact où personne ne se trouve au moment où la question se pose.
  # Devant une courbe à 3 h du matin, on ne va pas ouvrir le dépôt pour savoir
  # pourquoi les écritures sont tracées vers le bas.
  #
  # Grafana affiche ce texte dans une infobulle sous le « ⓘ » du titre. Une
  # phrase, jamais le commentaire entier : ce qui explique une DÉCISION reste en
  # Nix, à destination de qui modifie ; ce qui explique la LECTURE part dans
  # l'interface, à destination de qui regarde. Les deux publics ne sont pas les
  # mêmes et ne lisent pas au même moment.
  mkDescription = description: lib.optionalAttrs (description != null) { inherit description; };

  mkTs =
    {
      id,
      title,
      targets,
      # Une phrase affichée sous le « ⓘ » du panneau, cf. `mkDescription`.
      description ? null,
      unit ? "short",
      # Hauteur seulement, comme `mkStat` : la position vient de la disposition.
      h ? 8,
      min ? 0,
      fill ? 10,
      stack ? false,
      # Chiffres après la virgule. `null` — le défaut — laisse Grafana décider,
      # ce qui convient partout sauf aux TAUX : `rate()` produit une moyenne,
      # donc une valeur fractionnaire même quand ce qu'on compte est entier par
      # nature. « 24,7 requêtes par minute » est exact et illisible ; poser 0 ici
      # arrondit l'AFFICHAGE sans toucher à la donnée, que l'infobulle montre
      # toujours en entier.
      decimals ? null,
      # Source de données du panneau. Prometheus pour tout le tableau sauf le
      # volume de journal, qui interroge Loki — c'est la SEULE raison d'être de
      # ce paramètre, et son défaut garde les vingt-cinq autres appels intacts.
      ds ? promDs,
      # `bars` pour un décompte d'événements : une courbe lissée entre deux
      # points suggère une continuité qui n'existe pas quand on compte des
      # lignes de journal par intervalle.
      drawStyle ? "line",
      # Loki distingue requête instantanée et requête sur plage, et veut le
      # savoir. Prometheus n'a pas ce champ, d'où l'omission pure quand il est
      # nul plutôt qu'une valeur vide qui embrouillerait le JSON.
      queryType ? null,
      # Expression régulière désignant les séries à TRACER SOUS L'AXE, pour un
      # flux bidirectionnel — lecture au-dessus, écriture en dessous.
      #
      # POURQUOI PAS UN SIGNE MOINS DANS LA REQUÊTE, qui était la méthode
      # employée ici et qui produit le même dessin : parce qu'elle nie la
      # DONNÉE et pas seulement son tracé. La légende et l'infobulle affichent
      # alors « -3,2 Mo/s », ce qui n'existe pas — on n'écrit pas une quantité
      # négative d'octets. Le lecteur doit deviner la convention, et la première
      # question qu'il pose est « pourquoi les écritures sont-elles négatives ? ».
      #
      # `negative-Y` est le réglage que Grafana prévoit pour ça : il retourne le
      # TRACÉ, la valeur reste positive partout où elle est lue. Le miroir n'est
      # plus une astuce de requête, il redevient une propriété d'affichage.
      #
      # À employer avec `min = null`, sans quoi l'axe reste borné à zéro et la
      # moitié inférieure du graphique n'existe pas.
      mirror ? null,
      # Surcharges Grafana supplémentaires, par série. Une surcharge est un
      # couple { matcher, properties } : elle désigne des séries par nom et leur
      # applique des réglages que le panneau porte globalement.
      #
      # C'est le seul moyen de tenir deux exigences contradictoires dans un même
      # panneau — une série en octets à côté de séries en pourcents, ou une
      # référence constante qui ne doit pas se lire comme une mesure. Sans elles,
      # la réponse serait toujours « un panneau de plus », ce qui n'est pas
      # toujours la bonne.
      overrides ? [ ],
      # Borne HAUTE de l'axe. Nulle par défaut — Grafana s'ajuste à la donnée,
      # ce qui est le bon comportement pour une grandeur sans plafond.
      #
      # À POSER SUR LES POURCENTAGES, où l'ajustement automatique est franchement
      # trompeur : un disque occupé entre 61,2 et 61,4 % remplit tout le
      # graphique d'une courbe qui monte et descend spectaculairement. On lit une
      # variation de deux dixièmes comme une crise. Borné à 100, le même panneau
      # montre ce qu'il faut voir — une ligne plate très haut, ou très bas.
      max ? null,
      # Calculs affichés à côté de chaque série dans la légende. La liste vide
      # rend la légende en LISTE, c'est-à-dire des noms seuls.
      #
      # Le défaut affiche la dernière valeur et le maximum, et transforme
      # l'usage : sans eux, lire la valeur courante d'une série suppose de
      # survoler la courbe à la souris — donc c'est impossible sur un téléphone,
      # qui est précisément l'appareil qu'on a en main quand une alerte tombe.
      #
      # Le maximum avec, parce que c'est la question qui suit toujours la
      # première : « ça monte à combien, au pire ? ». Il se lit sur la fenêtre
      # affichée, donc il répond pour la période qu'on regarde.
      legendCalcs ? [
        "lastNotNull"
        "max"
      ],
      # Où poser la légende. DÉDUIT et non réglé : une légende qui porte des
      # valeurs va à DROITE, une légende qui ne porte que des noms va en bas.
      #
      # POURQUOI CE N'EST PAS UN GOÛT. Grafana plafonne la hauteur de la légende
      # du BAS à 35 % de celle du panneau, et sa largeur à 60 % quand elle est à
      # droite. Relevé dans le binaire de Grafana 13.0.6 plutôt que supposé :
      #
      #   renderLegend(…) … maxHeight:"35%", maxWidth:"60%"
      #
      # Ce que ça donne en lignes, une ligne de table faisant 22 pixels avec un
      # en-tête de colonnes de même hauteur :
      #
      #   - panneau `h = 8` → 93 pixels de légende → l'en-tête et TROIS séries ;
      #   - panneau `h = 6` → 66 pixels → l'en-tête et DEUX séries.
      #
      # Pile, sans marge. Un nom un peu long qui passe à la ligne suffit à
      # dépasser, et Grafana rend alors la légende défilante : on fait défiler
      # une légende pour lire une valeur, ce qui est exactement ce que la
      # légende en table devait éviter. C'est ce qui se voyait sur « Coffre »
      # (deux séries, `h = 6`) et « nginx » (trois séries, `h = 8`).
      #
      # Aucun réglage ne rattrape ça, et augmenter la hauteur des panneaux
      # reviendrait à allonger le tableau pour loger une légende. À DROITE, en
      # revanche, la légende dispose de toute la hauteur : douze séries à
      # `h = 8`, huit à `h = 6`, là où le panneau le plus fourni du tableau en a
      # huit. Elle prend de la largeur, ce qui est le bon échange — une courbe
      # perd peu à être moins large, elle perd tout à être moins haute.
      #
      # Reste réglable pour un cas particulier, mais le défaut n'est plus à
      # décider panneau par panneau : le compte de séries n'est pas connu à la
      # construction, il dépend de ce que rend la requête, et il grandit tout
      # seul — un pair WireGuard de plus, une sonde de plus, un capteur de plus
      # sur un disque neuf.
      legendPlacement ? (if legendCalcs == [ ] then "bottom" else "right"),
    }:
    {
      inherit id title h;
      type = "timeseries";
      datasource = ds;
      fieldConfig = {
        defaults = {
          inherit
            unit
            min
            max
            decimals
            ;
          color.mode = "palette-classic";
          custom = {
            inherit drawStyle;
            lineWidth = 1;
            fillOpacity = fill;
            showPoints = "never";
            spanNulls = true;
            stacking = {
              mode = if stack then "normal" else "none";
              group = "A";
            };
          };
        };
        overrides =
          lib.optional (mirror != null) {
            matcher = {
              id = "byRegexp";
              options = mirror;
            };
            properties = [
              {
                id = "custom.transform";
                value = "negative-Y";
              }
            ];
          }
          ++ overrides;
      };
      options = {
        legend = {
          # `table` dès qu'il y a des chiffres à porter : le mode `list` les
          # accepte dans le JSON et ne les affiche jamais, ce qui donne un
          # panneau qui a l'air correct et ne montre rien de plus.
          displayMode = if legendCalcs == [ ] then "list" else "table";
          placement = legendPlacement;
          showLegend = true;
          calcs = legendCalcs;
        };
        tooltip = {
          mode = "multi";
          sort = "desc";
        };
      };
      targets = lib.imap0 (
        i: t:
        {
          # `refId` doit seulement être UNIQUE dans le panneau ; les lettres qu'on
          # voit dans l'interface sont une convention, pas une contrainte de
          # format. Une liste de lettres écrite à la main plafonnait à cinq cibles
          # et faisait échouer l'ÉVALUATION DU SYSTÈME à la sixième — une erreur de
          # construction opaque, pour un détail cosmétique. Un compteur n'a pas de
          # borne.
          refId = toString (i + 1);
          datasource = ds;
          expr = t.expr;
          legendFormat = t.legend;
        }
        // lib.optionalAttrs (queryType != null) { inherit queryType; }
      ) targets;
    }
    // mkDescription description;

  # BANDES D'ÉTAT, pour ce qui ne vaut QUE 0 ou 1. Une courbe est le mauvais
  # dessin pour ça, et le panneau des cibles de collecte le montrait bien : vingt
  # séries qui valent toutes 1 se superposent en UNE SEULE ligne, sous laquelle
  # dix-neuf autres sont invisibles. On ne voyait donc pas qu'une cible était
  # tombée — sauf à survoler la seule ligne visible — sur le panneau dont c'est
  # l'unique raison d'être.
  #
  # Le state-timeline donne une bande par série, empilées, vertes ou rouges. La
  # panne se voit sans lire, ce qui est exactement ce qu'on demande à un panneau
  # qu'on croise en faisant défiler.
  #
  # `mergeValues` fusionne les intervalles consécutifs de même valeur : sans lui,
  # chaque point de collecte devient un rectangle et la bande ressemble à un
  # code-barres.
  mkStates =
    {
      id,
      title,
      targets,
      description ? null,
      h ? 10,
      # Ce que valent 0 et 1 en toutes lettres. Les mêmes deux mots partout
      # seraient plus courts et moins justes : « hors service » convient à une
      # cible de collecte, pas à une unité systemd.
      labels ? {
        "0" = "hors service";
        "1" = "en service";
      },
    }:
    {
      inherit id title h;
      type = "state-timeline";
      datasource = promDs;
      fieldConfig = {
        defaults = {
          color.mode = "thresholds";
          thresholds = {
            mode = "absolute";
            steps = [
              {
                color = "red";
                value = null;
              }
              {
                color = "green";
                value = 1;
              }
            ];
          };
          custom = {
            lineWidth = 0;
            fillOpacity = 80;
          };
          mappings = [
            {
              type = "value";
              options = lib.mapAttrs (_: text: { inherit text; }) labels;
            }
          ];
        };
        overrides = [ ];
      };
      options = {
        showValue = "never";
        mergeValues = true;
        alignValue = "left";
        rowHeight = 0.9;
        # Le nom de chaque série est déjà écrit à gauche de sa bande : une
        # légende en dessous le répéterait vingt fois pour rien.
        legend = {
          displayMode = "list";
          placement = "bottom";
          showLegend = false;
        };
        tooltip = {
          mode = "single";
          sort = "none";
        };
      };
      targets = lib.imap0 (i: t: {
        refId = toString (i + 1);
        datasource = promDs;
        expr = t.expr;
        legendFormat = t.legend;
      }) targets;
    }
    // mkDescription description;

  # LA LISTE DES ALERTES QUI BRÛLENT, et son absence était le trou le plus
  # étonnant de ce tableau : un module entier consacré à décider qu'il y a un
  # problème, et pas un panneau pour dire lesquels sont en cours. La seule façon
  # de le savoir était d'attendre Discord, ou d'ouvrir Alertmanager — qui n'est
  # publié nulle part, puisque rien n'écoute hors de la boucle locale.
  #
  # DEPUIS PROMETHEUS ET NON DEPUIS ALERTMANAGER, alors que la source de données
  # `Alertmanager` est provisionnée juste à côté : Prometheus publie ses propres
  # alertes actives comme une série ordinaire, `ALERTS`, que n'importe quel
  # panneau sait lire. C'est vérifié sur cette machine plutôt que supposé, et ça
  # évite de dépendre du schéma du panneau `alertlist`, qui bouge d'une version
  # de Grafana à l'autre.
  #
  # Ce qu'on y perd : les alertes SILENCÉES, qui n'existent que côté
  # Alertmanager. Personne ne silence rien ici.
  #
  # `Watchdog` EXCLU, obligatoirement : il brûle en permanence par construction
  # (cf. le groupe `meta`). Le laisser mettrait une ligne rouge perpétuelle en
  # tête du panneau, c'est-à-dire referait exactement ce que le dead man's switch
  # évite déjà avec soin — une alerte de fond devant laquelle on apprend à ne
  # plus regarder.
  mkAlertes =
    { id }:
    {
      inherit id;
      title = "Alertes en cours";
      description = "Les alertes que Prometheus considère comme actives en ce moment, watchdog exclu. Un panneau vide est l'état normal.";
      type = "table";
      datasource = promDs;
      h = 8;
      fieldConfig = {
        defaults = {
          # LE MESSAGE QUI COMPTE, et c'est le même soin qu'ailleurs dans ce
          # fichier : sans lui, Grafana écrit « No data » sur un panneau dont
          # l'état normal est d'être vide. Or « No data » veut dire aussi bien
          # « aucune alerte » que « la source ne répond plus ».
          #
          # Le texte affirme donc que la mesure a bien eu lieu, ce qu'un panneau
          # vide ne dit pas tout seul.
          noValue = "Aucune alerte active.";
          custom.align = "left";
        };
        overrides = [
          {
            matcher = {
              id = "byName";
              options = "Gravité";
            };
            properties = [
              {
                id = "custom.cellOptions";
                value.type = "color-text";
              }
              {
                id = "mappings";
                value = [
                  {
                    type = "value";
                    options = {
                      critical = {
                        text = "critique";
                        color = "red";
                        index = 0;
                      };
                      warning = {
                        text = "avertissement";
                        color = "orange";
                        index = 1;
                      };
                    };
                  }
                ];
              }
            ];
          }
        ];
      };
      options = {
        showHeader = true;
        # Par gravité CROISSANTE, ce qui met « critical » avant « warning » —
        # l'ordre alphabétique tombe juste, pour une fois.
        sortBy = [
          {
            displayName = "Gravité";
            desc = false;
          }
        ];
      };
      targets = [
        {
          refId = "1";
          datasource = promDs;
          expr = ''ALERTS{alertstate="firing", alertname!="Watchdog"}'';
          # `instant` : on veut l'état MAINTENANT, pas son historique. Sans lui,
          # la table reçoit une série temporelle entière et n'affiche qu'une
          # bouillie de points.
          instant = true;
          format = "table";
        }
      ];
      # Les colonnes que Prometheus ajoute et qui ne disent rien ici : l'instant
      # de la mesure, la valeur (toujours 1), le nom de la métrique (toujours
      # `ALERTS`), l'état (toujours `firing` puisqu'il est filtré) et la tâche de
      # collecte. Ce qui reste — le nom de l'alerte, sa gravité, la cible, et les
      # étiquettes propres à chaque règle comme `mountpoint` ou `device` — est
      # exactement ce qu'on lit dans le message Discord.
      transformations = [
        {
          id = "organize";
          options = {
            excludeByName = {
              Time = true;
              Value = true;
              "__name__" = true;
              alertstate = true;
              job = true;
            };
            renameByName = {
              alertname = "Alerte";
              severity = "Gravité";
              instance = "Cible";
            };
          };
        }
      ];
    };

  # ------------------------------------------------------------- disposition
  #
  # LE TABLEAU SE DÉCRIT, SES COORDONNÉES SE CALCULENT. Chaque panneau portait
  # avant son `x` et son `y` écrits à la main, et ça coûtait deux choses dont
  # aucune n'est cosmétique :
  #
  #   - insérer un panneau au milieu obligeait à renuméroter les vingt suivants.
  #     Personne ne le fait, donc tout nouveau panneau s'ajoutait À LA FIN quel
  #     que soit son sujet. C'est ainsi que les trois panneaux de disque avaient
  #     fini à trois endroits différents, séparés par le réseau, les sondes et
  #     les certificats ;
  #   - un `y` dupliqué ne fait RIEN échouer. Grafana superpose simplement les
  #     deux panneaux, ce qui se découvre à l'œil, plus tard, et sur une machine
  #     qu'on regarde justement parce que quelque chose ne va pas.
  #
  # Le tableau est donc une liste de SECTIONS, chacune une liste de BANDES
  # horizontales, chaque bande une liste de panneaux qui se partagent les
  # vingt-quatre colonnes. Réordonner devient déplacer une ligne, et les
  # coordonnées ne peuvent plus se contredire puisque personne ne les écrit.

  # Largeurs d'une bande. La division entière laisse un reste — 24 / 5 = 4, il
  # en reste 4 — qu'on donne au DERNIER panneau : sans ça une bande de cinq
  # laisserait une colonne vide sur la droite.
  bandWidths =
    n:
    let
      w = 24 / n;
      # Colonnes que la division entière laisse (24 / 5 = 4, il en reste 4).
      reste = 24 - w * n;
    in
    # RÉPARTI SUR LES PREMIERS, une colonne chacun, plutôt que donné en bloc au
    # dernier. Une bande de cinq donne ainsi 5-5-5-5-4 au lieu de 4-4-4-4-8, où
    # le dernier panneau faisait le double des autres sans raison.
    lib.genList (i: if i < reste then w + 1 else w) n;

  # Décalages horizontaux cumulés, déduits des largeurs.
  bandOffsets = widths: lib.init (lib.foldl' (acc: w: acc ++ [ (lib.last acc + w) ]) [ 0 ] widths);

  # Hauteur d'une bande : celle de son panneau le plus haut, sinon la bande
  # suivante viendrait le chevaucher.
  bandHeight = lib.foldl' (m: p: if p.h > m then p.h else m) 0;

  # Pose une bande à l'ordonnée donnée. Le `h` que portent les constructeurs
  # migre dans `gridPos` et disparaît du panneau : Grafana ne connaît pas
  # d'attribut `h` à la racine, l'y laisser polluerait le JSON.
  placeBand =
    y: band:
    let
      widths = bandWidths (lib.length band);
      xs = bandOffsets widths;
    in
    lib.imap0 (
      i: p:
      removeAttrs p [ "h" ]
      // {
        gridPos = {
          inherit y;
          inherit (p) h;
          w = lib.elemAt widths i;
          x = lib.elemAt xs i;
        };
      }
    ) band;

  # Empile les sections et rend la liste de panneaux que Grafana attend.
  #
  # UN EN-TÊTE DE SECTION EST UN PANNEAU comme un autre, de type `row` et haut
  # d'une seule ligne de grille. Deux formes selon qu'il est replié ou non, et
  # ce n'est pas un détail de rendu : DÉPLIÉ, ses panneaux sont ses FRÈRES dans
  # la liste principale ; REPLIÉ, ils vivent dans son propre attribut `panels`.
  # Se tromper de forme donne une section vide, sans erreur.
  #
  # Les identifiants des en-têtes partent de 100 pour ne pas entrer en collision
  # avec ceux des panneaux, qui sont écrits à la main.
  placeSections =
    sections:
    (lib.foldl'
      (
        acc: section:
        let
          collapsed = section.collapsed or false;

          # Les bandes de la section, empilées sous son en-tête.
          stacked =
            lib.foldl'
              (a: band: {
                y = a.y + bandHeight band;
                panels = a.panels ++ placeBand a.y band;
              })
              {
                y = acc.y + 1;
                panels = [ ];
              }
              section.bands;

          header = {
            id = 100 + acc.n;
            type = "row";
            inherit (section) title;
            inherit collapsed;
            panels = if collapsed then stacked.panels else [ ];
            gridPos = {
              h = 1;
              w = 24;
              x = 0;
              y = acc.y;
            };
          };
        in
        {
          n = acc.n + 1;
          # Repliée, la section n'occupe que la ligne de son en-tête.
          y = if collapsed then acc.y + 1 else stacked.y;
          panels = acc.panels ++ [ header ] ++ lib.optionals (!collapsed) stacked.panels;
        }
      )
      {
        n = 0;
        y = 0;
        panels = [ ];
      }
      sections
    ).panels;

  dashboard = {
    uid = "think-systeme";
    title = "Système";
    tags = [ "nix" ];
    timezone = "browser";
    schemaVersion = 39;
    editable = true;
    refresh = "1m";
    time = {
      from = "now-12h";
      to = "now";
    };

    # CURSEUR PARTAGÉ ENTRE TOUS LES PANNEAUX (1 = crosshair ; 0 serait aucun
    # partage, 2 partagerait aussi l'infobulle).
    #
    # CE QUE ÇA CHANGE, et c'est le geste qu'on fait le plus souvent devant ce
    # tableau : survoler un pic sur une courbe pose une ligne verticale au même
    # instant sur TOUTES les autres. La question qu'on se pose devant un
    # décrochage est toujours « et les autres, à cette seconde-là ? » — un pic de
    # charge en même temps qu'un pic de disque, un temps de réponse qui monte en
    # même temps que la file PHP. Sans ce réglage, il faut lire trois horloges à
    # la main.
    #
    # `2` a été écarté : l'infobulle partagée ouvre une boîte sur chaque panneau
    # à la fois, ce qui masque les courbes qu'on essaie justement de comparer.
    graphTooltip = 1;

    # LES ALERTES DESSINÉES SUR TOUTES LES COURBES, en bandes verticales.
    #
    # CE QUE ÇA RÉPOND et que rien ne répondait : devant un décrochage, la
    # première question est « est-ce que ça a alerté ? », et la seconde « qu'est-ce
    # qui alertait AU MÊME MOMENT ? ». Les deux demandaient d'ouvrir Alertmanager
    # dans un autre onglet et de recoller deux horloges à la main.
    #
    # Une annotation Prometheus rend une région pour chaque intervalle où la
    # série existe. `ALERTS{alertstate="firing"}` n'existe QUE pendant qu'une
    # alerte brûle : la bande couvre donc exactement sa durée, et son étiquette
    # porte le nom de l'alerte.
    #
    # `Watchdog` exclu pour la même raison que dans le panneau des alertes : il
    # brûle en permanence, donc il peindrait le tableau entier.
    #
    # `enable = false` PAR DÉFAUT, et c'est un vrai choix : les bandes sont utiles
    # quand on enquête et encombrantes quand on regarde une courbe. Grafana pose
    # une case à cocher en haut du tableau, à côté des filtres de journal — on
    # les allume le jour où on en a besoin.
    annotations.list = [
      {
        name = "Alertes";
        datasource = promDs;
        enable = false;
        hide = false;
        iconColor = "red";

        # LA REQUÊTE ÉCRITE DEUX FOIS, ET C'EST DÉLIBÉRÉ. Grafana a déplacé la
        # requête d'annotation de la racine de l'objet (`expr`, la forme
        # historique) vers un sous-objet `target`, et les deux formes se
        # rencontrent encore selon la version et selon que le tableau a été
        # migré ou non.
        #
        # Poser les deux ne coûte qu'une ligne et rend l'annotation indifférente
        # à la version. Se tromper de forme ne produirait aucune erreur : les
        # bandes ne s'afficheraient simplement jamais, et on chercherait
        # longtemps pourquoi une alerte connue ne laisse pas de trace.
        expr = ''ALERTS{alertstate="firing", alertname!="Watchdog"}'';
        target = {
          expr = ''ALERTS{alertstate="firing", alertname!="Watchdog"}'';
          refId = "Anno";
        };
        titleFormat = "{{alertname}}";
        textFormat = "{{severity}} · {{instance}}";
        step = "60s";
      }
    ];

    # RACCOURCIS vers ce qui n'est pas dans le tableau. Aucun des deux n'est
    # atteignable autrement : Prometheus et Alertmanager n'écoutent que sur la
    # boucle locale, et c'est Grafana qui leur sert de façade — mais rien n'y
    # menait, il fallait connaître le chemin.
    links = [
      {
        title = "Explorer";
        type = "link";
        icon = "doc";
        # SANS PARAMÈTRES, délibérément : l'URL qui présélectionne une source et
        # une requête a changé de forme entre les versions de Grafana (`left=`
        # puis `panes=`), et un lien qui ouvre une page d'erreur est pire que pas
        # de lien. Explore s'ouvre sur la dernière source employée.
        url = "/explore";
        targetBlank = false;
        tooltip = "Recherche libre dans Loki et Prometheus, au-delà de ce que ce tableau montre.";
      }
      # PAS DE LIEN VERS ALERTMANAGER, et le retirer est la bonne réponse plutôt
      # que d'en chercher un autre.
      #
      # CE QUI A ÉTÉ ESSAYÉ : `/alerting/groups?alertmanager=Alertmanager`. La
      # page CHARGE — les groupes, les receveurs et le watchdog s'affichent — mais
      # Grafana surimpose « Page not found ». La route existe bel et bien (relevée
      # dans le bundle de Grafana 13.0.6, sous le navId `groups`, titrée « Active
      # notifications ») ; c'est son entrée de NAVIGATION qui n'est pas servie,
      # parce que les pages touchant à un Alertmanager externe demandent des
      # droits que le rôle `Editor` n'a pas. Le chrome ne trouve donc aucune page
      # à nommer et rend son 404 par-dessus un contenu pourtant correct.
      #
      # POURQUOI ON NE MONTE PAS LE RÔLE POUR AUTANT : `auto_assign_org_role`
      # reste à `Editor` pour une raison qui pèse bien plus lourd qu'un lien, et
      # elle est écrite plus bas — un Admin peut AJOUTER UNE SOURCE DE DONNÉES,
      # c'est-à-dire faire émettre à cette machine des requêtes vers l'adresse de
      # son choix, y compris des services de la boucle locale exposés nulle part.
      #
      # CE QU'ON NE PERD PAS : la question « qu'est-ce qui brûle en ce moment »
      # est déjà répondue sans quitter le tableau, par la table « Alertes en
      # cours » de la section Surveillance. Ne restent hors de portée que les
      # silences et le détail du routage, qui se consultent en cas de besoin par
      # un tunnel SSH vers 127.0.0.1:9093.
      #
      # Un lien qui mène à « Page not found » est pire que pas de lien : il use
      # la confiance qu'on accorde aux autres.
    ];

    # FILTRES DE JOURNAL, en haut du tableau.
    #
    # CE QU'ILS REMPLACENT : jusqu'ici, écarter du bruit du panneau des erreurs
    # demandait d'éditer ce fichier, de reconstruire et de redéployer — pour un
    # filtre qu'on voulait souvent essayer une fois et jeter. Ces variables
    # rendent le tri INTERACTIF : on trie en regardant, on ne fige que ce qui
    # mérite de l'être.
    #
    # Elles ne dispensent donc pas des reclassements écrits dans Vector, elles
    # les complètent : ce qui est FAUX à la source — une erreur dbus qui n'en
    # est pas une — se corrige à la source, une bonne fois pour toutes. Ce qui
    # est simplement HORS SUJET du moment se filtre ici.
    #
    # PORTÉE : Grafana n'a pas de filtre par section, une variable vaut pour
    # tout le tableau. Elles ne sont lues que par les deux panneaux de la
    # section « Journaux », d'où le préfixe « Journaux : » sur chaque libellé —
    # sans lui, on croirait qu'elles filtrent aussi les courbes.
    templating.list = lib.optionals cfg.logs.enable [
      {
        # `multi` sans `includeAll` : les quatre gravités sont connues d'avance
        # et tiennent à l'écran. Un « All » n'ajouterait qu'un détour pour
        # revenir à ce que les cases cochées disent déjà.
        #
        # Défaut sur error+warn, c'est-à-dire le panneau tel qu'il était figé
        # avant : le comportement ne change pas tant qu'on ne touche à rien.
        # `hide` ET `skipUrlSync` SONT OBLIGATOIRES, aussi inutiles qu'ils
        # paraissent. Grafana les écrit systématiquement quand il enregistre un
        # tableau, et son schéma les attend : un bloc `templating` incomplet est
        # REJETÉ EN SILENCE — aucune erreur de provisioning, simplement aucune
        # variable. Et sans variable, `${"$"}{unite:regex}` part littéralement
        # dans la requête, qui ne correspond alors à rien.
        #
        # Les deux symptômes n'en font donc qu'un, et c'est trompeur : on cherche
        # pourquoi le graphique est vide alors que la cause est que les filtres
        # n'existent pas. Constaté au premier déploiement.
        name = "gravite";
        label = "Journaux : gravité";
        type = "custom";
        query = "error,warn,info,debug";
        multi = true;
        includeAll = false;
        hide = 0;
        skipUrlSync = false;
        current = {
          text = [
            "error"
            "warn"
          ];
          value = [
            "error"
            "warn"
          ];
        };
        options =
          map
            (v: {
              text = v;
              value = v;
              selected = v == "error" || v == "warn";
            })
            [
              "error"
              "warn"
              "info"
              "debug"
            ];
      }
      {
        # Liste construite à l'exécution depuis Loki : une unité ajoutée au host
        # apparaît sans qu'on touche à ce fichier. `refresh = 1` la recalcule au
        # chargement du tableau.
        #
        # `allValue = ".+"` ET SURTOUT PAS `.*`, qui est le réflexe et que Loki
        # REFUSE :
        #
        #   queries require at least one regexp or equality matcher that does
        #   not have an empty-compatible value
        #
        # Une requête doit comporter au moins un sélecteur incapable de
        # correspondre au vide, sans quoi elle décrirait potentiellement tous
        # les flux de l'instance, y compris ceux dépourvus de l'étiquette.
        # `.*` accepte la chaîne vide, `.+` exige au moins un caractère.
        #
        # Le panneau de lignes y aurait survécu — son `level=~"(error|warn)"`
        # remplit déjà la condition — mais celui du VOLUME n'a que ce
        # sélecteur-ci, et tombait donc en erreur d'analyse. Constaté au
        # déploiement.
        #
        # Choisi plutôt que le `$__all` par défaut, qui produirait la liste
        # complète des 49 unités dans chaque requête là où deux caractères
        # suffisent.
        name = "unite";
        label = "Journaux : unité";
        type = "query";
        datasource = lokiDs;

        # FORME OBJET ET NON LA CHAÎNE `label_values(unit)`. Cette dernière est
        # la syntaxe historique, comprise par le type de source Prometheus ;
        # l'éditeur de variables de Loki attend une requête STRUCTURÉE, et une
        # chaîne le laisse sans valeurs — donc une variable vide, donc une
        # requête qui ne correspond à rien.
        #
        # `type = 1` est l'énumération de Loki pour « valeurs d'une étiquette »
        # (0 étant « noms des étiquettes »). `definition` n'est que le libellé
        # affiché dans l'éditeur.
        query = {
          label = "unit";
          refId = "LokiVariableQueryEditor-VariableQuery";
          stream = "";
          type = 1;
        };
        definition = "label_values(unit)";

        multi = true;
        includeAll = true;
        allValue = ".+";
        refresh = 1;
        regex = "";
        sort = 1;
        hide = 0;
        skipUrlSync = false;
        options = [ ];
        current = {
          text = [ "All" ];
          value = [ "$__all" ];
        };
      }
      {
        # Recherche en plein texte. Vide par défaut, ce qui donne `|= ""` —
        # un filtre qui laisse tout passer, vérifié. C'est ce qui permet de la
        # laisser branchée en permanence sans qu'elle ne gêne.
        #
        # UNE INCLUSION ET NON UNE EXCLUSION, à dessein : un `!= "$var"` vide
        # donnerait `!= ""`, qui exclut TOUTE ligne contenant la chaîne vide,
        # c'est-à-dire toutes. Le panneau se viderait au chargement sans que
        # rien n'explique pourquoi.
        name = "contient";
        label = "Journaux : contient";
        type = "textbox";
        query = "";
        hide = 0;
        skipUrlSync = false;
        options = [
          {
            selected = true;
            text = "";
            value = "";
          }
        ];
        current = {
          text = "";
          value = "";
        };
      }
    ];

    panels = placeSections (
      [
        {
          title = "Vue d'ensemble";
          bands = [
            [
              (mkStat {
                # EN TÊTE DU TABLEAU, avant les quatre mesures de la machine, et
                # ce n'est pas une question de goût : c'est le seul chiffre qui
                # dise si quelque chose RÉCLAME une action. Les autres décrivent
                # un état dont on tire soi-même les conclusions.
                #
                # Il double le panneau détaillé de la section Surveillance, tout
                # en bas, et le doublon est le sujet : personne ne fait défiler
                # jusqu'en bas quand tout a l'air normal. Ici il se voit sans
                # être cherché.
                id = 6;
                title = "Alertes en cours";
                unit = "short";
                description = "Nombre d'alertes actives en ce moment, watchdog exclu. Le détail est dans la section Surveillance, tout en bas.";
                # `or vector(0)` : sans lui, l'absence d'alerte n'est aucune
                # série, donc « No Data » — le message ambigu que ce tableau
                # écarte partout ailleurs. Un zéro affiché dit que la mesure a eu
                # lieu et qu'elle ne trouve rien, ce que le vide ne dit pas.
                expr = ''count(ALERTS{alertstate="firing", alertname!="Watchdog"}) or vector(0)'';
                steps = [
                  {
                    color = "green";
                    value = null;
                  }
                  {
                    color = "red";
                    value = 1;
                  }
                ];
              })
              (mkStat {
                id = 1;
                title = "Processeur";
                unit = "percent";
                description = "Part de temps processeur non oisif, tous cœurs confondus, lissée sur 5 minutes.";
                expr = "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))";
                steps = [
                  {
                    color = "green";
                    value = null;
                  }
                  {
                    color = "orange";
                    value = 70;
                  }
                  {
                    color = "red";
                    value = 90;
                  }
                ];
              })
              (mkStat {
                id = 2;
                title = "RAM utilisée";
                unit = "percent";
                description = "Calculé sur `MemAvailable`, donc sur ce qu'une application pourrait vraiment obtenir : le cache du noyau ne compte pas comme occupé.";
                expr = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)";
                steps = [
                  {
                    color = "green";
                    value = null;
                  }
                  {
                    color = "orange";
                    value = 80;
                  }
                  {
                    color = "red";
                    value = 90;
                  }
                ];
              })
              (mkStat {
                id = 3;
                # « Stockage » et non « Racine » : le chiffre-clé s'adresse au
                # coup d'œil, pas à l'administrateur qui sait ce qu'est `/`. La
                # précision perdue est mince sur cette machine — la racine occupe
                # 457 des 458 Gio du disque, le reste étant `/boot`, qui a son
                # propre suivi dans la section Stockage.
                title = "Stockage utilisé";
                unit = "percent";
                description = "Occupation de la racine, qui est le disque à un gigaoctet près. `/boot` a son propre suivi dans la section Stockage.";
                expr = "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})";
                steps = [
                  {
                    color = "green";
                    value = null;
                  }
                  {
                    color = "orange";
                    value = 85;
                  }
                  {
                    color = "red";
                    value = 95;
                  }
                ];
              })
              (mkStat {
                id = 4;
                title = "Sondes en échec";
                unit = "short";
                description = "Points sondés par une vraie requête HTTP qui ne répondent pas comme attendu. Le détail est dans la section Accès public.";
                expr = "count(probe_success == 0) or vector(0)";
                steps = [
                  {
                    color = "green";
                    value = null;
                  }
                  {
                    color = "red";
                    value = 1;
                  }
                ];
              })
              (mkStat {
                # DES PROPRIÉTÉS DE LA MACHINE, PAS DES SÉRIES TEMPORELLES.
                # Aucune des trois ne bouge jamais sur une machine physique — le
                # seul cas où le compte de cœurs varierait est l'ajout de
                # processeurs à chaud, qui suppose une machine virtuelle, et
                # think n'en est pas une. Un chiffre-clé est exactement la forme
                # qui convient à une valeur qu'on veut connaître sans la suivre.
                #
                # Le compte de cœurs vivait avant dans le panneau `Charge`, tracé
                # en courbe à côté des trois moyennes : une constante dessinée
                # comme une mesure. Il donne ici la clé de lecture de ce panneau,
                # qui est désormais en pourcentage de cette capacité.
                #
                # AUCUN SEUIL, d'où l'unique palier : colorer un nombre de cœurs
                # laisserait croire qu'il existe une bonne et une mauvaise
                # valeur.
                #
                # LES TROIS ENSEMBLE DANS UNE SEULE BOÎTE, parce qu'une machine
                # ne se décrit pas par « 4 » ni par « 14 Gio » mais par les trois
                # à la fois. Les séparer en trois tuiles occuperait la moitié du
                # bandeau pour dire une seule chose, et diluerait les quatre
                # mesures VIVANTES qui l'entourent — celles qui bougent et qu'on
                # vient vraiment surveiller.
                #
                # UNITÉS MÊLÉES, d'où la surcharge : le panneau est en octets
                # pour la RAM et le disque, et le compte de cœurs redevient un
                # nombre nu. Sans elle, Grafana annoncerait « 4 o ».
                id = 5;
                title = "Matériel";
                unit = "bytes";
                description = "Ce que la machine EST, et non ce qu'elle fait : trois constantes, qui donnent l'échelle de lecture des quatre mesures voisines.";
                # Trois constantes : la courbe de fond ne tracerait que des
                # droites plates, sur trois échelles sans rapport.
                graph = false;
                targets = [
                  {
                    expr = "count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
                    legend = "cœurs";
                  }
                  {
                    expr = "node_memory_MemTotal_bytes";
                    legend = "RAM";
                  }
                  {
                    # La racine, qui est le disque à un gigaoctet près sur cette
                    # machine — `/boot` mis à part.
                    expr = "node_filesystem_size_bytes{mountpoint=\"/\"}";
                    legend = "stockage";
                  }
                ];
                overrides = [
                  {
                    matcher = {
                      id = "byName";
                      options = "cœurs";
                    };
                    properties = [
                      {
                        id = "unit";
                        value = "short";
                      }
                    ];
                  }
                ];
                steps = [
                  {
                    color = "text";
                    value = null;
                  }
                ];
              })
            ]
          ];
        }
        {
          title = "Machine";
          bands = [
            [
              (mkTs {
                id = 10;
                title = "Processeur par mode";
                unit = "percentunit";
                description = "Où part le temps processeur. `iowait` qui domine veut dire que la machine attend le disque, pas qu'elle calcule ; `steal` n'existe que sur une machine virtuelle.";
                stack = true;
                fill = 30;
                targets = [
                  {
                    expr = "sum by (mode) (rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) / on() group_left count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
                    legend = "{{ mode }}";
                  }
                ];
              })
              (mkTs {
                id = 11;
                title = "RAM";
                unit = "bytes";
                description = "« utilisée » exclut le cache du noyau. Le swap qui monte est le signal : quelque chose ne tient plus en mémoire.";
                targets = [
                  {
                    expr = "node_memory_MemTotal_bytes";
                    legend = "totale";
                  }
                  {
                    expr = "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes";
                    legend = "utilisée";
                  }
                  {
                    expr = "node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes";
                    legend = "swap";
                  }
                ];
              })
            ]
            [
              (mkTs {
                id = 13;
                # RAPPORTÉE AU NOMBRE DE CŒURS, donc en pourcentage de capacité.
                #
                # La charge brute est un nombre sans échelle : 4 est confortable
                # sur huit cœurs et catastrophique sur un. Le panneau traçait
                # donc le nombre de cœurs à côté, comme repère — une CONSTANTE
                # dessinée en courbe, ce qui la faisait lire comme une grandeur
                # susceptible de varier alors qu'elle ne bouge jamais sur une
                # machine physique.
                #
                # Diviser par les cœurs supprime le problème au lieu de
                # l'habiller : 100 % veut dire « exactement saturé », et il n'y
                # a plus de repère à tracer puisqu'il est devenu l'échelle
                # elle-même. Le nombre de cœurs, lui, a rejoint les chiffres-clés
                # en tête de tableau, qui est sa place — c'est une propriété de
                # la machine, pas une série temporelle.
                #
                # `on()` sans étiquette commune et `group_left` : le compte de
                # cœurs est un scalaire sans étiquette, les charges en ont. Sans
                # ça, PromQL ne sait pas apparier les deux membres et rend un
                # résultat vide — sans erreur.
                #
                # La règle `ChargeElevee` reste écrite en absolu (`> 2 × cœurs`)
                # et n'a pas besoin de changer : son seuil se lit simplement
                # 200 % sur ce graphique.
                title = "Charge processeur";
                unit = "percent";
                description = "Charge système rapportée au nombre de cœurs : 100 % veut dire exactement saturé. L'alerte `ChargeElevee` se lit à 200 %.";
                # PAS de borne haute ici, contrairement aux autres pourcentages :
                # la charge peut légitimement dépasser 100 %, et c'est justement
                # ce qu'on vient voir. Un axe coupé à 100 masquerait la seule
                # information intéressante du panneau.
                targets = [
                  {
                    expr = "100 * node_load1 / on() group_left count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
                    legend = "1 min";
                  }
                  {
                    expr = "100 * node_load5 / on() group_left count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
                    legend = "5 min";
                  }
                  {
                    expr = "100 * node_load15 / on() group_left count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
                    legend = "15 min";
                  }
                ];
              })
              (mkTs {
                # Sur une heure glissante, parce que le compteur brut est cumulatif
                # depuis le démarrage : sa valeur ne dit rien, sa progression dit tout.
                id = 21;
                title = "Processus tués faute de mémoire";
                unit = "short";
                description = "Le noyau tue un processus quand il ne peut plus allouer. Une barre non nulle est toujours un incident, même si la machine a l'air d'aller bien depuis.";
                decimals = 0;
                targets = [
                  {
                    expr = "increase(node_vmstat_oom_kill_total[1h])";
                    legend = "tués sur 1 h";
                  }
                ];
              })
            ]
            [
              (mkTs {
                # LA SATURATION, QUI EST UNE AUTRE QUESTION QUE L'USAGE — et le
                # tableau ne savait y répondre nulle part. Les panneaux voisins
                # disent ce que la machine CONSOMME ; celui-ci dit ce qu'elle
                # ATTEND, c'est-à-dire la seule chose qui explique « c'est lent ».
                #
                # LA PRESSION (PSI), que le noyau calcule et que node_exporter
                # publiait déjà sans que rien ne la lise : la fraction de temps
                # pendant laquelle au moins une tâche est bloquée faute de
                # processeur, de mémoire ou d'entrée-sortie. C'est plus direct
                # que la charge moyenne, qui compte les tâches prêtes sans dire
                # si elles souffrent.
                #
                # L'OCCUPATION DU DISQUE avec, et c'est l'angle mort que ce
                # panneau ferme vraiment. Le panneau `Disque` trace des OCTETS
                # par seconde, or un disque se sature sur des OPÉRATIONS, pas sur
                # un volume : des milliers de petites écritures dispersées le
                # tiennent occupé à 100 % pour un débit dérisoire. C'est
                # exactement ce que produisent les miniatures de Nextcloud et les
                # écritures de PostgreSQL, et le panneau des octets montrait donc
                # une machine au repos pendant que le disque était à genoux.
                #
                # PAS DE BORNE HAUTE, contrairement aux autres pourcentages de ce
                # tableau, et c'est un renversement assumé : ailleurs, le cadrage
                # automatique trompe parce qu'il transforme deux dixièmes de
                # variation en montagne russe. Ici la valeur normale est proche
                # de ZÉRO et c'est le pic qui porte l'information — borner à 100
                # écraserait toutes les courbes sur l'axe et rendrait le panneau
                # illisible précisément quand il devient intéressant.
                # LE TITRE ET LES LÉGENDES DISENT « ATTENTE » ET NON
                # « SATURATION », qui est le nom du phénomène mais pas de la
                # mesure. Première version écrite ici, et la question est tombée
                # aussitôt : un panneau intitulé « Saturation » avec des
                # pourcentages ne dit pas de QUOI ils sont le pourcentage. On lit
                # spontanément « le processeur est saturé à 1,2 % », qui n'a
                # aucun sens.
                #
                # Formulé en TEMPS D'ATTENTE, il n'y a plus d'ambiguïté : 10 %
                # veut dire que pendant un dixième du temps, quelque chose
                # voulait cette ressource et ne l'a pas eue. C'est une grandeur
                # qu'on sait lire sans connaître le PSI.
                id = 44;
                title = "Temps passé à attendre";
                unit = "percent";
                description = "Part du temps pendant laquelle quelque chose attend une ressource au lieu de travailler. 10 % sur la courbe processeur veut dire que pendant 10 % du temps, au moins une tâche voulait le processeur et ne l'a pas obtenu. Zéro est l'état normal. C'est ce qui explique « la machine est lente » quand tous les autres panneaux ont l'air calmes — le processeur peut être à 30 % pendant que tout attend le disque.";
                targets = [
                  {
                    expr = "rate(node_pressure_cpu_waiting_seconds_total[5m]) * 100";
                    legend = "en attente du processeur";
                  }
                  {
                    expr = "rate(node_pressure_io_waiting_seconds_total[5m]) * 100";
                    legend = "en attente du disque";
                  }
                  {
                    expr = "rate(node_pressure_memory_waiting_seconds_total[5m]) * 100";
                    legend = "en attente de mémoire";
                  }
                  {
                    # LA SEULE DES QUATRE QUI NE MESURE PAS UNE ATTENTE : celles
                    # du dessus comptent le temps où des TÂCHES sont bloquées,
                    # celle-ci le temps où le DISQUE travaille. Elle est dans le
                    # même panneau parce qu'elle se lit avec elles — un disque
                    # occupé à 100 % explique une attente d'entrées-sorties —,
                    # et sa légende dit clairement qu'elle parle d'autre chose.
                    expr = "rate(node_disk_io_time_seconds_total[5m]) * 100";
                    legend = "disque {{ device }} occupé";
                  }
                ];
              })
            ]
            [
              (mkTs {
                id = 14;
                title = "Réseau";
                unit = "Bps";
                description = "Débit par interface. L'émission est tracée SOUS l'axe pour lire les deux sens d'un coup d'œil : la valeur reste positive dans la légende et l'infobulle.";
                min = null;
                mirror = "↑ .*";
                targets = [
                  {
                    expr = "rate(node_network_receive_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])";
                    legend = "↓ {{ device }}";
                  }
                  {
                    expr = "rate(node_network_transmit_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])";
                    legend = "↑ {{ device }}";
                  }
                ];
              })
              (mkTs {
                id = 15;
                title = "Disque";
                unit = "Bps";
                description = "Débit par périphérique. L'écriture est tracée sous l'axe, comme l'émission du panneau réseau.";
                min = null;
                mirror = "écriture .*";
                targets = [
                  {
                    expr = "rate(node_disk_read_bytes_total[5m])";
                    legend = "lecture {{ device }}";
                  }
                  {
                    expr = "rate(node_disk_written_bytes_total[5m])";
                    legend = "écriture {{ device }}";
                  }
                ];
              })
            ]
            [
              (mkTs {
                # Processeur, circuit graphique intégré et disque sur le même axe : ce
                # qui informe n'est pas la valeur absolue mais l'ÉCART entre elles et
                # leur dérive commune. Trois courbes qui montent ensemble sur des
                # semaines, c'est de la poussière ou un ventilateur qui faiblit — une
                # panne lente, donc invisible au jour le jour.
                #
                # La jointure sur `node_hwmon_chip_names` sert uniquement à la légende :
                # sans elle les séries s'appellent `pci0000:00_0000:00:18_3`, ce qui
                # n'apprend rien à qui regarde le panneau six mois plus tard.
                #
                # DEUX ALERTES DERRIÈRE CE PANNEAU, contrairement à ce qui était écrit
                # ici tant qu'il n'y en avait aucune : `MachineTropChaude` sur les
                # capteurs de la carte, au seuil que le matériel déclare lui-même, et
                # `DisqueTropChaud` sur le SSD, à un chiffre écrit à la main faute de
                # seuil exposé. Le graphique garde son rôle propre — voir la dérive
                # LENTE, celle qui s'installe sur des semaines et qu'aucun seuil
                # n'attrape avant qu'il soit tard.
                id = 30;
                title = "Températures";
                unit = "celsius";
                description = "Ce qui informe n'est pas la valeur absolue mais l'écart entre les courbes et leur dérive commune : trois qui montent ensemble sur des semaines, c'est de la poussière ou un ventilateur qui faiblit.";
                targets = [
                  {
                    expr = "node_hwmon_temp_celsius * on(chip) group_left(chip_name) node_hwmon_chip_names";
                    legend = "{{ chip_name }}";
                  }
                  {
                    expr = "smartctl_device_temperature{temperature_type=\"current\"}";
                    legend = "disque {{ device }}";
                  }
                  {
                    # LE SEUIL TRACÉ AVEC LA MESURE, seule façon de lire un
                    # graphique de température sans connaître par cœur ce que le
                    # matériel tolère. La surcharge en fait une ligne grise en
                    # pointillés : une RÉFÉRENCE, pas une quatrième mesure qu'on
                    # comparerait aux autres.
                    expr = "0.9 * node_hwmon_temp_crit_celsius";
                    legend = "seuil d'alerte";
                  }
                ];
                overrides = [
                  {
                    matcher = {
                      id = "byName";
                      options = "seuil d'alerte";
                    };
                    properties = [
                      {
                        id = "custom.lineStyle";
                        value = {
                          fill = "dash";
                          dash = [
                            10
                            10
                          ];
                        };
                      }
                      {
                        id = "color";
                        value = {
                          mode = "fixed";
                          fixedColor = "text";
                        };
                      }
                      {
                        id = "custom.fillOpacity";
                        value = 0;
                      }
                      # Nommée dans la légende, tue dans l'infobulle : même
                      # traitement que les références du panneau des certificats.
                      # Une constante n'a rien à dire au survol, mais elle doit
                      # dire son nom quelque part — un trait pointillé anonyme en
                      # travers d'un graphique ne renseigne sur rien.
                      {
                        id = "custom.hideFrom";
                        value = {
                          legend = false;
                          tooltip = true;
                          viz = false;
                        };
                      }
                    ];
                  }
                ];
              })
              (mkTs {
                # `min` explicitement nul est FAUX ici, la dérive allant dans les deux
                # sens : un décalage négatif est aussi fatal aux codes TOTP qu'un
                # positif, et le défaut du helper écrêterait la moitié de la courbe.
                id = 22;
                title = "Dérive d'horloge";
                unit = "s";
                description = "Décalage que NTP est en train de corriger. Au-delà de 50 ms, les codes TOTP d'Authelia commencent à être refusés sans que rien n'explique pourquoi.";
                min = null;
                targets = [
                  {
                    expr = "node_timex_offset_seconds";
                    legend = "décalage";
                  }
                ];
              })
            ]
          ];
        }
        {
          title = "Stockage";
          bands = [
            [
              (mkTs {
                # EN POURCENTAGE ET NON EN OCTETS, et c'est ce panneau-ci qui
                # avait le plus à y gagner.
                #
                # En valeur absolue, `/` occupe 294 Gio et `/boot` moins d'un :
                # trois cent soixante-dix fois moins. La courbe de `/boot`
                # restait donc collée à l'axe, indiscernable de zéro — alors que
                # c'est précisément la partition que ce module dit surveiller.
                # Elle se remplit toute seule, une génération à la fois, et son
                # remplissage casse le rebuild suivant. Le panneau cachait ce
                # pour quoi il existait.
                #
                # Le pourcentage n'est pas qu'un remède d'échelle, c'est la
                # bonne grandeur : la question posée est « est-ce que ça se
                # remplit », qui est proportionnelle. Deux systèmes de fichiers
                # de tailles incomparables deviennent comparables, et les seuils
                # des règles d'alerte — écrits en pourcentage eux aussi — se
                # lisent directement sur le graphique.
                #
                # Ce qu'on abandonne : le nombre de gigaoctets restants, qu'on
                # lit sur le chiffre-clé « Stockage utilisé » en tête de tableau.
                id = 12;
                title = "Espace disque libre";
                unit = "percent";
                description = "En pourcentage, ce qui rend `/` et `/boot` comparables malgré un rapport de 370 entre leurs tailles — et fait lire directement les seuils des alertes, écrits en pourcentage eux aussi.";
                # BORNÉ À 100, sans quoi Grafana cadre sur l'amplitude réelle des
                # données : deux points de variation remplissent alors tout le
                # graphique, et une racine parfaitement stable entre 38,4 et
                # 38,6 % se lit comme une montagne russe. C'est le panneau où
                # l'ajustement automatique trompe le plus, parce qu'ici la
                # question posée — « est-ce que ça se remplit ? » — se juge sur
                # l'échelle entière et pas sur l'écart du moment.
                max = 100;
                targets = [
                  {
                    expr = "100 * node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}";
                    legend = "{{ mountpoint }}";
                  }
                ];
              })
              (mkTs {
                # L'autre façon de remplir un disque, et la plus déroutante : `df`
                # annonce de la place libre pendant que toute écriture échoue. Nextcloud
                # et ses miniatures sont le producteur de petits fichiers de la machine.
                id = 23;
                title = "Inodes libres";
                unit = "short";
                description = "L'autre façon de remplir un disque : `df` annonce de la place pendant que toute écriture échoue. À rapprocher du panneau « Nextcloud : fichiers », qui en est le producteur.";
                targets = [
                  {
                    expr = "node_filesystem_files_free{${fsSelector}}";
                    legend = "{{ mountpoint }}";
                  }
                ];
              })
            ]
          ]
          ++ lib.optional cfg.disks.enable [
            (mkTs {
              id = 18;
              title = "Disques : usure et réserve";
              unit = "percent";
              description = "Endurance d'écriture consommée et blocs de secours restants. Les séries NVMe et ATA cohabitent : celles qui ne correspondent pas au disque branché sont simplement absentes.";
              max = 100;
              targets = [
                {
                  expr = "smartctl_device_percentage_used";
                  legend = "usure {{ device }}";
                }
                {
                  expr = "smartctl_device_available_spare";
                  legend = "réserve {{ device }}";
                }
                # Même grandeur, autre bus : les deux séries NVMe ci-dessus sont vides
                # sur un SATA, celle-ci l'est sur un NVMe. Les garder ensemble évite un
                # panneau à retoucher au prochain changement de disque — cf. le groupe
                # d'alertes `disques` pour le détail de l'attribut 202.
                #
                # Pas de série « réserve » côté ATA : ce disque l'expose bien (attribut
                # 180, blocs de secours restants) mais en NOMBRE DE BLOCS, qui n'a rien
                # à faire dans un panneau en pourcentage. Elle est couverte par alerte
                # plutôt que tracée faussement.
                {
                  expr = "smartctl_device_attribute{attribute_id=\"202\",attribute_value_type=\"raw\"}";
                  legend = "usure {{ device }}";
                }
              ];
            })
          ];
        }
        {
          title = "Accès public";
          bands = [
            [
              (mkTs {
                id = 16;
                title = "Temps de réponse des sondes";
                unit = "s";
                description = "Mesuré depuis le host. ATTENTION : les noms publics sont réécrits par dnsmasq, donc ces sondes tapent sur nginx en direct et ne traversent PAS le tunnel Cloudflare. Elles ne disent rien de la joignabilité depuis internet.";
                # LE NOM D'HÔTE ET NON L'URL ENTIÈRE, et c'est la légende à droite
                # qui l'impose : Grafana lui accorde jusqu'à 60 % de la largeur du
                # panneau, et `https://cloud.vpn.nathanchampagne.com/status.php`
                # fait quarante-huit caractères. Sept lignes de cette longueur
                # prennent toute la place autorisée et laissent au graphique ce
                # qu'il en reste.
                #
                # Le chemin sondé ne se perd pas pour autant : il est écrit dans
                # `blackbox.targets`, à côté du module attendu, et l'infobulle
                # continue de porter l'étiquette `instance` complète. Même
                # traitement que la timeline des cibles de collecte, pour la même
                # raison.
                targets = [
                  {
                    expr = ''label_replace(probe_duration_seconds, "cible", "$1", "instance", "https?://([^/]+).*")'';
                    legend = "{{ cible }}";
                  }
                ];
              })
              (mkTs {
                id = 17;
                title = "Certificats : jours restants";

                # `short` ET SURTOUT PAS `d`, qui semble pourtant l'unité juste
                # puisque ce sont des jours. Les unités de TEMPS de Grafana
                # changent d'échelle toutes seules : 89 jours s'affichent
                # « 12.7 week », et 21 jours « 3 week ». Un panneau qui répond à
                # « combien de jours reste-t-il » se met alors à répondre en
                # semaines, sur des seuils qui sont écrits en jours dans les
                # règles d'alerte.
                #
                # Le nombre nu est la bonne réponse ici, et le titre porte déjà
                # l'unité.
                unit = "short";
                decimals = 0;
                description = "En dents de scie : lego renouvelle à 30 jours restants, donc la courbe redescend de 90 à 30 puis remonte. C'est une dent qui n'est PAS remontée qui doit inquiéter.";
                # Deux lignes de référence plutôt qu'un seul chiffre à retenir :
                # elles disent d'un coup d'œil si la dent en cours est normale ou
                # si le renouvellement a cessé de se faire. Ce sont les seuils
                # exacts des deux alertes sur les certificats, 21 et 7 jours.
                #
                # ELLES RESTENT DANS LA LÉGENDE, et les avoir masquées était une
                # faute : deux traits pointillés apparaissaient en travers du
                # graphique sans que rien nulle part ne dise ce qu'ils étaient.
                # Une référence anonyme n'est pas une référence, c'est une
                # question de plus posée au lecteur. Elles coûtent deux lignes de
                # légende, sur un panneau qui en accueille douze.
                #
                # Masquées de l'INFOBULLE en revanche : ce sont des constantes,
                # les relire à chaque survol n'apprend rien et pousse les sept
                # valeurs utiles vers le bas.
                #
                # COULEUR FIXE ET GRISE, comme la référence du panneau des
                # températures : sans elle, la palette leur attribue deux teintes
                # vives qu'on prend pour des sondes de plus, et elle en prive
                # d'autant les vraies mesures.
                overrides = [
                  {
                    matcher = {
                      id = "byRegexp";
                      options = "seuil .*";
                    };
                    properties = [
                      {
                        id = "custom.lineStyle";
                        value = {
                          fill = "dash";
                          dash = [
                            10
                            10
                          ];
                        };
                      }
                      {
                        id = "custom.fillOpacity";
                        value = 0;
                      }
                      {
                        id = "color";
                        value = {
                          mode = "fixed";
                          fixedColor = "text";
                        };
                      }
                      {
                        id = "custom.hideFrom";
                        value = {
                          legend = false;
                          tooltip = true;
                          viz = false;
                        };
                      }
                    ];
                  }
                ];
                # Nom d'hôte plutôt qu'URL entière, cf. le panneau voisin.
                targets = [
                  {
                    expr = ''label_replace((probe_ssl_earliest_cert_expiry - time()) / 86400, "cible", "$1", "instance", "https?://([^/]+).*")'';
                    legend = "{{ cible }}";
                  }
                  {
                    expr = "21";
                    legend = "seuil d'alerte";
                  }
                  {
                    expr = "7";
                    legend = "seuil critique";
                  }
                ];
              })
            ]
          ]
          # LE TUNNEL, QUI N'AVAIT AUCUN PANNEAU alors que deux alertes en
          # dépendent — dont une critique. C'est le trou le plus net qui restait
          # dans ce tableau : `TunnelCloudflareCoupe` annonce que tout ce qui est
          # publié sur internet est injoignable, et rien dans l'interface ne
          # permettait de voir à quoi ressemblait l'avant. La question qui suit
          # une notification à 3 h du matin est toujours la même — est-ce un
          # décrochage isolé ou une dégradation qui dure depuis une heure —, et
          # c'est une forme de courbe, pas un nombre.
          #
          # DANS « ACCÈS PUBLIC » ET NON DANS « SERVICES », parce que c'est de
          # cela qu'il s'agit, et parce que cette section-ci n'est pas
          # conditionnée à `apps` : le tunnel existe indépendamment des
          # exporteurs applicatifs.
          #
          # Les sondes de la bande du dessus ne le remplacent PAS et c'est écrit
          # juste à côté : elles visent des noms que dnsmasq réécrit vers le LAN,
          # donc elles tapent sur nginx sans jamais traverser l'edge. Ce panneau
          # est la seule vue de ce chemin-là.
          ++ lib.optional (cloudflared.metricsAddress != null) [
            (mkTs {
              id = 37;
              title = "Tunnel Cloudflare : connexions vers l'edge";
              unit = "short";
              description = "cloudflared maintient quatre connexions sortantes. En perdre une n'interrompt rien mais annonce souvent la suite ; zéro veut dire que tout ce qui est publié sur internet est injoignable, alors que le démon tourne et que son unité reste active.";
              # PLUS BAS QUE LES AUTRES, parce qu'il occupe la largeur entière
              # pour une seule série qui vaut 4 en permanence. La hauteur des
              # courbes sert à distinguer des valeurs qui se croisent ; il n'y a
              # rien à démêler ici, seulement une marche à voir quand elle
              # tombe.
              h = 6;
              # `decimals = 0` : on compte des connexions, pas une moyenne.
              decimals = 0;
              # `min = 0` — le défaut — est ici ce qui rend le panneau lisible.
              # Sans borne basse, Grafana cadre sur l'amplitude réelle d'une
              # valeur constante à 4 et dessine une ligne qui semble osciller
              # entre 3,99 et 4,01. Avec le zéro, une chute à 3 se voit
              # immédiatement pour ce qu'elle est : un quart de la redondance.
              targets = [
                {
                  expr = "cloudflared_tunnel_ha_connections";
                  legend = "connexions";
                }
              ];
            })
          ];
        }
      ]
      ++ lib.optional cfg.apps.enable {
        title = "Services";
        bands = [
          [
            (mkTs {
              id = 24;
              title = "nginx : requêtes et connexions";
              unit = "short";
              description = "Les connexions « en attente » sont des connexions gardées ouvertes entre deux requêtes, pas des requêtes en souffrance : leur nombre est normal et suit le trafic.";
              decimals = 0;
              targets = [
                {
                  # Par minute comme le panneau Authelia, et pour la même raison : un
                  # taux par seconde sur cette machine s'affiche en centièmes.
                  expr = "rate(nginx_http_requests_total[5m]) * 60";
                  legend = "requêtes/min";
                }
                {
                  expr = "nginx_connections_active";
                  legend = "connexions actives";
                }
                {
                  expr = "nginx_connections_waiting";
                  legend = "connexions en attente";
                }
              ];
            })
            (mkTs {
              # `listen_queue` EST LE SIGNAL, les deux autres ne sont là que pour le
              # lire : une file qui monte alors que les processus actifs plafonnent
              # veut dire que le pool est au maximum et que les requêtes patientent.
              # C'est la forme exacte que prend « Nextcloud est lent » vu d'ici.
              id = 25;
              title = "PHP-FPM : pool Nextcloud";
              unit = "short";
              description = "La file d'attente est le signal, les deux autres servent à la lire : une file qui monte pendant que les processus actifs plafonnent, c'est la forme exacte que prend « Nextcloud est lent ».";
              decimals = 0;
              targets = [
                {
                  expr = "phpfpm_active_processes";
                  legend = "actifs";
                }
                {
                  expr = "phpfpm_idle_processes";
                  legend = "au repos";
                }
                {
                  expr = "phpfpm_listen_queue";
                  legend = "en file d'attente";
                }
              ];
            })
          ]
          [
            (mkTs {
              # `authelia_authz` et NON `authelia_authn_total` : ce dernier ne compte
              # que les saisies d'identifiants, donc il n'existe pas tant que personne
              # ne s'est connecté depuis le dernier démarrage — un panneau vide la
              # plupart du temps. `authz` compte les DÉCISIONS d'autorisation, à
              # chaque requête, et c'est le flux continu qu'on veut voir. Les
              # connexions proprement dites n'ont donc pas de panneau : le leur
              # resterait vide des semaines entières, ce qui se lit « rien ne se
              # passe » au lieu de « rare par nature ».
              #
              # PAR MINUTE, d'où le `* 60` : `rate()` produit un taux PAR SECONDE, et
              # sur une machine familiale ça donne des valeurs comme 0,41 qu'il faut
              # convertir de tête pour se représenter quoi que ce soit. Le calcul
              # reste fait sur une fenêtre de 5 minutes — c'est le lissage, pas
              # l'unité : une rafale d'une seconde reste visible, simplement étalée.
              #
              # DEUX SÉRIES SEULEMENT, ET C'EST UNE LIMITE DE LA SOURCE. Authelia
              # n'expose sur `authz` que le label `code` — rien sur la règle qui a
              # tranché. Impossible, donc, de distinguer ici une session valide d'un
              # `bypass` (partage public, requête venue du tunnel, chemin serverinfo) :
              # les deux comptent 200. Les légendes le disent plutôt que de laisser
              # croire à une mesure des connexions.
              #
              # CE QUI RESTE EXPLOITABLE malgré ça, et c'est l'essentiel : un `bypass`
              # ne produit JAMAIS de 401. La courbe des renvois au portail est donc
              # pure, et c'est celle qui porte le signal — un mur de 401 sans 200 en
              # regard, c'est soit l'authentification cassée, soit quelqu'un qui
              # insiste depuis l'extérieur.
              id = 26;
              title = "Authelia : requêtes filtrées par minute";
              unit = "short";
              description = "La ligne de base est de 2 refus/min : ce sont les sondes blackbox elles-mêmes, qui reçoivent le 302 qu'elles attendent. L'alerte `PortailRefusEnRafale` se déclenche à 20.";
              decimals = 0;
              targets = [
                {
                  expr = "sum(rate(authelia_authz_total{code=\"200\"}[5m])) * 60";
                  # « bypass » et non « contournement » : c'est le mot qu'emploie
                  # la politique d'Authelia elle-même (`policy: bypass` dans les
                  # règles du profil). Traduire l'un des deux côtés obligerait à
                  # faire le lien de tête entre le panneau et la configuration.
                  #
                  # La légende ne nomme donc que le bypass, alors que ce compteur
                  # additionne aussi les sessions valides — la source ne les
                  # distingue pas, cf. le paragraphe sur les deux séries
                  # ci-dessus. C'est le cas le plus fréquent qui donne son nom à
                  # la courbe, pas la totalité de ce qu'elle contient.
                  legend = "laissées passer (bypass)";
                }
                {
                  expr = "sum(rate(authelia_authz_total{code!=\"200\"}[5m])) * 60";
                  legend = "renvoyées au portail";
                }
              ];
            })
            (mkTs {
              # Le délai depuis la dernière poignée de main, pair par pair, et sous
              # leur NOM plutôt que sous leur clé publique — c'est tout l'objet du
              # fichier de correspondance fabriqué plus haut.
              #
              # Pas d'alerte là-dessus, volontairement : ces pairs sont des téléphones
              # qui se connectent quand ils veulent. Un long silence est normal, et
              # une règle dessus sonnerait chaque nuit. Le panneau sert à répondre à
              # « pourquoi mon téléphone ne passe plus », pas à prévenir.
              id = 27;
              title = "WireGuard : dernier contact des pairs";
              unit = "s";
              description = "Ancienneté de la dernière poignée de main, par pair. Un long silence est NORMAL — ce sont des téléphones. Le panneau sert à répondre à « pourquoi mon téléphone ne passe plus », pas à prévenir.";
              targets = [
                {
                  # L'exporteur publie l'HORODATAGE de la dernière poignée de main,
                  # pas son ancienneté — `wireguard_latest_handshake_delay_seconds`
                  # existe dans le binaire mais n'est pas exposé par cette version. La
                  # soustraction est donc faite ici.
                  # LE `and` N'EST PAS UN FILTRE DE CONFORT, il corrige un
                  # défaut qui rendait ce panneau illisible.
                  #
                  # `wireguard_latest_handshake_seconds` vaut ZÉRO pour un pair
                  # qui ne s'est jamais connecté — ce n'est pas une absence de
                  # mesure, c'est un horodatage nul. La soustraction rend alors
                  # l'heure Unix courante, soit environ 1,79 milliard de
                  # secondes, cinquante-six ans. Deux pairs déclarés et jamais
                  # appairés suffisaient à écraser tous les autres contre l'axe :
                  # celui vu il y a une minute et celui vu il y a trois jours
                  # devenaient la même ligne plate.
                  #
                  # `and (… > 0)` ne garde que les pairs ayant DÉJÀ parlé une
                  # fois. Ce qu'on y perd — savoir qu'un pair n'a jamais
                  # communiqué — n'appartient pas à un graphique d'ancienneté :
                  # c'est une propriété de la configuration, qui se lit dans la
                  # liste des pairs du profil.
                  expr = "(time() - wireguard_latest_handshake_seconds) and (wireguard_latest_handshake_seconds > 0)";
                  legend = "{{ friendly_name }}";
                }
              ];
            })
          ]
        ]
        # LES DEUX EXPORTEURS COLLECTÉS QUE PERSONNE NE REGARDAIT. Postgres,
        # Redis et dnsmasq produisent ensemble plus de mille séries — mesuré —
        # sans qu'un seul panneau ne les affiche, alors que DEUX alertes s'y
        # appuient : `BaseDeDonneesInjoignable` et `MetriquesDnsmasqAbsentes`.
        #
        # C'est la situation exacte que le panneau du coffre décrit pour
        # Vaultwarden : une alerte dit qu'un seuil est franchi, elle ne dit pas à
        # quoi ressemblait l'avant. Collecter sans afficher, c'est payer le
        # stockage d'une mesure et se priver de la lire au seul moment où elle
        # servirait.
        #
        # LA BANDE N'EXISTE QUE SI L'UN DES DEUX EST LÀ, et sa largeur s'ajuste
        # toute seule — un panneau prend les vingt-quatre colonnes, deux les
        # partagent. C'est ce que `placeBand` fait sans qu'on ait à y penser.
        ++ (
          let
            bases = lib.optional (appsOn config.services.postgresql.enable) (mkTs {
              id = 38;
              title = "Bases de données : connexions";
              unit = "short";
              description = "Les deux bases dans le même panneau parce que l'alerte `BaseDeDonneesInjoignable` les couvre ensemble. Postgres plafonne à 100 connexions : c'est la saturation, et non la panne franche, qui se voit ici.";
              decimals = 0;
              targets = [
                {
                  # Sommé plutôt que ventilé par base : le plafond de Postgres
                  # est global, donc c'est le total qui s'en approche. Le détail
                  # par base ne dirait rien de plus sur le risque.
                  expr = "sum(pg_stat_database_numbackends)";
                  legend = "postgres";
                }
                {
                  # Le plafond tracé avec la mesure, seule façon de lire l'une
                  # sans connaître l'autre par cœur. Gris et en pointillés comme
                  # les références des panneaux de températures et de
                  # certificats : c'est un repère, pas une troisième mesure.
                  expr = "pg_settings_max_connections";
                  legend = "plafond postgres";
                }
                {
                  # L'instance d'Authelia, la seule des deux qui soit exportée —
                  # celle de Nextcloud ne l'est pas, et le pourquoi est écrit à
                  # côté de son exporteur : y entrer supposerait de rejoindre le
                  # groupe `nextcloud`, donc d'obtenir la lecture des données.
                  expr = "redis_connected_clients";
                  legend = "redis (authelia)";
                }
              ];
              overrides = [
                {
                  matcher = {
                    id = "byName";
                    options = "plafond postgres";
                  };
                  properties = [
                    {
                      id = "custom.lineStyle";
                      value = {
                        fill = "dash";
                        dash = [
                          10
                          10
                        ];
                      };
                    }
                    {
                      id = "custom.fillOpacity";
                      value = 0;
                    }
                    {
                      id = "color";
                      value = {
                        mode = "fixed";
                        fixedColor = "text";
                      };
                    }
                    {
                      id = "custom.hideFrom";
                      value = {
                        legend = false;
                        tooltip = true;
                        viz = false;
                      };
                    }
                  ];
                }
              ];
            });

            resolveur = lib.optional (appsOn dns.enable) (mkTs {
              id = 39;
              title = "dnsmasq : résolutions par minute";
              unit = "short";
              description = "dnsmasq résout les noms du LAN et du VPN, et le tunnel dépend de lui pour démarrer. Son arrêt casse les noms partout sans faire échouer une seule unité — deux courbes à zéro sont donc un signal, pas un calme.";
              decimals = 0;
              targets = [
                {
                  # PAR MINUTE comme les panneaux nginx et Authelia, et pour la
                  # même raison : un taux par seconde donne 0,34 là où « 20 par
                  # minute » se lit sans conversion mentale.
                  expr = "rate(dnsmasq_hits_total[5m]) * 60";
                  legend = "servies par le cache";
                }
                {
                  # Ce qui est parti chez le résolveur amont. Le RAPPORT entre
                  # les deux courbes est l'information : des ratés qui prennent
                  # le pas sur les succès veulent dire un cache trop petit ou
                  # vidé en boucle.
                  expr = "rate(dnsmasq_misses_total[5m]) * 60";
                  legend = "transmises à l'amont";
                }
              ];
            });
            bande = bases ++ resolveur;
          in
          lib.optional (bande != [ ]) bande
        )
        # LES DEUX SURFACES D'AUTHENTIFICATION DE LA MACHINE, dans la même bande
        # parce qu'elles se lisent ensemble : ce sont les deux seuls endroits où
        # quelqu'un peut essayer d'entrer, et les deux seuls que Prometheus ne
        # peut pas voir — ni Vaultwarden ni sshd n'exposent la moindre métrique.
        # Leur alerte à toutes deux vit dans Loki, pour cette raison exacte.
        #
        # La bande n'existe que si l'un des deux est là, et sa largeur s'ajuste.
        ++ (
          let
            ssh = lib.optional (cfg.logs.enable && config.systemSettings.ssh.enable) (mkTs {
              # LE PENDANT DU PANNEAU DU COFFRE, pour l'autre surface
              # d'authentification de la machine — et la seule alerte critique du
              # fichier qui n'avait aucune vue. `SshTentativesRepetees` se
              # déclenche à dix refus en un quart d'heure et tombait jusqu'ici sans
              # que rien ne montre l'avant.
              #
              # DANS LE JOURNAL, comme le coffre et pour la même raison : sshd
              # n'expose aucune métrique. Ses refus n'existent que sous forme de
              # texte.
              #
              # LES DEUX SENS, et le rapport entre eux est l'information. Mesuré
              # sur trente jours : 79 connexions acceptées et 4 refus, ces derniers
              # dus à un appairage raté. Le port étant décalé, les balayages
              # automatiques qui ne tapent que sur 22 n'arrivent pas jusqu'ici —
              # une rafale de refus veut donc dire que quelqu'un a trouvé le port
              # et insiste, ce qui est un événement et non du bruit de fond.
              id = 43;
              title = "SSH : authentifications";
              unit = "short";
              description = "sshd n'expose aucune métrique : ces barres sont comptées dans le journal. La ligne de base est de deux ou trois connexions par jour. Le port étant décalé, une rafale de refus n'est pas un balayage automatique.";
              h = 6;
              ds = lokiDs;
              queryType = "range";
              drawStyle = "bars";
              decimals = 0;
              # `or vector(0)` sur les deux, exactement comme le panneau du coffre :
              # sans lui, une journée sans connexion ne rend aucune série et Grafana
              # écrit « No Data », qui ne distingue pas « personne ne s'est
              # connecté » de « la source est cassée ».
              targets = [
                {
                  expr = ''sum(count_over_time({unit="sshd.service"} |~ "Accepted (publickey|password)" [$__auto])) or vector(0)'';
                  legend = "acceptées";
                }
                {
                  expr = ''sum(count_over_time({unit="sshd.service"} |~ "Failed password|Invalid user" [$__auto])) or vector(0)'';
                  legend = "refusées";
                }
              ];
            });

            coffre = lib.optional (config.systemSettings.vaultwarden.enable && cfg.logs.enable) (mkTs {
              # LE SEUL PANNEAU DU TABLEAU ALIMENTÉ PAR LE JOURNAL plutôt que par
              # une métrique, et ce n'est pas un choix esthétique : Vaultwarden
              # n'expose AUCUNE métrique — pas de `/metrics`, pas d'exporteur.
              # Prometheus ne peut rien tracer de lui. Ce qu'on sait de ses
              # connexions, on le sait parce qu'il l'écrit.
              #
              # POURQUOI UN GRAPHIQUE ALORS QU'UNE ALERTE EXISTE DÉJÀ : l'alerte
              # dit qu'un seuil est franchi, elle ne dit pas à quoi ressemblait
              # l'avant. Devant une notification à 3 h du matin, la question est
              # « est-ce un coup isolé ou une montée depuis une heure », et c'est
              # une forme de courbe, pas un nombre. Le panneau donne à l'alerte le
              # contexte qui lui manque.
              #
              # `bars` et non une ligne : on compte des événements par intervalle,
              # et une courbe lissée entre deux connexions suggérerait une
              # continuité qui n'existe pas.
              #
              # PEU DE DONNÉES, ET C'EST NORMAL : quelques connexions par jour sur
              # un coffre familial. Le panneau est vide la plupart du temps, et
              # c'est précisément ce qu'on veut y lire — le jour où il ne l'est
              # plus, quelque chose se passe.
              id = 35;
              title = "Coffre : connexions";
              unit = "short";
              description = "Compté dans le JOURNAL : Vaultwarden n'expose aucune métrique. Vide est l'état normal — quelques connexions par jour. Une rafale d'échecs vient forcément d'un appareil appairé au VPN.";
              h = 6;
              ds = lokiDs;
              queryType = "range";
              drawStyle = "bars";
              decimals = 0;
              # `or vector(0)` SUR LES DEUX, ET C'EST LE CŒUR DE CE PANNEAU.
              #
              # Sans lui, une période sans aucune connexion ne rend AUCUNE série,
              # et Grafana affiche « No Data ». Or « No Data » est ambigu : il veut
              # dire aussi bien « personne ne s'est connecté » que « la source est
              # cassée, la requête est fausse, ou Loki ne répond plus ». Sur un
              # panneau dont l'intérêt est justement d'être vide la plupart du
              # temps, c'est le pire message possible — celui devant lequel on ne
              # sait pas s'il faut s'inquiéter.
              #
              # Le repli force une valeur ZÉRO, qui dit quelque chose de précis :
              # « je regarde, et il ne s'est rien passé ». C'est le même procédé
              # que le chiffre-clé « Sondes en échec » plus haut, pour la même
              # raison.
              #
              # Ce n'est pas cosmétique : la différence entre « rien » et « je ne
              # sais pas » est exactement ce que ce module passe son temps à
              # établir ailleurs.
              targets = [
                {
                  expr = ''sum(count_over_time({unit="vaultwarden.service"} |= "(login)" |= "200 OK" [$__auto])) or vector(0)'';
                  legend = "réussies";
                }
                {
                  expr = ''sum(count_over_time({unit="vaultwarden.service"} |= "(login)" |= "400 Bad Request" [$__auto])) or vector(0)'';
                  legend = "échouées";
                }
              ];
            });

            bande = coffre ++ ssh;
          in
          lib.optional (bande != [ ]) bande
        )
        ++ lib.optionals (cfg.apps.nextcloudTokenKey != null) [
          [
            (mkTs {
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
                  # `nextcloud_shares_total` est VENTILÉ par `type` — six séries, une
                  # par mécanisme de partage. Sans le label dans la légende, Grafana
                  # affiche six fois « partages » et le panneau devient illisible.
                  #
                  # Ventilé plutôt que sommé, parce que les types ne disent pas la
                  # même chose : `link` est un partage public, exposé à quiconque
                  # détient l'URL, là où `user` et `group` restent internes. Un total
                  # les confondrait dans un seul chiffre.
                  expr = "nextcloud_shares_total";
                  legend = "partages {{ type }}";
                }
              ];
            })
            (mkTs {
              # SÉPARÉ DES COMPTES, et c'est le second temps d'une correction dont
              # le premier avait déplacé le problème au lieu de le régler.
              #
              # Ce compteur vivait d'abord dans le panneau de stockage, où son
              # unité — un nombre — jurait avec des octets. Il a donc rejoint les
              # comptes, qui sont bien des nombres. Sauf qu'il vaut ~14 000 quand
              # les comptes valent 5 et les partages 0 : les trois séries utiles
              # devenaient une ligne plate collée à l'axe, invisible.
              #
              # L'unité et l'ORDRE DE GRANDEUR sont deux contraintes distinctes, et
              # satisfaire l'une ne dispense pas de l'autre. Deux mesures qui ne se
              # comparent pas font deux panneaux — jamais un second axe, qui
              # inventerait une corrélation entre elles.
              id = 33;
              title = "Nextcloud : fichiers";
              unit = "short";
              description = "Sa PENTE est ce qui compte : c'est le producteur d'inodes de la machine, à rapprocher du panneau « Inodes libres » de la section Stockage.";
              decimals = 0;
              targets = [
                {
                  # Sa PENTE est ce qui compte : c'est le producteur d'inodes de
                  # la machine, à rapprocher du panneau `Inodes libres`.
                  expr = "nextcloud_files_total";
                  legend = "fichiers";
                }
              ];
            })
          ]
          [
            (mkTs {
              # PAS de panneau « mises à jour en attente », qui était le premier
              # réflexe : `nextcloud_apps_updates_available_total` et
              # `nextcloud_system_update_available` existent dans le binaire de
              # l'exporteur mais ne sortent PAS ici — l'API `serverinfo` ne renvoie
              # cette section que si l'application `updatenotification` la remplit.
              # Un panneau sur ces noms restait vide, ce qui ressemble à « rien à
              # mettre à jour » alors que ça veut dire « je ne sais pas ».
              #
              # UNIQUEMENT DES OCTETS ICI, et c'est la raison d'être de ce découpage :
              # l'unité est une propriété du PANNEAU, pas de la série. Mêler un compte
              # de fichiers à des tailles obligeait à choisir « short », qui affiche
              # 4.29e+11 au lieu de 400 Gio — illisible pour les deux. Le compte de
              # fichiers a rejoint le panneau voisin, qui est déjà en `short`.
              #
              # `bytes` comme les autres panneaux de volume du tableau : Grafana y
              # rend des multiples binaires (Kio, Mio, Gio), cohérent avec ce que
              # rapportent le noyau et `df`.
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
            })
            (mkTs {
              # MÊME UNITÉ QUE LE PANNEAU VOISIN, ET POURTANT À PART. Ce sont bien
              # deux volumes en octets, mais l'un vaut 315 Go et l'autre 96 Mo :
              # trois mille fois moins. Tracée à côté de l'espace libre, la base
              # est une ligne confondue avec l'axe, et sa croissance — la seule
              # chose qu'on vient regarder — est invisible.
              #
              # L'unité partagée ne suffit donc pas à justifier un axe partagé.
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
            })
          ]
        ];
      }
      ++ lib.optional cfg.logs.enable {
        title = "Journaux";
        bands = [
          [
            (mkTs {
              id = 31;
              title = "Journal : lignes par gravité";
              description = "Suit les filtres « unité » et « contient » du haut du tableau, mais PAS celui de gravité : ce panneau EST la répartition par gravité, la filtrer masquerait les barres qu'on vient regarder.";
              h = 6;
              ds = lokiDs;
              queryType = "range";
              drawStyle = "bars";
              # Empilé : ce qui intéresse ici est le volume TOTAL et la part
              # d'anormal dedans, pas trois courbes à comparer entre elles.
              stack = true;
              fill = 60;
              # `rate()` produirait des fractions de ligne (cf. la note sur
              # `decimals` plus haut) ; ici on compte des entiers.
              decimals = 0;
              targets = [
                {
                  # `$__auto` cale la fenêtre de comptage sur la largeur d'un pixel du
                  # graphique : les barres restent lisibles qu'on regarde une heure ou
                  # une semaine. Une valeur fixe donnerait soit une forêt de barres
                  # d'un pixel, soit trois blocs.
                  #
                  # `{unit=~".+"}` plutôt qu'un nom d'hôte en dur : Loki exige au moins
                  # un sélecteur qui ne corresponde pas au vide, et `unit` est la seule
                  # étiquette que le transform de normalisation garantit sur CHAQUE
                  # ligne — y compris celles du noyau.
                  # PAS DE FILTRE SUR LA GRAVITÉ ICI, contrairement au panneau
                  # de lignes en dessous : ce panneau EST la répartition par
                  # gravité. La filtrer reviendrait à masquer les barres qu'on
                  # vient regarder. Il suit en revanche l'unité et la recherche,
                  # pour rester d'accord avec le panneau qu'il surplombe.
                  expr = ''sum by (level) (count_over_time({unit=~"${"$"}{unite:regex}"} |= "${"$"}{contient}"[$__auto]))'';
                  legend = "{{level}}";
                }
              ];
            })
          ]
          [
            (mkLogs {
              id = 32;
              title = "Journal : erreurs et avertissements";
              description = "Filtré par les trois variables du haut du tableau. Le journal complet — dont 99,5 % d'`info` — est dans Explore, à un clic.";
              # PAS le journal entier, à dessein. Dix-huit mille lignes par jour dont
              # 99,5 % d'`info` : tout afficher ici reviendrait à ne rien montrer, et
              # le panneau serait celui qu'on arrête de lire. Les deux gravités qui
              # restent font environ cent lignes par jour — une quantité qu'un humain
              # parcourt vraiment.
              #
              # Le reste n'est pas perdu : il est dans Explore, à un clic, et la barre
              # du panneau au-dessus le compte toujours.
              expr = ''{level=~"${"$"}{gravite:regex}", unit=~"${"$"}{unite:regex}"} |= "${"$"}{contient}"'';
            })
          ]
        ];
      }
      ++ [
        {
          title = "Surveillance";

          # DÉPLIÉE, contrairement au choix initial. Le raisonnement d'alors —
          # « on ne la consulte que quand on doute de ce qu'on lit ailleurs » —
          # avait un défaut : une section repliée ne se déplie que si on pense à
          # la déplier, et on n'y pense pas quand tout a l'air normal. Or ces
          # panneaux disent justement si « tout a l'air normal » veut dire
          # quelque chose.
          #
          # Le coût est quelques bandes de plus à faire défiler, tout en bas. Le
          # bénéfice est de les voir en passant, ce qui est la seule façon de
          # remarquer qu'une cible est tombée sans avoir été la chercher.
          collapsed = false;
          bands = [
            # LA LISTE DES ALERTES SEULE DANS SA BANDE, sur toute la largeur. Une
            # ligne y porte le nom de l'alerte, sa gravité, la cible et les
            # étiquettes propres à la règle — la couper en deux colonnes
            # tronquerait la seule chose qu'on vient lire.
            [ (mkAlertes { id = 36; }) ]
            [
              (mkTs {
                # Une SÉRIE PAR UNITÉ, pas un compteur : le nom de l'unité est
                # précisément l'information que l'alerte ne transporte pas, et la forme
                # de la courbe distingue une panne franche d'un clignotement — ce que
                # les faux « Résolu » de nixos-upgrade auraient montré d'un coup d'œil.
                id = 19;
                title = "Unités systemd en échec";
                unit = "short";
                description = "Une série par unité tombée, avec son nom — l'information que l'alerte Discord ne transporte pas. « aucune en échec » à zéro est l'état normal, et dit que la collecte fonctionne.";
                decimals = 0;
                targets = [
                  {
                    # LE NOM DE L'UNITÉ **ET** PAS DE « No Data ». Les deux, et
                    # c'est la seule formulation qui les tienne ensemble.
                    #
                    # Le problème : `… {state="failed"} == 1` ne rend RIEN quand
                    # tout va bien — comportement normal d'un filtre — et Grafana
                    # écrit « No Data ». Or ce message est ambigu, il dit aussi
                    # bien « aucune unité en échec » que « la collecte est morte
                    # ou node_exporter ne répond plus ». Sur un panneau dont
                    # l'état NORMAL est d'être vide, c'est le pire message.
                    #
                    # Un `count(…) or vector(0)` réglerait l'ambiguïté mais
                    # perdrait le nom, qui est justement ce qu'on vient lire.
                    #
                    # D'où `absent()`, qui ne rend une valeur QUE lorsque son
                    # argument n'en rend aucune. Multiplié par zéro et étiqueté
                    # par `label_replace`, il fabrique une série de repli qui
                    # porte un nom lisible — et qui DISPARAÎT dès qu'une vraie
                    # unité tombe, contrairement à un `or vector(0)` qui serait
                    # resté affiché à côté d'elle, en la contredisant.
                    #
                    # Vérifié dans les deux sens : sans échec on lit
                    # « aucune en échec = 0 » ; avec un échec (simulé sur un
                    # sélecteur qui correspond) on lit le nom de l'unité seul.
                    #
                    # ATTENTION à ne pas généraliser ce repli : il vaut pour un
                    # COMPTE D'ÉVÉNEMENTS, où zéro veut dire « rien ne s'est
                    # produit ». Il serait faux sur une jauge d'état — mettre 0
                    # sur un `smartctl_device_percentage_used` absent afficherait
                    # « disque neuf » là où la vérité est « pas mesurable sur ce
                    # disque ».
                    expr = "(node_systemd_unit_state{state=\"failed\"} == 1) or label_replace(absent(node_systemd_unit_state{state=\"failed\"} == 1) * 0, \"name\", \"aucune en échec\", \"\", \"\")";
                    legend = "{{ name }}";
                  }
                ];
              })
              (mkTs {
                # LE JUMEAU DU PANNEAU VOISIN, et les deux ne se recouvrent pas :
                # celui de gauche voit l'état `failed`, celui-ci voit ce qui ne
                # l'atteint jamais. Un service qui plante lentement, une fois par
                # minute, n'épuise jamais son `StartLimitBurst` : il reste
                # `active` en permanence, aucune règle d'état ne le remarque, et
                # les sondes le trouvent debout entre deux morts. Ce compteur est
                # le seul symptôme, et il n'était tracé nulle part — seule
                # l'alerte `ServiceRedemarreEnBoucle` le lisait.
                #
                # LE FILTRE `> 0` N'EST PAS COSMÉTIQUE : la métrique existe pour
                # les 162 unités de la machine, mesuré. Sans lui, le panneau
                # empile 162 séries plates à zéro et la seule qui bouge est
                # introuvable.
                #
                # Le repli par `absent()` est le même procédé que chez le voisin,
                # et pour la même raison : sans lui, l'absence de redémarrage
                # afficherait « No Data », qui veut dire aussi bien « rien n'a
                # redémarré » que « la collecte est morte ».
                id = 40;
                title = "Services qui redémarrent";
                unit = "short";
                description = "Redémarrages par unité sur l'heure écoulée. Un service peut renaître indéfiniment sans jamais passer en échec : c'est la seule vue de ce mode de panne. L'alerte se déclenche au-delà de trois.";
                decimals = 0;
                targets = [
                  {
                    expr = "(increase(node_systemd_service_restart_total[1h]) > 0) or label_replace(absent(increase(node_systemd_service_restart_total[1h]) > 0) * 0, \"name\", \"aucun redémarrage\", \"\", \"\")";
                    legend = "{{ name }}";
                  }
                ];
              })
            ]
            # SEULE DANS SA BANDE, comme la liste des alertes. Vingt-deux bandes
            # portent chacune leur nom à gauche du graphique : sur une demi-
            # largeur, ces noms mangent le tiers du panneau et les plus longs sont
            # tronqués. C'est la même raison qui garde le panneau de journal seul
            # sur sa ligne.
            [
              (mkStates {
                h = 12;
                # `up` par cible : c'est la santé de la COLLECTE elle-même. Une tâche
                # tombée ne rend pas ses métriques fausses, elle les fait disparaître —
                # et un graphe vide ressemble à un graphe calme.
                #
                # EN BANDES ET NON EN COURBES, et le panneau ne montrait à peu près
                # rien avant : vingt-deux séries qui valent toutes 1 se superposent en
                # une seule ligne, sous laquelle vingt et une autres sont cachées. Une
                # cible tombée n'y était visible qu'en survolant la ligne — sur le
                # panneau dont c'est la seule raison d'être.
                #
                # DEUX CIBLES SÉPARÉES, parce que `job` ne suffit pas à nommer une
                # sonde : les sept sondes blackbox partagent deux tâches, donc sept
                # bandes homonymes. Leur `instance` est l'URL complète, trop longue
                # pour l'étiquette d'une bande, d'où le `label_replace` qui n'en garde
                # que le nom d'hôte — vérifié contre Prometheus avant d'être écrit ici.
                id = 20;
                title = "Cibles de collecte";
                description = "Une bande par cible de collecte. Rouge veut dire que Prometheus ne récupère plus ses métriques : les courbes qui en dépendent ne sont pas calmes, elles sont vides.";
                labels = {
                  "0" = "ne répond plus";
                  "1" = "collectée";
                };
                targets = [
                  {
                    expr = ''up{job!~"blackbox.*"}'';
                    legend = "{{ job }}";
                  }
                  {
                    expr = ''label_replace(up{job=~"blackbox.*"}, "cible", "$1", "instance", "https?://([^/]+).*")'';
                    legend = "sonde {{ cible }}";
                  }
                ];
              })
            ]
          ]
          # LA COLLECTE DE JOURNAUX, dernière pièce de la surveillance à n'avoir
          # aucune vue. Deux alertes la couvrent — `CollecteDeJournauxEnErreur` et
          # `CollecteDeJournauxArretee` — et toutes deux tombaient sans que rien
          # ne montre l'avant.
          #
          # CE QU'UN COMPTEUR D'ERREURS NE DIT PAS : le mode de panne réel est
          # une collecte qui S'ARRÊTE, pas une collecte qui échoue. Rien ne
          # signale l'arrêt, il n'arrive simplement plus rien, et la seule façon
          # de le voir est de regarder un débit — c'est-à-dire une courbe.
          #
          # La barre du panneau « lignes par gravité » se viderait aussi, mais
          # elle vit dans la section des journaux, qu'on ouvre pour LIRE des
          # lignes, pas pour se demander si la chaîne fonctionne. Ici, à côté des
          # cibles de collecte, la question posée est la bonne.
          #
          # `h = 6` : une seule série, dont on regarde la présence bien plus que
          # la valeur exacte.
          ++ (
            let
              journaux = lib.optional cfg.logs.enable (mkTs {
                id = 41;
                title = "Journaux expédiés vers Loki";
                unit = "short";
                description = "Lignes que Vector remet à Loki, par minute. C'est le dernier maillon : il prouve que la ligne est vraiment arrivée. Une chute à zéro qui dure est ce que l'alerte `CollecteDeJournauxArretee` attrape au bout de six heures.";
                decimals = 0;
                h = 6;
                targets = [
                  {
                    # Sur le PUITS et non sur la source, comme la règle qui
                    # l'accompagne : c'est ce qui distingue « Vector lit » de
                    # « Loki a reçu ».
                    expr = ''sum(rate(vector_component_sent_events_total{component_id="loki",component_kind="sink"}[5m])) * 60'';
                    legend = "lignes/min";
                  }
                ];
              });

              # LE TIMER QUI CESSE DE SE DÉCLENCHER, dernière alerte du fichier à
              # n'avoir aucune vue — et elle est CRITIQUE. Ce qu'elle surveille
              # est le silence : `nixos-upgrade` qui s'arrête, ce sont les
              # correctifs de sécurité qui cessent d'arriver ; `acme-renew-*` qui
              # s'arrête, ce sont les certificats qui expireront dans trente
              # jours sans un mot.
              #
              # LA COURBE DIT CE QUE L'ALERTE NE DIT PAS, et elle le dit d'un
              # coup d'œil : un timer sain dessine un escalier, l'âge monte
              # jusqu'à vingt-quatre heures puis retombe à zéro. Un timer mort
              # est une droite qui monte et ne redescend plus. La différence se
              # voit avant les quarante-huit heures du seuil.
              #
              # Le `and (… > 0)` est le même garde-fou que sur le panneau
              # WireGuard, et pour la même raison : un timer jamais déclenché
              # depuis le démarrage rapporte zéro, et la soustraction rendrait
              # alors cinquante-six ans, écrasant toutes les autres séries contre
              # l'axe.
              timers = [
                (mkTs {
                  id = 42;
                  title = "Timers : temps depuis le dernier déclenchement";
                  unit = "s";
                  description = "Un escalier qui retombe chaque nuit est le comportement sain. Une droite qui monte sans redescendre veut dire qu'un timer ne se déclenche plus — ce qui ne fait échouer aucune unité et ne produit aucun journal.";
                  h = 6;
                  targets = [
                    {
                      expr = "(time() - node_systemd_timer_last_trigger_seconds{name=~\"nixos-upgrade.timer|acme-.+\"}) and (node_systemd_timer_last_trigger_seconds > 0)";
                      legend = "{{ name }}";
                    }
                    {
                      # Le seuil de l'alerte, en secondes. Tracé comme les
                      # références des certificats et des températures : gris,
                      # pointillé, nommé dans la légende et tu dans l'infobulle.
                      expr = "172800";
                      legend = "seuil d'alerte";
                    }
                  ];
                  overrides = [
                    {
                      matcher = {
                        id = "byName";
                        options = "seuil d'alerte";
                      };
                      properties = [
                        {
                          id = "custom.lineStyle";
                          value = {
                            fill = "dash";
                            dash = [
                              10
                              10
                            ];
                          };
                        }
                        {
                          id = "custom.fillOpacity";
                          value = 0;
                        }
                        {
                          id = "color";
                          value = {
                            mode = "fixed";
                            fixedColor = "text";
                          };
                        }
                        {
                          id = "custom.hideFrom";
                          value = {
                            legend = false;
                            tooltip = true;
                            viz = false;
                          };
                        }
                      ];
                    }
                  ];
                })
              ];
              bande = journaux ++ timers;
            in
            lib.optional (bande != [ ]) bande
          );
        }
      ]
    );
  };

  # Règles d'alerte évaluées par le ruler de Loki.
  #
  # LE SOUS-DOSSIER `fake` N'EST PAS UNE PLAISANTERIE, c'est la seule chose à
  # savoir de ce bloc : le stockage local du ruler range les règles PAR
  # LOCATAIRE, et `fake` est le nom que Loki donne au locataire unique quand
  # `auth_enabled` est faux. Un fichier posé à la racine du répertoire est
  # ignoré EN SILENCE — le ruler démarre, ne charge rien, et ne s'en plaint
  # jamais.
  # LES TROIS GROUPES DE RÈGLES QUE LOKI ÉVALUE, et il faut les nommer ensemble
  # pour voir ce qui suit : le coffre, SSH, et les erreurs disque du noyau.
  #
  # LE RULER EST MONTÉ SI L'UN DES TROIS EXISTE, et non plus sur la seule
  # `kernelAlerts` comme c'était écrit. Le défaut était silencieux et sérieux :
  # couper `kernelAlerts` — une option prévue pour ça — retirait le ruler
  # entier, donc emportait AUSSI les alertes du coffre et de SSH, qui n'ont
  # aucun rapport avec le noyau. Les règles restaient écrites dans le store,
  # personne ne les chargeait, et rien ne le disait.
  #
  # C'est exactement le mode d'échec que ce module passe son temps à traquer
  # ailleurs : une surveillance qui disparaît sans que sa disparition se voie.
  lokiRuler =
    cfg.logs.enable
    && (
      config.systemSettings.vaultwarden.enable
      || config.systemSettings.ssh.enable
      || cfg.logs.kernelAlerts.enable
    );

  lokiRules = pkgs-stable.linkFarm "loki-rules" [
    {
      name = "fake/rules.yaml";
      # JSON, qui est du YAML valide — même procédé que pour les tableaux de
      # bord Grafana et les checks Datadog.
      path = pkgs-stable.writeText "rules.yaml" (
        builtins.toJSON {
          groups =
            lib.optional config.systemSettings.vaultwarden.enable {
              # LE COFFRE-FORT, qui est le service le plus sensible du host et le
              # seul dont Prometheus ne peut RIEN dire : Vaultwarden n'expose
              # aucune métrique — pas de `/metrics`, pas d'exporteur. Vérifié, son
              # port local répond 404 sur ce chemin.
              #
              # Ce qui existe déjà : une sonde blackbox sur `/alive`, qui dit
              # qu'il répond, et le signalement d'échec de son unité. Aucun des
              # deux ne voit ce qui compte vraiment sur un coffre — que quelqu'un
              # essaie d'y entrer.
              #
              # Ce signal-là n'est QUE dans le journal, d'où cette règle. C'est le
              # deuxième et dernier emploi de Loki comme moteur d'alerte, et il
              # obéit au même critère que le premier : ce que les métriques ne
              # peuvent pas voir, faute d'exister.
              name = "coffre";
              interval = "1m";
              rules = [
                {
                  # SUR UNE RAFALE, PAS SUR UN ÉCHEC. Se tromper de mot de passe
                  # est banal — le journal en compte dix-sept depuis l'installation,
                  # étalés sur des jours, et ce sont des fautes de frappe. Alerter
                  # à la première ferait sonner pour rien, donc apprendrait à ne
                  # plus lire.
                  #
                  # Cinq en un quart d'heure ne ressemble plus à une main humaine
                  # qui se trompe. Le seuil est réglé sur cette différence-là.
                  #
                  # CE QUE ÇA VEUT DIRE ICI, et c'est ce qui rend l'alerte grave :
                  # le coffre n'est joignable que depuis trois appareils appairés
                  # au VPN (cf. `vaultwarden.allowedNetworks`). Une rafale ne peut
                  # donc pas venir d'internet — elle vient de CHEZ TOI, d'un de tes
                  # appareils. C'est une alerte sur un appareil compromis, pas sur
                  # un inconnu qui frappe à la porte.
                  alert = "CoffreTentativesRepetees";
                  expr = ''sum(count_over_time({unit="vaultwarden.service"} |= "(login)" |= "400 Bad Request" [15m])) > 5'';
                  labels.severity = "critical";
                  annotations.summary = "{{ $value | printf \"%.0f\" }} échecs de connexion au coffre en 15 min. L'accès étant restreint au VPN, ça vient d'un appareil appairé.";
                }
              ];
            }
            ++ lib.optional config.systemSettings.ssh.enable {
              # SSH, dont AUCUNE métrique ne parle. sshd ne publie rien : ses
              # refus d'authentification n'existent que dans le journal, comme
              # ceux du coffre. Troisième et dernier emploi de Loki comme moteur
              # d'alerte, toujours sur le même critère — ce que les métriques ne
              # peuvent pas voir, faute d'exister.
              name = "acces";
              interval = "1m";
              rules = [
                {
                  # DIX EN UN QUART D'HEURE. Le port est décalé (cf.
                  # `systemSettings.ssh.port`), ce qui écarte les balayages
                  # automatiques qui ne tapent que sur 22 — le journal n'en
                  # compte que huit depuis l'installation, tous dus à un
                  # appairage raté. Une campagne qui trouve CE port-là est donc
                  # un événement, pas du bruit de fond.
                  #
                  # Le seuil reste haut pour absorber une clé mal configurée qui
                  # réessaie : ce qu'on veut attraper est l'insistance, pas
                  # l'erreur ponctuelle.
                  #
                  # Motifs relevés dans le journal réel — `Invalid user … from …`
                  # et `Failed password` — et requête validée contre Loki avant
                  # d'être écrite ici.
                  alert = "SshTentativesRepetees";
                  expr = ''sum(count_over_time({unit="sshd.service"} |~ "Failed password|Invalid user" [15m])) > 10'';
                  labels.severity = "critical";
                  annotations.summary = "{{ $value | printf \"%.0f\" }} refus d'authentification SSH en 15 min sur un port non standard : quelqu'un a trouvé le port et insiste.";
                }
              ];
            }
            # SOUS SON OPTION, comme les deux groupes au-dessus sont sous la
            # leur. Ce groupe était ajouté inconditionnellement, si bien que
            # couper `kernelAlerts` laissait sa règle dans le fichier — sans
            # effet tant que le ruler disparaissait avec, mais faux dès que le
            # ruler cesse d'être conditionné à cette option, ce qui est le cas
            # depuis `lokiRuler`.
            ++ lib.optional cfg.logs.kernelAlerts.enable {
              name = "noyau";
              interval = "1m";
              rules = [
                {
                  # LE TROU QUE CETTE RÈGLE FERME, et il est réel : l'incident
                  # du 19 août 2026 à 17 h 20. La liaison SATA du disque
                  # SYSTÈME est tombée et revenue, une écriture a échoué, et
                  # RIEN n'a alerté. Ni `DisqueSmartEnEchec` — le disque se
                  # déclare sain, et il l'est —, ni `DisqueLiaisonSataDegradee`,
                  # dont la règle est pourtant juste : le compteur CRC n'a pas
                  # bougé, une perte de lien n'étant pas une erreur de
                  # transmission.
                  #
                  # L'événement n'existait QUE dans le journal du noyau. C'est
                  # exactement la classe de panne que ce module existe pour
                  # attraper — celle qui s'annonce avant de détruire — et la
                  # seule que les métriques ne peuvent pas voir, parce qu'un
                  # incident ponctuel ne déplace aucun compteur.
                  #
                  # `unit="noyau"` est l'étiquette que le transform de
                  # normalisation de Vector pose sur les messages sans unité
                  # systemd, le noyau au premier chef.
                  alert = "DisqueErreurAtaNoyau";
                  expr = ''sum(count_over_time({unit="noyau"} |~ `(?i)(exception Emask|SError:|failed command|hard resetting link|I/O error)`[10m])) > 0'';
                  labels.severity = "warning";
                  annotations.summary = "Le noyau signale une erreur de liaison ou de commande sur un disque ({{ $value | printf \"%.0f\" }} ligne(s) en 10 min). Câble ou connecteur SATA — vérifie `journalctl -k | grep -i ata`.";
                }
              ];
            };
        }
      );
    }
  ];

  dashboardsDir = pkgs-stable.linkFarm "grafana-dashboards" [
    {
      name = "systeme.json";
      path = pkgs-stable.writeText "systeme.json" (builtins.toJSON dashboard);
    }
  ];
in
{
  options.systemSettings.monitoring = {
    enable = lib.mkEnableOption "surveillance du host (Prometheus, Alertmanager, Grafana)";

    retention = lib.mkOption {
      type = lib.types.str;
      default = "90d";
      description = ''
        Durée pendant laquelle Prometheus garde les mesures.

        Quatre-vingt-dix jours et non trente : sur ce volume de séries, la
        différence se compte en centaines de mégaoctets, et c'est précisément la
        fenêtre qui permet de répondre à « est-ce que ça a toujours été comme
        ça ? » — la question qu'on se pose vraiment devant une courbe.
      '';
    };

    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        Fréquence de collecte des métriques locales. Les sondes blackbox ont la
        leur, plus lâche : elles ouvrent une vraie connexion TLS.
      '';
    };

    blackbox.targets = lib.mkOption {
      default = { };
      description = ''
        Points sondés DEPUIS l'extérieur des applications, par une vraie requête
        HTTP.

        PIÈGE de cette machine-ci, à connaître avant de choisir une cible : les
        noms publics sont réécrits localement par dnsmasq (cf.
        `systemSettings.dns.overrides`), donc une sonde lancée d'ici tape sur
        nginx en direct et NE TRAVERSE PAS le tunnel Cloudflare. Elle ne dit donc
        rien de la joignabilité depuis internet — seul un tiers peut le dire, et
        c'est encore le rôle de `deadManSwitch`.
      '';
      example = lib.literalExpression ''
        {
          nextcloud = {
            url = "https://cloud.exemple.fr/status.php";
            module = "http_2xx";
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL complète à sonder, schéma compris.";
            };

            module = lib.mkOption {
              type = lib.types.enum [
                "http_2xx"
                "http_authelia"
              ];
              default = "http_2xx";
              description = ''
                Réponse ATTENDUE de la cible.

                `http_2xx` exige un 2xx : à réserver aux points qui répondent
                vraiment quelque chose, donc à un chemin qui ne passe pas par le
                portail — la sonde vérifie alors l'application elle-même.

                `http_authelia` accepte aussi la redirection vers le portail, qui
                est la réponse NORMALE d'un nom protégé sondé depuis le host. Il
                ne prouve que nginx, le certificat et Authelia ; l'application
                derrière peut être à terre sans que ça se voie.
              '';
            };
          };
        }
      );
    };

    disks = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Relève l'état SMART des disques et alerte dessus.

          POURQUOI C'EST À PART du reste des métriques : c'est la seule chose
          surveillée ici dont la défaillance détruit des DONNÉES au lieu
          d'interrompre un service. Un service qui tombe se relance, un disque
          qui meurt ne rend rien.

          Ça ne remplace pas `smartd`, qui tourne déjà (cf.
          modules/system/storage/disks) : celui-ci surveille en continu et sait
          lancer des autotests, ce que l'exporteur ne fait pas. Ça lui donne le
          canal qui lui manque — smartd ne sait notifier que par
          `systembus-notify`, c'est-à-dire une notification de bureau sur une
          machine qui n'a aucune session graphique. Il détecte depuis toujours,
          et personne ne l'entend.

          L'exporteur a besoin de `CAP_SYS_RAWIO` et `CAP_SYS_ADMIN` pour
          interroger les disques, le module amont les lui donne. C'est un
          privilège réel, à mettre en regard de ce qu'il couvre.
        '';
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/dev/nvme0n1" ];
        description = ''
          Disques à interroger. Liste VIDE — le défaut — laisse l'exporteur les
          découvrir seul, ce qui est préférable : un disque ajouté est surveillé
          sans qu'on y pense, alors qu'une liste écrite à la main cesse d'être
          juste au premier changement de matériel, sans rien dire.
        '';
      };
    };

    logs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Collecte le journal de la machine dans Loki et l'expose comme source
          de données de Grafana.

          CE QUE ÇA FERME, et c'est le dernier trou de ce module : tout le reste
          ici mesure des NOMBRES. Une courbe dit qu'une chose a mal tourné, à
          quelle heure et dans quelle proportion — elle ne dit jamais POURQUOI.
          La réponse est dans le journal, et jusqu'ici il fallait ouvrir une
          session SSH pour la lire, c'est-à-dire précisément ce qu'on ne peut
          pas faire depuis un téléphone au moment où l'on reçoit l'alerte.

          Les deux vues vivent alors dans la MÊME interface, derrière le même
          portail, sur le même axe de temps : on repère le décrochage sur la
          courbe, on lit ce que la machine racontait à cette minute-là.

          DEUX BRIQUES, et il faut les distinguer parce qu'elles échouent
          séparément :

            - Vector lit le journal et l'envoie. Il tourne en `DynamicUser`,
              entre dans le groupe `systemd-journal` pour la lecture seule, et
              garde un signet dans /var/lib/vector — un redémarrage reprend donc
              où il s'était arrêté, sans trou ni doublon.
            - Loki stocke et répond aux requêtes. Sur la boucle locale, aucun
              port ouvert, comme Prometheus.

          ALERTER RESTE L'AFFAIRE DE PROMETHEUS : tout ce qui se mesure se
          surveille là-bas, et dédoubler les règles entre deux moteurs
          reviendrait à ne plus savoir lequel a parlé. Loki ne prend que ce que
          les métriques ne peuvent pas voir, faute d'exister — trois règles à ce
          jour, et le critère se vérifie à chaque fois :

            - les rafales d'échecs sur le coffre, Vaultwarden n'exposant AUCUNE
              métrique (suit `vaultwarden.enable`) ;
            - les rafales de refus SSH, sshd n'en exposant pas davantage (suit
              `ssh.enable`) ;
            - les erreurs de disque du noyau, qui ne déplacent aucun compteur
              (suit `kernelAlerts` ci-dessous).

          Chacune suit le service qu'elle regarde, et le ruler de Loki n'est monté
          que si au moins l'une des trois existe.
        '';
      };

      kernelAlerts = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Fait évaluer par Loki une règle sur les erreurs de disque du NOYAU,
            et la route vers Alertmanager comme les autres.

            VRAI PAR DÉFAUT, contrairement à l'usage de ce dépôt, et pour la
            même raison que `proxy.expiryCheck` : c'est la seule surveillance
            d'une classe de panne que rien d'autre ne voit.

            L'ÉVÉNEMENT QUI L'A MOTIVÉE, le 19 août 2026 à 17 h 20 : la liaison
            SATA du disque système est tombée et revenue, une écriture a échoué,
            et aucune alerte n'est partie. `DisqueSmartEnEchec` ne pouvait rien
            dire — le disque est sain, et il l'est vraiment ;
            `DisqueLiaisonSataDegradee` non plus — sa règle est juste, mais le
            compteur CRC n'a pas bougé, une perte de lien n'étant pas une erreur
            de transmission. L'incident n'existait que dans le journal.

            C'est la limite structurelle d'une surveillance par métriques : un
            incident PONCTUEL ne déplace aucun compteur. Il faut lire le texte.

            NE COMMANDE QUE CETTE RÈGLE-CI, et il a fallu le corriger : le ruler
            de Loki entier était conditionné à cette option, si bien que la
            couper emportait aussi les alertes du coffre et de SSH, qui n'ont
            rien à voir avec le noyau. Elles restaient écrites, plus personne ne
            les évaluait, et rien ne le disait.

            CE QUE ÇA N'OUVRE PAS : Loki ne devient pas un second moteur
            d'alerte. Avant d'ajouter une règle ici, la bonne question est de
            savoir si Prometheus
            ne le mesure pas déjà — il le mesure presque toujours.
          '';
        };
      };

      retention = lib.mkOption {
        type = lib.types.str;
        default = "30d";
        description = ''
          Durée pendant laquelle Loki garde les journaux.

          TRENTE JOURS et non quatre-vingt-dix comme `retention` plus haut, et
          l'écart est voulu : une métrique répond à « est-ce que ça a toujours
          été comme ça ? », question qui porte sur des mois. Un journal répond à
          « que s'est-il passé cette nuit-là », question qui porte sur des jours.
          Personne ne relit la ligne de journal d'un incident vieux d'un
          trimestre — on relit la COURBE.

          Le coût n'est pas l'argument, et autant donner les chiffres pour que
          l'augmenter soit une décision informée. MESURÉS sur cette machine le
          20 août 2026, en interrogeant Loki lui-même plutôt qu'en estimant :
          77 000 lignes et 18,5 Mo bruts par jour, soit ~560 Mo par mois avant
          compression. Loki compresse largement, donc passer à `"90d"` coûte de
          l'ordre de quelques centaines de mégaoctets.

          CES CHIFFRES ONT QUADRUPLÉ depuis la mise en service, où ils étaient de
          18 000 lignes et 4 Mo. L'agent Datadog en est la cause à lui seul : il
          écrit 11 Mo par jour, soit 60 % du total. C'est le premier endroit où
          regarder si le volume redevient un sujet, cf. `excludeUnits`.

          CE RÉGLAGE NE SUFFIT PAS SEUL À EFFACER quoi que ce soit : Loki
          n'applique une rétention que si son compacteur tourne avec
          `retention_enabled`. Sans lui, cette valeur est acceptée sans un mot et
          les journaux s'accumulent indéfiniment — panne silencieuse classique
          de Loki. Le module pose les deux ensemble, plus bas.
        '';
      };

      excludeUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "prometheus-blackbox-exporter.service" ];
        description = ''
          Unités dont le journal n'est PAS envoyé, par nom d'unité complet.

          Vide par défaut : on collecte tout. C'est le bon défaut parce qu'une
          ligne écartée ici est une ligne qui n'existera pas le jour où on la
          cherchera, et qu'on ne saura même pas qu'elle a manqué.

          DEUX CANDIDATS MESURÉS SUR CETTE MACHINE le 20 août 2026, si le volume
          devient un sujet — et l'ordre a changé depuis la mise en service, d'où
          les chiffres plutôt qu'un souvenir :

            - `datadog-agent.service` : 33 600 lignes et 11 Mo par jour, soit
              60 % du volume total à lui seul. De très loin le premier poste.
            - `prometheus-blackbox-exporter.service` : 5 760 lignes par jour
              (7 %), toutes identiques et toutes NORMALES — ce sont les
              redirections que la sonde `http_authelia` attend et compte comme un
              succès. C'est du bruit au sens strict : du volume qui ne porte
              aucune information.

          Le troisième poste, Grafana, ne se traite PAS ici : son bavardage a été
          coupé à la source en le passant en `log.level = "warn"`, ce qui est
          toujours préférable — une unité écartée ici est écartée y compris le
          jour où elle a quelque chose de vrai à dire.

          À manier avec prudence tout de même. Écarter une unité, c'est se
          priver de son journal y compris le jour où c'est ELLE qui va mal.
        '';
      };
    };

    apps = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Métriques APPLICATIVES : nginx, PHP-FPM, Authelia et WireGuard.

          Ce que ça ajoute par rapport au reste du module, qui ne regarde que la
          MACHINE : node-exporter dira toujours que le processeur va bien
          pendant que Nextcloud met trente secondes à répondre parce que son
          pool PHP est saturé, et les sondes blackbox diront que le portail
          répond 200 pendant qu'il refuse toutes les authentifications.

          Chaque exporteur est activé seulement si le service qu'il observe
          l'est : rien ne démarre pour surveiller ce qui n'existe pas.

          NE COUVRE PAS Nextcloud lui-même (occupation, utilisateurs, version) :
          son exporteur exige un jeton `serverinfo` qui doit être créé à la main
          dans l'instance puis rangé dans les secrets, donc il ne peut pas être
          activé par une simple option. Voir `nextcloud.tokenKey` ci-dessous.
        '';
      };

      nextcloudTokenKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "nextcloud/serverinfo_token";
        description = ''
          Clé sops du jeton `serverinfo` de Nextcloud. `null` — le défaut —
          laisse l'exporteur Nextcloud éteint.

          DEUX GESTES MANUELS, et ils ne peuvent pas être automatisés : le jeton
          est produit par l'instance, il ne peut donc pas venir d'un fichier que
          le déploiement écrirait avant elle.

            nextcloud-occ config:app:set serverinfo token --value "$(openssl rand -hex 32)"
            secrets edit nextcloud/serverinfo_token

          Le jeton donne accès à l'état de l'instance, pas à son contenu — d'où
          ce chemin plutôt que la réutilisation de `nextcloud/admin_pass`, qui
          ferait de l'exporteur un administrateur complet pour afficher trois
          compteurs.
        '';
      };
    };

    grafana = {
      hostName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "metrics.exemple.fr";
        description = ''
          Nom sous lequel Grafana est servi. Il doit être couvert par le domaine
          de session d'Authelia, sinon le cookie du portail ne l'accompagne pas.
        '';
      };

      public = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Publie Grafana par le tunnel, en plus du LAN et du VPN.

          Il n'est jamais servi sans le portail : la protection est posée dès
          qu'Authelia est actif, et une assertion refuse la publication sans lui.
          C'est le point à ne pas relâcher — Grafana en accès libre expose la
          topologie de la machine, ses points de montage et l'état de ses
          services.
        '';
      };
    };

    deadManSwitch = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Envoie un battement de cœur périodique à un service TIERS, qui prévient
          quand il cesse d'arriver.

          C'EST LA SEULE PIÈCE qui couvre la panne dont tout le reste est
          incapable de parler. Prometheus, Alertmanager et Discord tournent tous
          SUR la machine surveillée : si elle s'éteint, si le réseau tombe, si le
          disque passe en lecture seule, le silence qui suit est indiscernable
          d'un fonctionnement normal. Ici c'est l'ABSENCE de signal qui alerte,
          et le juge est ailleurs.

          Le battement porte l'alerte `Watchdog`, toujours en échec par
          construction : il ne s'interrompt donc pas seulement quand la machine
          meurt, mais aussi quand Prometheus n'évalue plus ses règles ou
          qu'Alertmanager ne route plus. Toute la chaîne est prouvée, pas
          seulement la présence de la machine.

          À régler côté tiers : une période un peu plus longue que
          `deadManSwitch.interval`, avec un délai de grâce — sinon un
          redémarrage de rebuild suffit à déclencher une fausse alerte.
        '';
      };

      pingUrlKey = lib.mkOption {
        type = lib.types.str;
        default = "healthchecks/ping_url";
        description = ''
          Clé sops de l'URL de ping, dans les secrets SYSTÈME.

          C'est une URL-capacité : qui la détient peut envoyer le battement à ta
          place, donc maintenir le service en « tout va bien » alors que la
          machine est morte. Elle n'a rien à faire dans ce dépôt, qui est public.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Période entre deux battements.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.grafana.hostName != null;
        message = "systemSettings.monitoring : grafana.hostName est requis, c'est le nom du vhost qui sert l'interface.";
      }
      {
        assertion = authelia.enable;
        message = ''
          systemSettings.monitoring exige systemSettings.authelia.enable.
          Grafana montre la topologie de la machine, ses points de montage et l'état de ses
          services : il n'est servi derrière aucune authentification propre (le formulaire de
          connexion est coupé au profit du portail), donc sans Authelia il serait en accès libre.
        '';
      }
      {
        assertion = proxy.enable;
        message = "systemSettings.monitoring exige systemSettings.proxy.enable (nginx et le certificat du vhost Grafana).";
      }
      {
        assertion = !cfg.grafana.public || cloudflared.enable;
        message = "systemSettings.monitoring.grafana.public exige systemSettings.cloudflared.enable, aucun port n'étant ouvert sur la box.";
      }
      {
        # L'exporteur Nextcloud vise le PREMIER nom supplémentaire, jamais le nom
        # public — sur celui-ci il récolterait la page de connexion du portail.
        # Sans nom supplémentaire, `lib.head` sur une liste vide fait échouer
        # l'évaluation sur « list index 0 is out of bounds », c'est-à-dire un
        # message qui ne nomme ni l'option en cause ni le module. Autant le dire.
        assertion = cfg.apps.nextcloudTokenKey == null || nextcloud.extraHostNames != [ ];
        message = ''
          systemSettings.monitoring.apps.nextcloudTokenKey exige au moins un systemSettings.nextcloud.extraHostNames.
          L'exporteur interroge l'API serverinfo sous le nom INTERNE, celui que la règle de contournement
          d'Authelia laisse passer : sous le nom public il reçoit la page de connexion du portail et échoue
          sur « invalid character '<' », du HTML là où il attend du JSON.
        '';
      }
    ];

    warnings = lib.optional (!cfg.deadManSwitch.enable) ''
      systemSettings.monitoring : aucun dead man's switch sur ce host.
      Prometheus, Alertmanager et le notifieur Discord tournent tous SUR la machine surveillée :
      si elle s'arrête, plus rien n'est envoyé et le silence ressemble exactement à « tout va bien ».
      Active systemSettings.monitoring.deadManSwitch.
    '';

    # ---------------------------------------------------------------- collecte

    services.prometheus = {
      enable = true;
      # Boucle locale : rien n'a besoin de joindre Prometheus depuis le réseau,
      # et son interface d'exploration donne accès à TOUTES les métriques sans
      # la moindre authentification — c'est Grafana, derrière le portail, qui
      # sert de façade.
      listenAddress = "127.0.0.1";
      port = ports.prometheus;
      retentionTime = cfg.retention;

      globalConfig = {
        scrape_interval = cfg.scrapeInterval;
        evaluation_interval = cfg.scrapeInterval;
      };

      rules = [ (builtins.toJSON alertRules) ];

      alertmanagers = [
        { static_configs = localTarget ports.alertmanager; }
      ];

      scrapeConfigs = [
        {
          job_name = "prometheus";
          static_configs = localTarget ports.prometheus;
        }
        {
          job_name = "node";
          static_configs = localTarget ports.node;

          # node_exporter reprend verbatim les noms de `/proc/vmstat`, qui
          # ignorent la convention du suffixe. Cf. `suffixeTotal`.
          metric_relabel_configs = suffixeTotal "node_vmstat_oom_kill";
        }
        {
          # Se surveiller lui-même a un sens précis ici : c'est de ses métriques
          # que vient `AlertmanagerNEnvoiePlus`.
          job_name = "alertmanager";
          static_configs = localTarget ports.alertmanager;
        }
      ]
      ++ lib.optional cfg.disks.enable {
        job_name = "smartctl";
        # L'exporteur ne réinterroge de toute façon pas les disques plus d'une
        # fois par minute (`maxInterval`), et une lecture SMART n'est pas
        # gratuite : la collecter toutes les trente secondes ne ferait que
        # dupliquer la même valeur.
        scrape_interval = "1m";
        static_configs = localTarget ports.smartctl;
      }
      ++ lib.optional (cloudflared.metricsAddress != null) {
        # LE SEUL MOYEN DE VOIR L'ÉTAT DU TUNNEL — cf. la documentation de
        # `systemSettings.cloudflared.metricsAddress`, qui porte le raisonnement
        # et le nom de l'unité à modifier.
        #
        # `up == 0` sur cette tâche attrape le démon qui ne répond plus, et
        # `TunnelCloudflareCoupe` attrape ce qu'il ne voit pas : le démon qui
        # tourne parfaitement sans plus aucun chemin vers l'edge. Le nom de
        # métrique que cette règle emploie a été relevé sur cette page-ci.
        job_name = "cloudflared";
        static_configs = [ { targets = [ cloudflared.metricsAddress ]; } ];
      }
      ++ lib.optional (appsOn proxy.enable) {
        job_name = "nginx";
        static_configs = localTarget ports.nginx;
      }
      ++ lib.optional (appsOn nextcloud.enable) {
        job_name = "php-fpm";
        static_configs = localTarget ports.phpfpm;
      }
      ++ lib.optional (appsOn authelia.enable) {
        job_name = "authelia";
        static_configs = localTarget ports.autheliaMetrics;

        # Authelia publie ses deux compteurs sans le suffixe. Cf. `suffixeTotal`.
        metric_relabel_configs = suffixeTotal "authelia_authz|authelia_request";
      }
      ++ lib.optional (appsOn wireguard.enable) {
        # Une poignée de pairs, une valeur qui ne bouge qu'à la connexion :
        # collecter plus souvent ne dirait rien de plus.
        job_name = "wireguard";
        scrape_interval = "1m";
        static_configs = localTarget ports.wireguardExporter;
      }
      ++ lib.optional (cfg.apps.nextcloudTokenKey != null) {
        # L'exporteur interroge l'API `serverinfo`, qui recompte les fichiers :
        # c'est une opération LOURDE côté instance, à ne pas déclencher toutes
        # les trente secondes.
        job_name = "nextcloud";
        scrape_interval = "5m";
        scrape_timeout = "1m";
        static_configs = localTarget ports.nextcloudExporter;
      }
      ++ lib.optionals cfg.logs.enable [
        # LES DEUX BRIQUES DU JOURNAL, qui n'étaient surveillées par personne le
        # jour où elles ont été ajoutées. `notify.discord` ne couvre que l'unité
        # qui ÉCHOUE ; ces deux cibles couvrent le cas qui manquait, celui du
        # service qui tourne sans plus rien faire — et `CibleInjoignable` s'y
        # applique sans qu'on ait à écrire une règle de plus.
        {
          job_name = "loki";
          static_configs = localTarget ports.loki;
        }
        {
          job_name = "vector";
          static_configs = localTarget ports.vector;
        }
      ]
      ++ lib.optional (appsOn config.services.postgresql.enable) {
        job_name = "postgres";
        static_configs = localTarget ports.postgres;
      }
      ++ lib.optional (appsOn authelia.enable) {
        job_name = "redis";
        static_configs = localTarget ports.redis;
      }
      ++ lib.optional (appsOn dns.enable) {
        job_name = "dnsmasq";
        static_configs = localTarget ports.dnsmasq;

        # QUATRE COMPTEURS DÉCLARÉS EN JAUGE par cet exporteur, et le panneau des
        # résolutions les lit avec `rate()`. Les noms de serveurs amont avec, qui
        # comptent eux aussi des requêtes cumulées : ils ne sont tracés nulle
        # part aujourd'hui, mais les laisser non conformes garantit le retour de
        # l'avertissement le jour où on les tracera.
        #
        # `cachesize`, `leases` et `auth` restent INTACTS : ce sont de vraies
        # jauges, et la première porte une alerte qui la cherche par son nom.
        # Cf. `suffixeTotal` pour le détail.
        metric_relabel_configs = suffixeTotal "dnsmasq_hits|dnsmasq_misses|dnsmasq_insertions|dnsmasq_evictions|dnsmasq_servers_queries|dnsmasq_servers_queries_failed";
      }
      ++ blackboxJobs;
    };

    services.prometheus.exporters.node = localExporter ports.node // {
      # UN SEUL collecteur ajouté, et il est consommé : `systemd` porte à lui
      # seul la règle `UniteSystemdEnEchec`. Il parle à systemd par dbus ; le
      # module amont ouvre AF_UNIX quand il est demandé, sans quoi le service
      # démarrerait en ne rapportant rien.
      #
      # `processes` a été RETIRÉ : il était activé sans qu'aucune règle ni aucun
      # panneau ne lise ce qu'il produit. Un collecteur qu'on allume « au cas
      # où » coûte des séries à stocker et donne l'illusion d'une surveillance
      # qui n'existe pas. À rallumer le jour où une règle en aura besoin.
      #
      # Les autres viennent par défaut : cpu, mémoire, systèmes de fichiers,
      # réseau, disque, vmstat (dont `oom_kill`) et timex (la dérive d'horloge).
      enabledCollectors = [ "systemd" ];

      # COMPTEUR DE REDÉMARRAGES PAR UNITÉ, qui ferme le seul angle mort réel du
      # montage : le service qui redémarre en boucle sans jamais échouer.
      #
      # `Restart = on-failure` avec `StartLimitBurst = 5` — la configuration des
      # conteneurs podman — a un trou précis. Un service qui plante VITE épuise
      # ses cinq tentatives, passe en `failed`, et `UniteSystemdEnEchec`
      # l'attrape. Un service qui plante LENTEMENT, une fois par minute, ne
      # franchit jamais la limite : il redémarre indéfiniment, l'unité reste
      # `active`, et rien ne le voit — ni le signalement d'échec, ni la règle sur
      # l'état, ni les sondes tant que l'application répond entre deux morts.
      #
      # Cette métrique est la seule qui distingue « il tourne » de « il n'arrête
      # pas de renaître ». Nom relevé en lançant l'exporteur avec ce drapeau,
      # pas supposé : `node_systemd_service_restart_total`, étiqueté par `name`.
      extraFlags = [ "--collector.systemd.enable-restarts-metrics" ];
    };

    services.prometheus.exporters.smartctl = lib.mkIf cfg.disks.enable (
      localExporter ports.smartctl // { inherit (cfg.disks) devices; }
    );

    # ------------------------------------------------- exporteurs applicatifs

    # `stub_status` sur un socket À PART, cf. le commentaire des ports : c'est
    # le seul moyen d'obtenir les compteurs de nginx sans toucher au port 80 ni
    # à l'ordre des vhosts. Pas de `enableACME` ni de TLS, l'écoute étant sur la
    # boucle locale et le contenu étant sept entiers sans intérêt pour personne.
    services.nginx.virtualHosts."nginx-status" = lib.mkIf (appsOn proxy.enable) {
      listen = [
        {
          addr = "127.0.0.1";
          port = ports.nginxStatus;
        }
      ];
      locations."/nginx_status".extraConfig = ''
        stub_status on;
        access_log off;
      '';
    };

    services.prometheus.exporters.nginx = lib.mkIf (appsOn proxy.enable) (
      localExporter ports.nginx
      // {
        scrapeUri = "http://127.0.0.1:${toString ports.nginxStatus}/nginx_status";
      }
    );

    # PHP-FPM ne publie son état que si on lui désigne un chemin pour ça ; sans
    # cette ligne l'exporteur démarre et ne trouve rien.
    services.phpfpm.pools.nextcloud.settings."pm.status_path" =
      lib.mkIf (appsOn nextcloud.enable) "/status";

    services.prometheus.exporters.php-fpm = lib.mkIf (appsOn nextcloud.enable) (
      localExporter ports.phpfpm
      // {
        # L'adresse de collecte ne passe que par l'environnement, le module amont
        # n'exposant pas d'option dédiée. Le fichier va dans le store SANS
        # réserve : il ne contient qu'un chemin de socket, aucun secret.
        environmentFile = pkgs-stable.writeText "php-fpm-exporter.env" ''
          PHP_FPM_SCRAPE_URI="unix:///run/phpfpm/nextcloud.sock;/status"
        '';
      }
    );

    # Authelia expose ses propres métriques, sans exporteur intermédiaire : le
    # nombre d'authentifications RÉUSSIES et REFUSÉES, que rien d'autre ne voit.
    # Une sonde blackbox constate que le portail répond, pas qu'il laisse encore
    # entrer quelqu'un.
    services.authelia.instances.main.settings.telemetry.metrics = lib.mkIf (appsOn authelia.enable) {
      enabled = true;
      address = "tcp://127.0.0.1:${toString ports.autheliaMetrics}";
    };

    services.prometheus.exporters.wireguard = lib.mkIf (appsOn wireguard.enable) (
      localExporter ports.wireguardExporter
      // {
        # Sans ça, chaque pair n'apparaît que par sa clé publique : lisible par
        # une machine, inutilisable dans une alerte qu'un humain doit lire à 5 h.
        wireguardConfig = wireguardNames;
      }
    );

    services.prometheus.exporters.nextcloud = lib.mkIf (cfg.apps.nextcloudTokenKey != null) (
      localExporter ports.nextcloudExporter
      // {
        # LE PREMIER NOM SUPPLÉMENTAIRE, jamais `hostName` : le nom public passe
        # par le portail sans exception, l'exporteur y récolte la page de connexion
        # d'Authelia et échoue sur « invalid character '<' » — du HTML là où il
        # attend du JSON. C'est sous le nom interne que vit le contournement, cf.
        # la règle `serverinfo` du profil.
        url = "https://${lib.head nextcloud.extraHostNames}";
        tokenFile = config.sops.secrets.${cfg.apps.nextcloudTokenKey}.path;
      }
    );

    # La base de Nextcloud. Une panne franche se voit déjà par la sonde
    # `status.php`, qui interroge PHP ET la base ; ce que celui-ci ajoute est ce
    # qui PRÉCÈDE la panne — connexions qui saturent, transactions qui traînent,
    # cache qui ne tient plus.
    #
    # `runAsLocalSuperUser` : l'exporteur se connecte par le socket local en
    # `postgres`, donc sans mot de passe à ranger nulle part. C'est un privilège
    # réel — lecture de toutes les vues d'administration — à mettre en regard du
    # fait qu'il ne sort rien de la machine.
    services.prometheus.exporters.postgres = lib.mkIf (appsOn config.services.postgresql.enable) (
      localExporter ports.postgres // { runAsLocalSuperUser = true; }
    );

    # UNE SEULE DES DEUX INSTANCES REDIS, celle d'Authelia, et c'est un choix
    # qu'il faut lire avant de vouloir le compléter.
    #
    # Les deux sockets sont en 660 : les atteindre suppose d'appartenir au groupe
    # propriétaire. Pour Authelia c'est `redis-authelia`, un groupe dédié qui ne
    # possède rien d'autre que l'état de ce Redis — l'y faire entrer n'ouvre
    # rien. Pour Nextcloud c'est le groupe `nextcloud`, celui du service
    # lui-même : y faire entrer un exporteur de métriques lui donnerait accès à
    # tout ce que Nextcloud rend lisible à son groupe, c'est-à-dire aux données.
    #
    # Le rapport coût/bénéfice s'inverse donc entre les deux, pour une mesure de
    # même nature. Ce qu'on perd sur l'instance Nextcloud : la saturation
    # mémoire de son cache, dont l'effet — une instance qui rame — se voit par
    # `PoolPhpSature` et par le temps de réponse de la sonde.
    services.prometheus.exporters.redis = lib.mkIf (appsOn authelia.enable) (
      localExporter ports.redis
      // {
        extraFlags = [ "-redis.addr unix:///run/redis-authelia/redis.sock" ];
      }
    );

    # dnsmasq ne publie pas de page de métriques : l'exporteur lui pose des
    # questions DNS de classe CHAOS (`cachesize.bind`, `hits.bind`…), ce que
    # dnsmasq répond nativement. Vérifié sur cette machine avant d'écrire ces
    # lignes — `dig @127.0.0.1 CHAOS TXT cachesize.bind` rend bien une valeur.
    #
    # CE QUE ÇA COUVRE et que rien d'autre ne voit : dnsmasq est le résolveur de
    # think ET la pièce dont dépend le démarrage du tunnel (cf.
    # modules/system/server/cloudflared). Son arrêt casse les noms internes
    # partout, y compris pour les clients VPN, sans faire échouer une seule
    # unité.
    services.prometheus.exporters.dnsmasq = lib.mkIf (appsOn dns.enable) (
      localExporter ports.dnsmasq
      // {
        # `127.0.0.1` ET NON `localhost`, qui est le défaut du module amont.
        #
        # Constaté à la mise en service, le 19 août 2026 : `localhost` se résout
        # d'abord en `::1`, et dnsmasq n'écoute qu'en IPv4 sur cette machine — ce
        # qui est cohérent, les annonces de routeur IPv6 étant refusées (cf.
        # modules/system/network). L'exporteur échouait donc à chaque collecte :
        #
        #   could not complete scrape: read udp [::1]->[::1]:53: connection refused
        #
        # ET RIEN NE LE DISAIT. L'unité restait `active`, `up` valait 1 puisque
        # l'exporteur répondait bien sur SON port, et il publiait même
        # `dnsmasq_leases 0` — une valeur lue dans le fichier de baux, sans
        # rapport avec le DNS. Seule l'ABSENCE de `dnsmasq_cachesize` trahissait
        # la panne, c'est-à-dire rien qu'on remarque sans aller le chercher.
        dnsmasqListenAddress = "127.0.0.1:53";
      }
    );

    # CONDITIONNÉ À L'EXISTENCE DE CIBLES, et pas seulement par économie.
    #
    # Le point d'entrée `/probe` de cet exporteur prend l'URL à sonder en
    # PARAMÈTRE : quiconque peut lui parler fait émettre à cette machine une
    # requête HTTP vers la destination de son choix. C'est un relais de requêtes
    # en bonne et due forme. Il n'écoute que sur la boucle locale, donc ça
    # suppose déjà un accès à la machine — raison de plus pour ne pas le faire
    # tourner quand aucune sonde n'est déclarée.
    services.prometheus.exporters.blackbox = lib.mkIf (cfg.blackbox.targets != { }) (
      localExporter ports.blackbox // { configFile = blackboxConfig; }
    );

    # --------------------------------------------------------------- alerting

    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.alertmanager;

      configuration = {
        route = {
          receiver = "discord";

          # Regroupement par ALERTE et non par instance : un disque plein
          # déclenche `DisqueBientotPlein` sur plusieurs points de montage à la
          # fois, et c'est un seul message qu'on veut lire.
          group_by = [ "alertname" ];
          group_wait = "30s";
          group_interval = "5m";

          # Douze heures avant de répéter : assez pour qu'une alerte ignorée
          # revienne, assez peu pour qu'elle n'apprenne pas à être ignorée.
          repeat_interval = "12h";

          # Le battement de cœur, qui ne doit RIEN à la logique de regroupement :
          # ni attente, ni espacement, ni la répétition de douze heures. Il part
          # immédiatement et repart à chaque période.
          #
          # La route ET la règle qui l'alimente apparaissent ensemble ou pas du
          # tout (cf. le groupe `meta`). Une route sans sa règle serait morte ;
          # une règle sans sa route, pire — l'alerte perpétuelle retomberait sur
          # le receveur par défaut et partirait sur Discord toutes les cinq
          # minutes, indéfiniment.
          routes = lib.optional cfg.deadManSwitch.enable {
            receiver = "deadman";
            matchers = [ ''alertname="Watchdog"'' ];
            group_wait = "0s";
            group_interval = "1m";
            repeat_interval = cfg.deadManSwitch.interval;
          };
        };

        # Une entrée par couple de seuils, cf. `seuilsEmboites` et le
        # raisonnement qui l'accompagne — la règle générique par gravité qui
        # tenait cette place ne correspondait à rien.
        inhibit_rules = map (p: {
          source_matchers = [ ''alertname="${p.critique}"'' ];
          target_matchers = [ ''alertname="${p.avertissement}"'' ];
          inherit (p) equal;
        }) seuilsEmboites;

        receivers = [
          {
            name = "discord";
            discord_configs = [
              {
                # Receveur Discord NATIF (depuis Alertmanager 0.25), pas un pont
                # à installer. L'URL vient d'un fichier et jamais de la
                # configuration : celle-ci vit dans le store, lisible par tous
                # les utilisateurs de la machine.
                webhook_url_file = "${amCredentials}/discord_webhook";
                send_resolved = true;
                title = ''{{ if eq .Status "firing" }}🔴 {{ .Alerts.Firing | len }} × {{ .CommonLabels.alertname }}{{ else }}🟢 Résolu — {{ .CommonLabels.alertname }}{{ end }}'';
                message = ''
                  {{ range .Alerts -}}
                  **{{ .Labels.severity }}** · `{{ .Labels.instance }}`
                  {{ .Annotations.summary }}
                  {{ end }}
                '';
              }
            ];
          }
        ]
        # Troisième et dernière pièce du dead man's switch, avec sa règle et sa
        # route : les trois apparaissent ensemble ou aucune. Un receveur défini
        # sans route qui le vise est du mobilier mort dans la configuration.
        #
        # Un POST sur l'URL de ping, ce qu'attend healthchecks.io — le corps JSON
        # qu'Alertmanager y met est simplement journalisé chez eux.
        #
        # `send_resolved` à faux et `max_alerts` à un : cette route ne transporte
        # qu'une alerte qui ne se résout jamais, tout le reste serait du bruit
        # envoyé à un tiers.
        ++ lib.optional cfg.deadManSwitch.enable {
          name = "deadman";
          webhook_configs = [
            {
              url_file = "${amCredentials}/healthchecks_ping";
              send_resolved = false;
              max_alerts = 1;
            }
          ];
        };
      };
    };

    # Le webhook est DÉJÀ déclaré par modules/system/notify, mais on le redéclare
    # ici : ce module doit fonctionner même si le signalement d'échec d'unité est
    # coupé, et c'est cette déclaration-là qui fait entrer alertmanager dans
    # l'audience du secret (cf. lib/sops-policy.nix). Les deux définitions
    # fusionnent, aucune ne pose `mode` deux fois.
    #
    # `restartUnits` : alertmanager ne relit pas ses credentials, une rotation du
    # webhook resterait sans effet jusqu'au prochain redémarrage fortuit.
    sops.secrets = lib.mkMerge [
      { ${notify.webhookKey}.restartUnits = [ "alertmanager.service" ]; }

      (lib.mkIf cfg.deadManSwitch.enable {
        ${cfg.deadManSwitch.pingUrlKey} = {
          mode = "0400";
          restartUnits = [ "alertmanager.service" ];
        };
      })

      # Jeton `serverinfo` de Nextcloud. `restartUnits` pour la même raison que
      # ci-dessus : l'exporteur lit le fichier une fois, au démarrage.
      (lib.mkIf (cfg.apps.nextcloudTokenKey != null) {
        ${cfg.apps.nextcloudTokenKey} = {
          mode = "0400";
          # 0400 n'a de sens qu'avec un propriétaire : par défaut le secret
          # appartient à root, et l'exporteur — qui tourne sous son propre
          # compte — se voit refuser la lecture.
          #
          # Possible ICI et pas pour alertmanager, dont le contournement par
          # `LoadCredential` est documenté plus haut : le module amont de
          # l'exporteur Nextcloud déclare un utilisateur STATIQUE, donc un nom
          # qu'un `owner` sops peut désigner. Alertmanager, lui, tourne en
          # `DynamicUser` sous un uid qui change à chaque démarrage.
          owner = "nextcloud-exporter";
          restartUnits = [ "prometheus-nextcloud-exporter.service" ];
        };
      })
    ];

    # --------------------------------------------------------------- journaux

    # Loki : le pendant de Prometheus pour le texte. Même posture — boucle
    # locale, aucun port ouvert, la façade est Grafana derrière le portail.
    #
    # BINAIRE UNIQUE, et c'est le seul mode qui ait un sens ici. Loki se déploie
    # d'ordinaire en composants séparés qui se parlent par un anneau de hachage ;
    # sur une machine, cet anneau tient en mémoire (`inmemory`) avec un seul
    # membre. Les valeurs ci-dessous ne sont donc pas des réglages de
    # performance, ce sont les valeurs qui désactivent la distribution.
    services.loki = lib.mkIf cfg.logs.enable {
      enable = true;

      configuration = {
        # Pas de multi-locataire : il n'y a qu'une machine et qu'un lecteur.
        # Laissé à `true`, Loki exigerait un en-tête `X-Scope-OrgID` sur chaque
        # requête, y compris celles de Grafana.
        auth_enabled = false;

        # PHONE HOME COUPÉ. Loki envoie par défaut un rapport d'usage anonyme à
        # Grafana Labs. Rien de sensible n'y passe, mais une machine de la maison
        # n'a pas à ouvrir de connexion sortante que personne n'a demandée.
        analytics.reporting_enabled = false;

        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = ports.loki;

          # Inutilisé en binaire unique (cf. le bloc `ports`), mais Loki l'ouvre
          # quand même : on le fixe sur la boucle locale plutôt que de le laisser
          # écouter partout sur son défaut.
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = ports.lokiGrpc;

          # Loki est très bavard en `info` — chaque requête de Grafana y passe.
          # Le laisser ainsi ferait de ce service la première source de lignes du
          # journal qu'il est censé collecter, ce qui n'est pas seulement absurde
          # mais BOUCLANT : ses propres traces reviendraient chez lui.
          log_level = "warn";
        };

        common = {
          path_prefix = "/var/lib/loki";
          replication_factor = 1;
          instance_addr = "127.0.0.1";
          ring.kvstore.store = "inmemory";

          storage.filesystem = {
            chunks_directory = "/var/lib/loki/chunks";
            rules_directory = "/var/lib/loki/rules";
          };
        };

        # `from` est la date à partir de laquelle ce schéma s'applique, PAS une
        # date de création : Loki permet d'empiler des schémas pour migrer sans
        # perdre l'ancien. Une seule entrée ici, donc une date passée quelconque
        # suffit — elle doit simplement précéder la première donnée écrite.
        #
        # tsdb + v13 : le couple courant de Loki 3. Les schémas antérieurs
        # marchent encore et sont des culs-de-sac.
        schema_config.configs = [
          {
            from = "2026-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];

        limits_config = {
          retention_period = cfg.logs.retention;

          # ACCEPTER LES ENTRÉES ANCIENNES, contrairement au défaut de Loki qui
          # rejette au-delà d'une semaine. Sans ça, le TOUT PREMIER démarrage
          # produit une rafale de rejets : Vector part du début du journal
          # existant — environ deux mois ici — et tout ce qui dépasse une semaine
          # revient en erreur. Des centaines d'erreurs au premier démarrage, sur
          # un composant dont on veut pouvoir lire le journal, c'est la meilleure
          # façon d'apprendre à ne plus le regarder.
          #
          # Ça n'ouvre pas la porte à un stockage sans fin : le compacteur
          # ci-dessous efface tout ce qui dépasse la rétention à son prochain
          # passage. On accepte, puis on élague — au lieu de refuser bruyamment.
          reject_old_samples = false;

          # Alimente l'histogramme de volume au-dessus des journaux dans Grafana,
          # celui qui montre d'un coup d'œil à quel moment ça s'est mis à parler.
          volume_enabled = true;
        };

        ruler = lib.mkIf lokiRuler {
          storage = {
            type = "local";
            local.directory = lokiRules;
          };

          # Répertoire de TRAVAIL du ruler, distinct des règles elles-mêmes qui
          # viennent du store en lecture seule. Loki y écrit son état
          # d'évaluation, il lui faut donc un chemin inscriptible.
          rule_path = "/var/lib/loki/ruler";

          alertmanager_url = "http://127.0.0.1:${toString ports.alertmanager}";

          # LA LIGNE SANS LAQUELLE AUCUNE ALERTE N'ARRIVE, et rien ne le dirait.
          # Le défaut de Loki est `false`, ce qui le fait poster sur
          # `/api/v1/alerts` — API que Prometheus a RETIRÉE. Mesuré sur cette
          # machine, Alertmanager 0.31.1 y répond « 410 Gone » quand
          # `/api/v2/alerts` répond 200.
          #
          # Le mode d'échec est le pire qui soit pour une chaîne d'alerte : le
          # ruler évalue correctement, déclenche, poste, échoue, et tout le
          # monde a l'air en bonne santé. On ne s'en apercevrait qu'en
          # constatant l'absence d'une alerte attendue — c'est-à-dire jamais,
          # puisque c'est le silence qu'on espère.
          enable_alertmanager_v2 = true;

          ring.kvstore.store = "inmemory";

          # Aucune API de gestion des règles : elles viennent du dépôt, il n'y a
          # rien à créer depuis l'extérieur.
          enable_api = false;
        };

        # SANS CE BLOC, `retention_period` NE FAIT RIEN. Loki l'accepte, ne s'en
        # plaint jamais, et conserve tout indéfiniment — c'est le compacteur qui
        # applique la rétention, et il ne le fait que si on le lui dit
        # explicitement. La panne se découvre le jour où le disque est plein.
        compactor = {
          working_directory = "/var/lib/loki/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };
      };
    };

    # Vector : lit le journal et le pousse dans Loki. Promtail, qui tenait ce
    # rôle historiquement, est en fin de vie depuis mars 2026 et a disparu de
    # nixpkgs ; Vector le remplace ici plutôt qu'Alloy parce que sa configuration
    # est de la DONNÉE — des attrsets Nix rendus en TOML — là où Alloy demande
    # d'embarquer un fichier écrit dans son propre langage, que rien dans ce
    # dépôt ne saurait relire.
    #
    # NE COMPTE PAS SUR LA VALIDATION AU BUILD POUR LE VRL, et ce commentaire
    # affirmait exactement le contraire — « une erreur ici fait échouer le
    # rebuild au lieu de laisser un collecteur muet en production ». C'est faux,
    # et s'y fier a coûté un déploiement raté le 20 août 2026.
    #
    # Le module amont lance bien `vector validate --no-environment` sur le TOML
    # produit, mais ce drapeau ne construit pas la topologie : les programmes VRL
    # ne sont jamais COMPILÉS. Mesuré sur la configuration fautive elle-même, qui
    # contenait une condition `if` que le langage refuse :
    #
    #   $ vector validate --no-environment vector.toml
    #   √ Loaded … Validated          (code de sortie 0)
    #
    # Le rebuild a donc réussi, et c'est l'unité qui est morte au démarrage en
    # « status=78/CONFIG », après le basculement — c'est-à-dire au pire moment,
    # quand plus rien ne peut refuser le changement.
    #
    # CE QUI VALIDE VRAIMENT, à passer avant tout déploiement touchant un
    # `remap` :
    #
    #   echo '{"message":"…"}' | vector vrl -p programme.vrl -i /dev/stdin
    #
    # Il compile le programme ET le fait tourner sur un événement, donc il
    # attrape aussi bien la syntaxe que le résultat. Une ligne de journal réelle
    # copiée depuis Loki suffit à faire un cas de test.
    #
    # Loki, lui, vérifie réellement sa configuration au build.
    services.vector = lib.mkIf cfg.logs.enable {
      enable = true;

      # Fait entrer l'unité dans le groupe `systemd-journal`. C'est LE réglage
      # sans lequel tout le reste est inerte : Vector démarrerait, se déclarerait
      # en bonne santé, et ne lirait rien — le mode d'échec le plus déroutant de
      # cette brique.
      journaldAccess = true;

      settings = {
        # Signet de lecture du journal. Le module amont pose `StateDirectory`,
        # donc ce chemin existe et survit aux redémarrages : Vector reprend où il
        # s'était arrêté, sans trou ni doublon. C'est aussi ce qui rend le
        # redémarrage d'un rebuild indolore.
        data_dir = "/var/lib/vector";

        sources.journal = {
          type = "journald";

          # `false`, contre le défaut de Vector : limité au démarrage courant, il
          # abandonnerait à chaque redémarrage de la machine tout ce qui n'avait
          # pas encore été expédié du démarrage précédent — c'est-à-dire
          # exactement les dernières lignes avant un plantage, les seules qu'on
          # voudra lire.
          current_boot_only = false;

          exclude_units = cfg.logs.excludeUnits;
        };

        # LES JOURNAUX D'ACCÈS DE NGINX, qui ne sont PAS dans journald : nginx
        # écrit dans des fichiers, et journald ne les voit pas. C'était le seul
        # endroit du montage où la réponse à « d'où vient ce pic de requêtes ? »
        # existait, et il fallait un `sudo grep` pour l'atteindre — constaté le
        # 19 août 2026 en cherchant l'origine d'un pic à 291 requêtes/minute,
        # qui s'est révélé être un scanner de vulnérabilités venu du tunnel.
        #
        # `error.log` avec, et il vaut au moins autant : c'est là que nginx dit
        # qu'un amont ne répond plus, qu'une poignée de main TLS a échoué ou
        # qu'un certificat manque — des pannes que le journal d'accès ne montre
        # que par leur conséquence.
        #
        # DEPUIS LE DÉBUT DU FICHIER au premier démarrage : Loki accepte les
        # entrées anciennes (cf. `reject_old_samples`), donc on récupère
        # l'historique de la semaine en cours plutôt que de partir de zéro. La
        # rotation est hebdomadaire, le volume rattrapé reste de l'ordre de la
        # dizaine de mégaoctets.
        sources.nginx = {
          type = "file";
          include = [
            "/var/log/nginx/access.log"
            "/var/log/nginx/error.log"
          ];
          read_from = "beginning";
        };

        # SÉVÉRITÉ DÉDUITE DU CODE DE RETOUR, et le seuil est à 500 — pas à 400.
        #
        # C'est le réglage qui décide si le panneau « erreurs et avertissements »
        # reste lisible. Un 4xx est une erreur du CLIENT : le scanner qui
        # demande /wp-content/mysql.sql reçoit un 404, et c'est le bon
        # comportement. Les compter comme des avertissements noierait le panneau
        # sous plusieurs centaines de lignes par jour qui ne demandent aucune
        # action — la même faute que les erreurs dbus corrigées plus haut.
        #
        # Un 5xx en revanche est NOTRE erreur : l'application a échoué, ou nginx
        # n'a pas pu joindre son amont. Ça mérite d'apparaître.
        #
        # `error.log` n'a pas de code de retour mais une gravité en toutes
        # lettres, d'où les deux chemins.
        transforms.nginx_normalise = {
          type = "remap";
          inputs = [ "nginx" ];
          source = ''
            msg = to_string(.message) ?? ""

            # HORODATER DEPUIS LA LIGNE, ET NON DEPUIS SA LECTURE. La source
            # `file` de Vector estampille l'événement à l'instant où elle le
            # LIT, ce qui est faux dès que la lecture n'est pas immédiate — et
            # elle ne l'est jamais au premier démarrage, qui rattrape le fichier
            # entier d'un coup.
            #
            # Constaté à la mise en service, le 19 août 2026 : des lignes
            # d'accès datées de 20 h 19 apparaissaient dans Loki à 20 h 47, et
            # les quelques milliers de lignes rattrapées se sont toutes empilées
            # sur la même minute. Ça vide de son sens la seule raison d'avoir
            # ces journaux ici — les recoller à une courbe. Un pic de requêtes à
            # 12 h 45 ne se serait retrouvé nulle part.
            #
            # Deux formats, parce que nginx en emploie deux :
            #
            #   - le journal d'ACCÈS porte son décalage (`+0200`), donc il se
            #     lit sans rien supposer ;
            #   - le journal d'ERREURS n'a que l'heure locale, d'où le fuseau
            #     passé en troisième argument. Il vient de `time.timeZone`, et
            #     `parse_timestamp` s'appuie sur la base tz — donc juste aussi
            #     au changement d'heure, ce qu'un décalage fixe ne serait pas.
            #
            # Un format qui ne correspond pas laisse `.timestamp` intact plutôt
            # que de tout casser : on retombe alors sur l'heure de lecture, qui
            # est fausse mais proche en régime établi.
            acces = parse_regex(msg, r'\[(?P<t>\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]') ?? {}
            quand = parse_timestamp(to_string(acces.t), "%d/%b/%Y:%H:%M:%S %z") ?? null

            if quand == null {
              erreurs = parse_regex(msg, r'^(?P<t>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})') ?? {}
              quand = parse_timestamp(to_string(erreurs.t), "%Y/%m/%d %H:%M:%S", "${config.time.timeZone}") ?? null
            }

            if quand != null {
              .timestamp = quand
            }

            # Les mêmes champs que le journal, pour que le puits ci-dessous
            # étiquette les deux flux sans avoir à les distinguer.
            ._SYSTEMD_UNIT = "nginx"
            .SYSLOG_IDENTIFIER = if ends_with(to_string(.file) ?? "", "error.log") {
              "nginx-error"
            } else {
              "nginx-access"
            }
            .host = get_hostname!()

            .level = "info"

            # Journal d'accès : le code est le premier nombre à trois chiffres
            # qui suit la requête entre guillemets.
            trouve = parse_regex(msg, r'" (?P<code>\d{3}) ') ?? {}
            code = to_int(trouve.code) ?? 0
            if code >= 500 {
              .level = "error"
            }

            # LES 502 DE RECONNEXION DE GRAFANA, reclassés et non supprimés.
            #
            # Un onglet Grafana laissé ouvert interroge `/api/live/ws` — le
            # websocket de Grafana Live — toutes les une à deux secondes, et
            # `/api/login/ping` en boucle. Pendant les deux ou trois secondes où
            # Grafana redémarre, nginx n'a plus d'amont et répond 502. Corrélation
            # vérifiée à la seconde près sur six redémarrages du 19 août 2026 :
            # aucun de ces 502 hors de la fenêtre d'arrêt, aucun arrêt sans eux.
            #
            # POURQUOI C'EST LÉGITIME DE LES TAIRE, alors qu'un 5xx est bien une
            # erreur serveur : parce que l'événement qu'ils signalent — Grafana
            # absent — est déjà couvert deux fois, et mieux. Un ARRÊT PROPRE
            # (rebuild) n'est pas une panne et n'a rien à signaler ; une PANNE
            # RÉELLE fait échouer l'unité, donc `notify.discord` prévient sur
            # Discord, et la cible de collecte tombe, donc `CibleInjoignable`
            # alerte. Ces lignes-là sont le signal le plus faible des trois, et
            # le seul qui parle aussi quand tout va bien.
            #
            # LE CIBLAGE EST ÉTROIT À DESSEIN : le code 502 ET le chemin exact,
            # extrait de la requête et non cherché dans la ligne entière — sans
            # quoi une URL de `referer` suffirait à faire taire autre chose. Tout
            # autre 502, sur tout autre chemin, reste une erreur.
            #
            # Rien n'est perdu : `{identifier="nginx-access"} |= " 502 "` les
            # retrouve toutes.
            # `to_string` SANS `??` : il accepte `null` et rend une chaîne vide,
            # donc il ne peut pas échouer. Le coalescing serait refusé par le
            # compilateur VRL (« unnecessary error coalescing operation »).
            # `[^ ?]+` ET NON `\S+`, qui était écrit ici et qui rendait la moitié
            # de cette règle inopérante : `\S+` avale la CHAÎNE DE REQUÊTE avec le
            # chemin, si bien que `/api/ds/query?ds_type=prometheus&requestId=SQR239`
            # ne pouvait être égal à rien de comparable — chaque requête portant
            # un identifiant différent, aucune égalité n'était possible.
            #
            # Ça n'a pas fait de bruit tant que les deux seuls chemins visés
            # étaient dépourvus de paramètres. Constaté le 20 août 2026 : un
            # rebuild à 12 h 42 a produit dix-huit 502, dont treize correctement
            # tus et quatre restés en `error` faute de cette coupure.
            requete = parse_regex(msg, r'"\w+ (?P<chemin>[^ ?]+)') ?? {}
            chemin = to_string(requete.chemin)

            # LES QUATRE CHEMINS QU'UN ONGLET LAISSÉ OUVERT INTERROGE EN BOUCLE,
            # et c'est la liste entière du problème : le websocket de Grafana
            # Live, le ping de session, la requête de données que déclenche le
            # rafraîchissement automatique, et celle des annotations qui
            # l'accompagne depuis que le tableau en porte.
            #
            # Les deux derniers manquaient parce qu'ils n'existaient pas encore
            # quand cette règle a été écrite — `/api/ds/query` n'apparaît qu'avec
            # un `refresh` actif, `/api/annotations` qu'avec des annotations
            # déclarées.
            #
            # RIEN D'AUTRE, et surtout pas tous les 502 de ce vhost : les
            # requêtes d'OUVERTURE de page ne sont pas ici, parce qu'un 502
            # devant quelqu'un qui vient de cliquer est une erreur qu'il voit et
            # sur laquelle il agit. Ce qu'on tait, c'est le bruit de fond d'un
            # onglet que personne ne regarde.
            # UNE LISTE ET `includes()`, ET LA FORME N'EST PAS UN GOÛT : une
            # condition `if` dont les `||` sont répartis sur plusieurs lignes ne
            # S'ANALYSE PAS en VRL, qui referme l'expression au premier saut de
            # ligne et bute ensuite sur la parenthèse. Écrite ainsi, elle a fait
            # échouer le démarrage de Vector en « status=78/CONFIG ».
            #
            # Le tableau, lui, s'écrit sur plusieurs lignes sans difficulté, et
            # il se relit mieux qu'une condition d'une centaine de colonnes.
            sondes_de_fond = [
              "/api/live/ws",
              "/api/login/ping",
              "/api/ds/query",
              "/api/annotations"
            ]

            if code == 502 && includes(sondes_de_fond, chemin) {
              .level = "info"
            }

            # Journal d'erreurs : la gravité y est écrite entre crochets.
            if contains(msg, "[error]") || contains(msg, "[crit]") || contains(msg, "[alert]") {
              .level = "error"
            } else if contains(msg, "[warn]") {
              .level = "warn"
            }
          '';
        };

        # SES PROPRES COMPTEURS, sans quoi la brique qui collecte le journal est
        # la seule chose de cette machine que personne ne regarde.
        #
        # Le mode d'échec qu'on ferme ici est nommé dans l'en-tête de
        # `logs.enable` et n'était pourtant pas instrumenté : Vector qui TOURNE
        # sans plus rien expédier. L'unité reste `active`, `notify.discord` n'a
        # donc rien à signaler, Loki répond parfaitement à des requêtes sur des
        # journaux qui ont cessé d'arriver, et la page reste fonctionnelle et
        # vide — ce qui ressemble trait pour trait à une machine calme.
        sources.internes.type = "internal_metrics";

        sinks.metriques = {
          type = "prometheus_exporter";
          inputs = [ "internes" ];
          address = "127.0.0.1:${toString ports.vector}";
        };

        # NORMALISATION AVANT ÉTIQUETAGE, et ce n'est pas cosmétique. Les
        # étiquettes du puits sont des gabarits : un champ absent rend le gabarit
        # irréalisable et l'événement est PERDU, sans que rien ne le dise.
        #
        # Or `_SYSTEMD_UNIT` manque sur tout ce qui ne vient pas d'une unité — les
        # messages du NOYAU en particulier, c'est-à-dire les disques, la mémoire
        # et le réseau. Les lignes les plus précieuses du journal sont justement
        # celles qui seraient tombées.
        transforms.normalise = {
          type = "remap";
          inputs = [ "journal" ];
          source = ''
            if !exists(._SYSTEMD_UNIT) {
              ._SYSTEMD_UNIT = "noyau"
            }
            if !exists(.SYSLOG_IDENTIFIER) {
              .SYSLOG_IDENTIFIER = "-"
            }
            if !exists(.PRIORITY) {
              .PRIORITY = "6"
            }

            # Gravité en MOT plutôt que le chiffre syslog : c'est ce que Grafana
            # sait colorer, et « error » se cherche mieux que « 3 ».
            priorite = to_int(.PRIORITY) ?? 6
            .level = "info"
            if priorite <= 3 {
              .level = "error"
            } else if priorite == 4 {
              .level = "warn"
            } else if priorite >= 7 {
              .level = "debug"
            }

            # GRAVITÉ CORRIGÉE, PAS LIGNE MASQUÉE, et la nuance est tout le
            # sujet : rien n'est jeté, la ligne reste intégralement cherchable
            # par `{identifier="dbus-broker-launch"}`. Seul son classement
            # change, parce qu'il est faux à la source.
            #
            # dbus-broker consigne en `error` une condition STRUCTURELLE sur
            # NixOS et sans la moindre conséquence. systemd expose quatre de ses
            # noms (`systemd1`, `machine1`, `import1`, `portable1`) dans son
            # propre paquet ; celui-ci étant dans `environment.systemPackages`,
            # ils se retrouvent dans `system-path` — que le module dbus de
            # nixpkgs inscrit EN DUR comme répertoire de services
            # (`services.dbus.packages = [ … config.system.path ]`). Le bus de
            # session voit donc un nom que `systemd --user` possède déjà, garde
            # la première déclaration, et signale la seconde.
            #
            # Aucune configuration ne peut l'empêcher : il faudrait patcher le
            # module amont, ou retirer systemd des paquets système. Ce sont
            # quatre lignes à chaque ouverture de session et à chaque activation.
            #
            # POURQUOI ÇA MÉRITE UNE RÈGLE plutôt que de vivre avec : le panneau
            # « erreurs et avertissements » ne vaut que par le fait qu'on le lit.
            # Quatre fausses erreurs par rebuild — et il y en a un par nuit avec
            # autoUpgrade — suffisent à en faire un panneau qu'on survole. La
            # prochaine vraie erreur passerait avec elles.
            #
            # CIBLAGE ÉTROIT À DESSEIN : l'émetteur ET le texte exact. Une règle
            # sur le seul émetteur ferait taire dbus-broker le jour où il aurait
            # quelque chose de vrai à dire.
            msg = to_string(.message) ?? ""
            if .SYSLOG_IDENTIFIER == "dbus-broker-launch" && contains(msg, "Ignoring duplicate name") {
              .level = "info"
            }
          '';
        };

        sinks.loki = {
          type = "loki";
          inputs = [
            "normalise"
            "nginx_normalise"
          ];
          endpoint = "http://127.0.0.1:${toString ports.loki}";

          # Le MESSAGE seul, pas l'événement complet en JSON. Ce qu'on vient lire
          # dans Grafana est une ligne de journal telle que `journalctl`
          # l'afficherait ; le reste des champs devient des étiquettes ci-dessous,
          # ou n'a aucun intérêt.
          encoding.codec = "text";

          # Loki 3 accepte le désordre dans une fenêtre donnée, et Vector expédie
          # par lots depuis plusieurs unités à la fois : refuser ferait perdre des
          # lignes pour une question d'ordre d'arrivée.
          out_of_order_action = "accept";

          # PEU D'ÉTIQUETTES, ET AUCUNE QUI VARIE BEAUCOUP. C'est la règle
          # cardinale de Loki, et la seule façon de s'en écarter durablement est
          # de ne pas la connaître : chaque combinaison distincte de valeurs crée
          # un FLUX séparé, avec son propre index et ses propres fichiers. Une
          # étiquette portant un identifiant de processus ou un horodatage en
          # fabriquerait des milliers et mettrait Loki à genoux sur une machine
          # qui ne produit pourtant que 4 Mo de texte par jour.
          #
          # Les quatre retenues sont bornées : une quarantaine d'unités, autant
          # d'identifiants, huit gravités, un hôte. Tout le reste — le contenu du
          # message, le PID, le fichier source — se cherche en plein texte, ce que
          # Loki fait très bien sans index.
          labels = {
            unit = "{{ _SYSTEMD_UNIT }}";
            identifier = "{{ SYSLOG_IDENTIFIER }}";
            level = "{{ level }}";
            host = "{{ host }}";
          };
        };
      };
    };

    # ---------------------------------------------------------------- Grafana

    services.grafana = {
      enable = true;

      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = ports.grafana;
          domain = cfg.grafana.hostName;
          # Sans lui, les liens que Grafana fabrique (partage, retour de
          # connexion) pointent vers localhost:3000.
          root_url = "https://${cfg.grafana.hostName}/";

          # COMPRESSION DES RÉPONSES, coupée par défaut chez Grafana. Ce qui
          # transite ici est du JSON — la définition du tableau, puis chaque
          # réponse de requête —, c'est-à-dire ce qui se compresse le mieux.
          #
          # Le chemin justifie la dépense de processeur : depuis l'extérieur, une
          # réponse traverse le tunnel Cloudflare avant d'arriver sur un
          # téléphone en 4G, et c'est exactement la situation où l'on ouvre ce
          # tableau — une alerte vient de tomber, on n'est pas chez soi.
          enable_gzip = true;
        };

        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          feedback_links_enabled = false;
        };
        news.news_feed_enabled = false;

        # L'AUTRE VÉRIFICATEUR DE MISES À JOUR, distinct de celui d'`analytics`
        # juste au-dessus, qui ne couvre que Grafana lui-même. Celui-ci interroge
        # grafana.com pour les GREFFONS, toutes les dix minutes, et il reste actif
        # quand l'autre est coupé — relevé dans le journal, pas supposé :
        #
        #   logger=plugins.update.checker msg="Update check succeeded"
        #
        # Aucun greffon n'est installé sur cette instance, donc la requête
        # demande l'état de rien. Même raison que le phone home de Loki : une
        # machine de la maison n'ouvre pas de connexion sortante que personne n'a
        # demandée.
        plugins.check_for_updates = false;

        # MÊME RAISONNEMENT QUE POUR LOKI, et il se mesure : Grafana écrit 7 689
        # lignes par jour dans le journal, dont ZÉRO au-dessus d'`info` — des
        # évictions de cache d'index, des évaluations de drapeaux internes, la
        # vérification de greffons coupée juste au-dessus. C'est un dixième du
        # volume total de la machine, produit par la brique qui sert justement à
        # LIRE ce journal.
        #
        # Ce qu'on garde : tout ce qui compte vraiment est au-dessus d'`info`.
        # Une erreur de provisioning — un tableau de bord illisible, une source
        # de données refusée — sort en `error` et reste visible.
        log.level = "warn";

        # AUTHENTIFICATION DÉLÉGUÉE AU PORTAIL, et c'est le point le plus délicat
        # du module.
        #
        # Le principe : Authelia authentifie, nginx transmet l'identité dans un
        # en-tête, Grafana fait confiance à cet en-tête et ouvre la session. Plus
        # aucun mot de passe Grafana à gérer, donc plus aucun secret de plus dans
        # sops, et une seule connexion au lieu de deux.
        #
        # CE QUI LE REND SÛR tient à trois conditions, toutes vérifiables :
        #
        #   1. Grafana n'écoute que sur 127.0.0.1 : personne ne peut lui parler
        #      sans passer par nginx.
        #   2. nginx pose l'en-tête avec `proxy_set_header`, qui REMPLACE ce que
        #      le client a envoyé. Un visiteur qui fabrique un `X-WEBAUTH-USER`
        #      le voit écrasé par la valeur qu'Authelia a renvoyée (cf. le vhost
        #      plus bas).
        #   3. `whitelist` restreint la confiance à la boucle locale, seule
        #      adresse d'où nginx se connecte.
        #
        # Retirer l'une des trois suffit à transformer un en-tête en droit
        # d'administration.
        "auth.proxy" = {
          enabled = true;
          header_name = "X-WEBAUTH-USER";
          header_property = "username";
          headers = "Name:X-WEBAUTH-NAME Email:X-WEBAUTH-EMAIL";
          auto_sign_up = true;
          sync_ttl = 60;
          whitelist = "127.0.0.1";
          enable_login_token = false;
        };

        auth = {
          # Formulaire de connexion COUPÉ : le laisser afficherait une porte
          # dérobée protégée par le mot de passe admin par défaut de Grafana.
          #
          # CONTREPARTIE, à connaître avant d'en avoir besoin : si Authelia cesse
          # de renvoyer l'identité, plus personne n'entre, y compris par un
          # tunnel SSH vers 127.0.0.1:3000. La porte de secours est de remettre
          # cette ligne à `false` le temps d'un rebuild, puis
          # `grafana-cli admin reset-admin-password <mot de passe>`.
          disable_login_form = true;
          disable_signout_menu = true;
        };
        "auth.anonymous".enabled = false;
        "auth.basic".enabled = false;

        users = {
          allow_sign_up = false;

          # `Editor` ET NON `Admin`, et l'écart est plus grand qu'il n'y paraît.
          #
          # Ce qu'un Editor peut faire couvre tout l'usage réel : explorer les
          # métriques, écrire des requêtes, créer et modifier des tableaux de
          # bord. Ce qu'il ne peut PAS faire est précisément ce qui est dangereux
          # ici — AJOUTER UNE SOURCE DE DONNÉES. Grafana interroge ses sources
          # depuis le serveur, donc quiconque peut en déclarer une fait émettre à
          # cette machine des requêtes vers l'adresse de son choix, y compris des
          # services de la boucle locale qui ne sont exposés nulle part :
          # Prometheus, Alertmanager, l'API d'Authelia. C'est un relais de
          # requêtes complet, offert par une interface graphique.
          #
          # Ça ne coûte rien parce que les sources sont POSÉES PAR LE DÉPÔT juste
          # en dessous : il n'y a jamais eu de raison d'en ajouter à la main.
          #
          # La barrière principale reste la règle Authelia, qui doit désigner
          # NOMMÉMENT les comptes admis (`subject`) — les comptes familiaux ont
          # eux aussi accès au portail. Celle-ci en est la seconde, pour le jour
          # où la première serait relâchée par inadvertance.
          auto_assign_org_role = "Editor";
        };

        security = {
          cookie_secure = true;

          # Clé qui chiffre les secrets rangés dans la base de Grafana — mots de
          # passe de sources de données, jetons de points de contact. Depuis
          # 26.05 elle n'a plus de valeur par défaut, et le module amont refuse
          # de construire sans elle.
          #
          # NI EN CLAIR ICI, NI DANS SOPS, mais engendrée sur la machine au
          # premier démarrage (cf. le preStart plus bas). En clair, elle finirait
          # dans le store et dans ce dépôt public, ce qui reviendrait à ne rien
          # chiffrer. Dans sops, elle laisserait croire à un secret transportable
          # alors qu'elle ne vaut QUE pour la base qu'elle a chiffrée : la
          # restaurer sur une machine dont la base est vide n'apporte rien, et la
          # perdre en gardant la base rend celle-ci illisible. Clé et base sont
          # le même état local, elles vivent au même endroit.
          #
          # `$__file{}` est le mécanisme de Grafana lui-même : il lit le contenu
          # du fichier au démarrage.
          secret_key = "$__file{${config.services.grafana.dataDir}/secret_key}";
        };
      };

      # Sources et tableaux de bord POSÉS PAR LE DÉPÔT, jamais cliqués. C'est ce
      # qui fait qu'une réinstallation rend une instance identique et pas une
      # instance vide — le reproche principal qu'on peut faire aux outils dont
      # toute la configuration vit dans une base.
      provision = {
        enable = true;

        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              # `uid` FIXE, et c'est ce qui rend le tableau de bord ci-dessus
              # portable : un panneau référence sa source par uid, et un uid
              # engendré au hasard changerait à chaque réinstallation, laissant
              # des panneaux vides.
              uid = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.prometheus}";
              isDefault = true;
              jsonData.timeInterval = cfg.scrapeInterval;
            }
            {
              name = "Alertmanager";
              type = "alertmanager";
              uid = "alertmanager";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.alertmanager}";
              jsonData.implementation = "prometheus";
            }
          ]
          ++ lib.optional cfg.logs.enable {
            name = "Loki";
            type = "loki";
            # `uid` fixe pour la même raison que les deux au-dessus : c'est par
            # lui qu'un panneau ou un signet désigne sa source, et un uid tiré au
            # hasard changerait à la réinstallation.
            uid = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString ports.loki}";
          };
        };

        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "dépôt";
              type = "file";
              # Modification interdite depuis l'interface : le fichier vient du
              # store, donc en lecture seule de toute façon. Le dire à Grafana
              # évite de laisser croire qu'un changement a été enregistré.
              allowUiUpdates = false;
              disableDeletion = true;
              options.path = dashboardsDir;
            }
          ];
        };
      };
    };

    # ------------------------------------------------------------- publication

    services.nginx.virtualHosts.${cfg.grafana.hostName} = lib.mkMerge [
      (myLib.mkTlsVhost {
        # Adresse réelle plutôt que celle de la connexion TCP, comme le portail :
        # tout arrive par cloudflared en 127.0.0.1 quand on vient de l'extérieur.
        extraConfig = ''
          access_log /var/log/nginx/access.log cf_combined;
        '';

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString ports.grafana}";
          # Grafana Live pousse ses mises à jour par websocket.
          proxyWebsockets = true;

          extraConfig = ''
            # LES DEUX LIGNES CI-DESSOUS SONT RECOPIÉES du niveau server, où
            # `authelia.nginxProtect` les pose déjà. Ce n'est pas une redondance,
            # c'est une obligation : `auth_request_set` suit la même règle
            # d'héritage que `add_header`, à savoir qu'un niveau qui en déclare
            # UN SEUL REMPLACE toute la liste du parent au lieu de s'y ajouter.
            #
            # Les trois `auth_request_set` de l'identité, juste en dessous,
            # suffisaient donc à effacer ceux du parent. `$redirection_url`
            # restait vide, `@authelia_401` en concluait que le 401 venait de
            # l'application et servait un 401 sec — en avalant la redirection
            # vers le portail qu'Authelia avait pourtant renvoyée. Symptôme :
            # 401 sans en-tête `Location` sur un nom protégé, alors que le même
            # montage marche sur Nextcloud, dont le vhost n'ajoute aucun
            # `auth_request_set`. Constaté par la sonde blackbox.
            #
            # SI TU AJOUTES un `auth_request_set` ici, vérifie que ces deux-là y
            # sont toujours.
            auth_request_set $redirection_url $upstream_http_location;
            auth_request_set $auth_status $upstream_status;

            # IDENTITÉ RENVOYÉE PAR AUTHELIA, reprise de la sous-requête
            # d'autorisation et repassée à Grafana. `$upstream_http_remote_user`
            # est l'en-tête `Remote-User` de la RÉPONSE d'Authelia — donc une
            # valeur qu'il a produite, pas une valeur que le client a envoyée.
            auth_request_set $authelia_user $upstream_http_remote_user;
            auth_request_set $authelia_name $upstream_http_remote_name;
            auth_request_set $authelia_email $upstream_http_remote_email;

            # `proxy_set_header` REMPLACE l'en-tête du client, il ne s'y ajoute
            # pas : c'est ce qui rend l'identité infalsifiable depuis dehors.
            # Ne jamais retirer ces trois lignes en laissant `auth.proxy` actif,
            # ce serait ouvrir l'administration de Grafana à un en-tête.
            proxy_set_header X-WEBAUTH-USER $authelia_user;
            proxy_set_header X-WEBAUTH-NAME $authelia_name;
            proxy_set_header X-WEBAUTH-EMAIL $authelia_email;
          '';
        };
      })

      # Portail devant le vhost. `nginxProtect` et non `nginxAuthRequest` :
      # contrairement à Nextcloud, rien derrière n'émet de 401 qu'il faudrait
      # préserver — le formulaire de connexion de Grafana est coupé, c'est
      # Authelia qui refuse, et sa redirection doit être suivie.
      authelia.nginxProtect
    ];

    systemSettings.cloudflared = lib.mkMerge [
      (lib.mkIf cfg.grafana.public {
        ingress.${cfg.grafana.hostName} = "https://127.0.0.1:443";
      })

      # DEMANDE au module du tunnel d'ouvrir sa page de métriques, au lieu
      # d'aller modifier son unité systemd de l'extérieur. C'est lui qui connaît
      # le nom de cette unité, construit à partir de l'UUID par le module amont.
      #
      # `mkDefault` : la valeur reste écrasable depuis un profil, et surtout un
      # `metricsAddress` déjà posé ailleurs n'entre pas en conflit avec celle-ci.
      (lib.mkIf cloudflared.enable {
        metricsAddress = lib.mkDefault "127.0.0.1:2000";
      })
    ];

    # ------------------------------------------------------------------ unités

    systemd.services = lib.mkMerge [
      {
        alertmanager = {
          serviceConfig.LoadCredential = [
            "discord_webhook:${config.sops.secrets.${notify.webhookKey}.path}"
          ]
          ++ lib.optional cfg.deadManSwitch.enable "healthchecks_ping:${
            config.sops.secrets.${cfg.deadManSwitch.pingUrlKey}.path
          }";
        };
      }

      # Le socket du pool PHP-FPM est en 0660 nginx:nginx, et l'exporteur tourne
      # sous un utilisateur dynamique : sans appartenance au groupe, il démarre
      # et se voit refuser la connexion. Lecture d'un état, aucun droit sur les
      # fichiers de Nextcloud, qui appartiennent à un autre utilisateur.
      (lib.mkIf (appsOn nextcloud.enable) {
        prometheus-php-fpm-exporter.serviceConfig = {
          SupplementaryGroups = [ "nginx" ];

          # Le durcissement amont n'autorise que AF_INET et AF_INET6, si bien
          # que l'exporteur ne peut pas OUVRIR le socket du pool : il sort en
          # « exit status 2 » sans un mot de plus, et le journal ne nomme jamais
          # l'appel refusé — c'est le mode d'échec normal d'un filtre systemd.
          #
          # La liste est concaténée, pas remplacée : AF_INET et AF_INET6 restent
          # en place pour l'écoute HTTP des métriques.
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      })

      {
        # Engendre la clé de chiffrement de la base au premier démarrage, et
        # seulement s'il n'y en a pas : la RÉÉCRIRE rendrait illisible tout ce
        # qu'elle a déjà chiffré.
        #
        # `mkAfter` : le module amont a son propre preStart, qui pose les liens
        # vers les ressources de Grafana. On s'ajoute derrière au lieu de le
        # remplacer.
        grafana.preStart = lib.mkAfter ''
          key=${config.services.grafana.dataDir}/secret_key
          if [ ! -s "$key" ]; then
            umask 077
            # Sans saut de ligne final : Grafana lit le fichier tel quel.
            ${pkgs-stable.coreutils}/bin/head -c 32 /dev/urandom \
              | ${pkgs-stable.coreutils}/bin/base64 \
              | ${pkgs-stable.coreutils}/bin/tr -d '\n' > "$key"
            ${pkgs-stable.coreutils}/bin/chmod 0400 "$key"
          fi
        '';
      }

      (lib.mkIf (cfg.disks.enable && notify.enable) {
        prometheus-smartctl-exporter = notify.onFailure;
      })

      # LE GROUPE QUI OUVRE LE SOCKET REDIS, et rien d'autre. Sans cette ligne
      # l'exporteur démarre, se déclare en bonne santé et publie `redis_up 0` —
      # c'est-à-dire qu'il annonce exactement la panne qu'il est censé détecter,
      # le pire des faux positifs.
      #
      # ICI et non à côté de l'exporteur, parce que `systemd.services` est
      # assigné en bloc dans ce module : une seconde assignation ailleurs
      # échoue à l'évaluation sur « attribute already defined ».
      (lib.mkIf (appsOn authelia.enable) {
        prometheus-redis-exporter.serviceConfig.SupplementaryGroups = [ "redis-authelia" ];
      })

      (lib.mkIf cfg.logs.enable {
        # ORDONNER VECTOR APRÈS LOKI. Vector réessaie et met en tampon, donc
        # démarrer en premier ne perd rien — mais il passe alors ses premières
        # secondes à échouer à se connecter, à chaque démarrage de la machine.
        # C'est du bruit régulier dans le journal, et c'est le journal de la
        # brique qui collecte le journal.
        #
        # `wants` et non `requires` : Loki à terre plus tard ne doit pas
        # emporter Vector, qui tamponne et reprendra tout seul.
        vector = {
          after = [ "loki.service" ];
          wants = [ "loki.service" ];

          # LES DEUX GROUPES, ET `mkForce` EST OBLIGATOIRE ICI. Le module amont
          # pose `SupplementaryGroups = "systemd-journal"` sous un `mkIf`, une
          # CHAÎNE et non une liste : une seconde définition ne fusionne pas,
          # elle entre en conflit à l'évaluation.
          #
          # D'où l'écrasement — et le piège qu'il crée : `systemd-journal` DOIT
          # rester dans cette liste. L'oublier ne casse rien de visible, Vector
          # démarrerait et se déclarerait en bonne santé en ne lisant plus une
          # seule ligne du journal. C'est le mode d'échec que documente déjà
          # `journaldAccess` ; le reproduire ici par distraction serait
          # d'autant plus vicieux qu'il ne resterait que les accès nginx, donc
          # une page qui a l'air de fonctionner.
          #
          # `nginx` donne la lecture sur /var/log/nginx, qui est en 750 pour ce
          # groupe. Il n'ouvre RIEN d'autre : les certificats appartiennent au
          # groupe `acme`, pas à celui-ci.
          serviceConfig.SupplementaryGroups = lib.mkForce [
            "systemd-journal"
            "nginx"
          ];
        };
      })

      (lib.mkIf (cfg.logs.enable && notify.enable) {
        # Les deux séparément, parce qu'ils échouent séparément et qu'aucun des
        # deux ne signale la panne de l'autre : Loki à terre, Vector tamponne en
        # silence ; Vector à terre, Loki répond parfaitement à des requêtes sur
        # des journaux qui ont cessé d'arriver. Ce second cas est le pire — la
        # page reste fonctionnelle et VIDE, ce qui ressemble à une machine
        # calme.
        loki = notify.onFailure;
        vector = notify.onFailure;
      })

      # DEUX RAISONS DISTINCTES DE FIGURER ICI, et la liste se lit mal sans les
      # séparer — dix unités d'exporteurs tournent sur cette machine, cinq
      # seulement sont raccordées.
      #
      # Les trois PREMIÈRES ne se surveillent pas elles-mêmes : Prometheus arrêté
      # n'évalue plus la règle qui dirait qu'il est arrêté, Alertmanager arrêté
      # ne route plus l'alerte qui le dirait, et Grafana n'est même pas collecté.
      # Le signalement d'échec d'unité est leur SEUL filet.
      #
      # Les deux SUIVANTES sont doublées à dessein : `CibleInjoignable` les
      # attrape déjà, cinq minutes plus tard. Elles sont ici parce qu'elles
      # alimentent tout le reste — node_exporter porte la quasi-totalité des
      # règles, blackbox porte toutes les sondes —, donc leur panne rend muettes
      # des dizaines d'autres alertes et vaut d'être connue tout de suite.
      #
      # Les exporteurs APPLICATIFS sont volontairement absents : leur chute est
      # vue par `CibleInjoignable`, elle ne rend aveugle que leur propre service,
      # et les raccorder tous ferait deux messages par panne pour rien.
      (lib.mkIf notify.enable {
        prometheus = notify.onFailure;
        alertmanager = notify.onFailure;
        grafana = notify.onFailure;
        prometheus-node-exporter = notify.onFailure;
        prometheus-blackbox-exporter = notify.onFailure;
      })
    ];
  };
}
