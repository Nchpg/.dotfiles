{ config, lib, ... }:

# Profil headless : ni session graphique ni GDM (cf. modules/system/gdm, dont le
# défaut suit la présence d'un window manager), une IP fixe et SSH. Prévu pour
# tourner sur le host think, cible `server-think`.
{
  config = {
    systemSettings = {
      # Thémise les TTY, seul rendu local d'un host sans session graphique :
      # sinon la console garde la palette Linux par défaut et la même commande
      # n'a pas les mêmes couleurs sur l'écran de la machine et en SSH depuis
      # gram. Les targets GUI suivent systemSettings.desktop.enable, faux ici.
      stylix.enable = true;

      # nchpg détient la clé age qui déchiffre le dépôt de secrets.
      sops.keyOwner = "nchpg";

      users = [
        {
          name = "nchpg";
          isAdmin = true;
          # Login TTY/SSH en fish, aligné sur userSettings.shell.default.
          shell = "fish";
          # Le commentaire en fin de ligne n'a AUCUN rôle cryptographique : c'est
          # du texte libre, et c'est le seul moyen de savoir à quoi correspond
          # une clé le jour où il faut en révoquer une. On le réécrit donc pour
          # nommer l'appareil, au lieu de garder ce que l'outil a généré —
          # `u0_a375@localhost` pour la seconde, un identifiant d'application
          # Android qui ne dit rien à personne.
          sshKeys = [
            # gram, le poste depuis lequel on administre la machine.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtpLQKGuQttRPNQTdMOjLpx1kn5oM94wj97klIh5Upf nchpg@gram"
            # Termux sur le téléphone, pour dépanner sans ordinateur — le cas où
            # l'on est dehors, en VPN, et où il faut relancer quelque chose.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDFLQKGgSPS//aBeJ0ZnXvDV9sr7XYC7Qu/NUIHy9B+9 nchpg@xiaomi-17t-termux"
            # Le poste sous Windows, d'où l'on se connecte quand on n'est pas sur
            # gram.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC1ZsoIRAXJRR0crPgfWJRPCNBQ+pdWqkMX6qmCq+4y1 nchpg@windows"
          ];
        }
      ];

      ssh = {
        enable = true;
        # Hors du port 22 : aucune sécurité en soi (un scan trouve le port en
        # quelques secondes), mais ça vide le journal des tentatives de
        # bruteforce automatisées qui ne tapent que sur 22.
        port = 3249;
      };

      # Accès distant aux services de la maison SANS en exposer aucun sur
      # internet : seul le port UDP de WireGuard est redirigé sur la box, tout le
      # reste ne répond que sur le LAN ou dans le tunnel.
      #
      # WireGuard natif et non wg-easy : les clés privées des appareils ne
      # transitent jamais par ce host, chaque peer garde son adresse propre — donc
      # une règle Authelia par appareil est possible — et il n'y a plus ni démon
      # docker, ni image à suivre, ni interface web à tenir à jour. L'appairage se
      # fait par `sudo wg-new-peer <nom> <adresse>`, qui affiche la configuration
      # et son QR code.
      vpn.wireguard = {
        enable = true;
        # Sous-domaine dédié, et surtout en « DNS only » côté Cloudflare : leur
        # proxy ne relaie que HTTP/HTTPS, un enregistrement proxifié ne peut pas
        # porter l'UDP de WireGuard. L'apex est pris par le site et un wildcard
        # renverrait vers CF, d'où un record explicite qui l'emporte sur lui.
        host = "vpn.nathanchampagne.com";

        # AUCUN résolveur poussé, comme pour gram : chaque appareil garde le
        # sien, et `cloud.vpn.` résout partout par son enregistrement A public
        # vers 10.8.0.1. C'est ce qui fait qu'un peer ne dépend plus de dnsmasq.
        #
        # La liste précédente était `[ think, la box ]`, censée dégrader
        # gracieusement si dnsmasq s'arrêtait. Elle ne le pouvait pas : la box
        # est sur le LAN, donc joignable seulement en TRAVERSANT ce host, et la
        # règle de forward exclut toutes les destinations privées tandis que
        # `peerLanAccess` est vide. Le repli était jeté en silence, et une panne
        # de dnsmasq coupait TOUTE résolution sur un appareil en tunnel complet,
        # pas seulement les réécritures.
        dns = [ ];

        # Seul le réseau du tunnel y passe, comme gram (cf. hosts/gram). Le
        # trafic ordinaire d'un appareil sort par le réseau où il se trouve.
        #
        # C'est ce que le commentaire de `nextcloud.extraHostNames` plus bas
        # décrit déjà comme le modèle en place — « les clients ne routent que
        # 10.8.0.0/24 vers le VPN » — et qui n'était vrai que de gram. Les
        # profils fabriqués ici partaient encore sur le défaut du module, un
        # tunnel COMPLET, hérité de wg-easy.
        #
        # Ce qu'on abandonne : le chiffrement du trafic ordinaire sur un WiFi
        # public, et l'URL unique — le client de synchronisation d'un peer doit
        # viser `cloud.vpn.…` et non `cloud.…`, ce dernier passant désormais par
        # le portail depuis l'extérieur. En échange le tunnel peut rester monté
        # en permanence sans détourner le trafic ni dépendre de l'upload de la
        # box, et think éteinte ne coupe plus internet.
        #
        # `::/0` disparaît avec, et c'est cohérent : il ne servait qu'à colmater
        # la fuite IPv6 d'un tunnel complet. Sans tunnel complet, il n'y a plus
        # rien à colmater.
        allowedIPs = [ "10.8.0.0/24" ];

        # Un appareil par entrée, clé PUBLIQUE seulement. Retirer une entrée
        # révoque l'appareil au prochain rebuild — la révocation redevient
        # déclarative, ce qu'elle n'était pas quand la liste vivait dans le volume
        # de wg-easy.
        #
        # Les adresses se prennent à la suite dans la plage, 10.8.0.1 étant le
        # serveur. Le nom n'est lu que par nous ; c'est l'adresse et la clé qui
        # comptent, et une assertion du module refuse un doublon.
        peers = [
          {
            name = "xiaomi_17t";
            publicKey = "2XpsKYhyyKszaFd91V8cQ7yynz04RZ37S040S2OU5DY=";
            address = "10.8.0.2";
            presharedKeyKey = "wireguard/xiaomi_17t_preshared_key";
          }
          {
            name = "gram";
            publicKey = "/gV7axgKpUvtPD/oEnbgC4CFpvRULEMAmGVekD4B/zI=";
            address = "10.8.0.3";
            presharedKeyKey = "wireguard/gram_preshared_key";
          }
          {
            name = "windows_gram";
            publicKey = "9q/Vrdgd2Q+o+GWGi8GePNlbQM9lLJ9SNNKwVWHDsWs=";
            address = "10.8.0.4";
            presharedKeyKey = "wireguard/windows_gram_preshared_key";
          }
          {
            name = "oppo_a74";
            publicKey = "gSR1i2a2jxgn3yeszMLjFMe8n+fXOTrFPMuvy0gEhko=";
            address = "10.8.0.5";
            presharedKeyKey = "wireguard/oppo_a74_preshared_key";
          }
          {
            name = "xiaomi_9t";
            publicKey = "hcqtv8ay9e0DKE1qRxWc4+FW2JAiDkWYTbiMIjfPJCE=";
            address = "10.8.0.6";
            presharedKeyKey = "wireguard/xiaomi_9t_preshared_key";
          }
          {
            name = "xiaomi_14tpro";
            publicKey = "pJ7CyK5txL/l2lVqsJ7cD+VGa69WOPy7ixGH7DtIDH0=";
            address = "10.8.0.7";
            presharedKeyKey = "wireguard/xiaomi_14tpro_preshared_key";
          }
        ];

        # SORTIE INTERNET COUPÉE, et c'est la conséquence directe du passage au
        # tunnel restreint juste au-dessus.
        #
        # Tant que `allowedIPs` valait `0.0.0.0/0`, cette option était le sens
        # même du montage : tout sortait par la maison, donc il fallait bien
        # laisser passer. Depuis qu'on ne pousse plus que `10.8.0.0/24`, aucun
        # peer n'envoie de trafic ordinaire dans le tunnel — la règle de forward
        # restait donc posée sans que rien ne l'emprunte, c'est-à-dire comme
        # surface et rien d'autre. Un appareil compromis pouvait encore ajouter
        # la route lui-même et se servir de la maison comme nœud de sortie, avec
        # du trafic attribuable à cette connexion.
        #
        # CE QUE ÇA N'AFFECTE PAS : les services de ce host. Nextcloud, le DNS
        # et SSH sont délivrés LOCALEMENT et relèvent du pare-feu d'entrée, pas
        # de la chaîne de forward — un peer continue de les joindre exactement
        # comme avant.
        #
        # PRÉCONDITION, à vérifier avant de rebuild : un appareil appairé du
        # temps où `wg-new-peer` fabriquait des profils en tunnel complet porte
        # encore `AllowedIPs = 0.0.0.0/0` dans SA configuration, et perdrait
        # alors tout internet tant que son tunnel est monté. Les profils
        # existants ne se mettent pas à jour tout seuls. Regénérer le profil de
        # l'appareil concerné, ou remettre cette ligne à `true` le temps de le
        # faire.
        peerInternetAccess = false;

        # Un peer n'atteint sur le LAN que cette machine — pas la box, pas les
        # objets connectés. Liste VIDE et non « tout le /24 » : un téléphone
        # familial compromis ne doit pas être un pied dans la maison.
        #
        # Ce filtrage n'existait pas avant : avec le pare-feu en iptables, la
        # chaîne FORWARD n'était filtrée par rien du tout.
        #
        # Rien à ajouter ici pour Nextcloud, le DNS ou SSH : ils tournent SUR ce
        # host, donc leur trafic est délivré localement et relève du pare-feu
        # d'entrée, pas du filtrage de traversée.
        peerLanAccess = [ ];
      };

      # Réécriture locale : cloud. répond l'adresse du LAN à la maison et dans le
      # VPN, le tunnel ailleurs. C'est ce qui permet UNE seule URL partout, y
      # compris dans les applications et les liens de partage, ceux-ci étant
      # construits d'après l'hôte de la requête en cours.
      dns = {
        enable = true;

        # Le SEUL nom qui a une raison légitime de répondre une adresse privée
        # depuis l'amont : `cloud.vpn.` pointe vers 10.8.0.1 par un
        # enregistrement A public. Sans cette exemption, la protection contre le
        # rebinding le rejetterait et le chemin de synchronisation tomberait.
        rebindOkDomains = [ "vpn.nathanchampagne.com" ];

        overrides = {
          "cloud.nathanchampagne.com" = "192.168.1.32";

          # Grafana, pour la même raison que le portail juste en dessous : sans
          # cette ligne, regarder ses courbes depuis le salon fait sortir la
          # requête jusqu'à l'edge Cloudflare pour redescendre par le tunnel vers
          # une machine qui est sur le même commutateur.
          "metrics.nathanchampagne.com" = "192.168.1.32";

          # Le portail aussi : sans cette ligne, s'authentifier depuis la maison
          # fait sortir la requête jusqu'à l'edge Cloudflare pour redescendre par
          # le tunnel vers une machine qui est sur le même commutateur, et une
          # panne de box suffit à rendre le portail injoignable sur place.
          # Commodité et non sécurité : depuis l'extérieur, il reste tributaire du
          # tunnel.
          "auth.nathanchampagne.com" = "192.168.1.32";

          # TOUTE la zone interne, résolue ICI et nulle part ailleurs. La syntaxe
          # de dnsmasq couvrant le nom et ses sous-domaines, cette entrée
          # remplace à elle seule le joker `*.lan.` qui vivait chez Cloudflare :
          # n'importe quel nom interne répond, sans rien avoir à déclarer.
          #
          # Plus aucun service du profil n'en dépend depuis le retrait de
          # `cloud.lan.` et de `wg.lan.`, mais elle reste utile pour les noms ad
          # hoc — `think.lan.…` pour SSH, par exemple.
          #
          # Pourquoi l'avoir retiré du DNS public : cet enregistrement publiait
          # 192.168.1.32 au monde entier, et le suffixe `.lan.` ne protégeait
          # rien — c'est un label ordinaire sous une zone publique, pas un
          # domaine local. Le nom ne donnait aucun accès (adresse non routable),
          # mais il n'avait aucune raison d'être annoncé.
          #
          # CE QUE ÇA COÛTE : le DNS public ne sert plus de filet. Si dnsmasq
          # s'arrête, les noms internes deviennent irrésolvables partout, y
          # compris pour les clients VPN — leur résolveur de repli est la box,
          # qui ne les connaît pas. Le chemin public de Nextcloud (`cloud.`,
          # par le tunnel) continue de fonctionner, lui.
          #
          # Les certificats ne sont pas concernés : la validation est en DNS-01,
          # lego pose un TXT par l'API Cloudflare sans avoir besoin d'un
          # enregistrement A, et vérifie la propagation chez 1.1.1.1 (cf.
          # `dnsResolver` dans modules/system/server/proxy) et non chez dnsmasq, qui
          # répondrait NODATA sur ces noms-là.
          "lan.nathanchampagne.com" = "192.168.1.32";
        };
      };

      # Relais SMTP partagé par Authelia et Nextcloud, déclaré une seule fois :
      # changer d'hébergeur se limite à ces lignes et au secret sops.
      #
      # Relais transactionnel plutôt qu'une boîte sur le domaine : chez IONOS les
      # boîtes supplémentaires sont facturées, et l'alias Gmail aurait fait
      # apparaître « via gmail.com » chez les destinataires sous Outlook. `user`
      # est un identifiant technique imposé par Resend, distinct de l'adresse
      # affichée — c'est le cas que le module sépare.
      #
      # Vérifié en conditions réelles : DKIM signe avec d=nathanchampagne.com,
      # l'alignement DMARC est donc strict et le Return-Path reste sur
      # send.nathanchampagne.com.
      mail = {
        enable = true;
        host = "smtp.resend.com";
        user = "resend";
        from = "nextcloud@nathanchampagne.com";
      };

      # nginx + ACME, socle des vhosts du host.
      proxy = {
        enable = true;
        # Aucune adresse : les avis d'expiration de Let's Encrypt ont cessé le
        # 4 juin 2025, donc le champ ne recevait plus rien. Ce qui surveille le
        # renouvellement est `notify.discord` ci-dessous, qui prévient à
        # l'échec plutôt qu'à l'expiration.
        #
        # Ce qu'on abandonne : le canal par lequel Let's Encrypt préviendrait
        # d'une révocation de masse. Assumé — ça arrive une fois par décennie et
        # ça se sait par ailleurs, alors qu'une adresse personnelle dans un dépôt
        # public se fait moissonner en continu.
        acmeEmail = null;
      };

      # Prévient quand une unité échoue, sur une machine que personne ne regarde.
      # Le webhook est un identifiant : il vit dans les secrets système, pas ici.
      notify.discord.enable = true;

      # Ce que `notify.discord` ne peut pas voir : les pannes qui s'annoncent au
      # lieu de survenir. Un disque qui se remplit, une mémoire qui part en swap,
      # une horloge qui dérive — aucune de ces trois-là ne fait échouer une unité
      # avant qu'il soit trop tard.
      #
      # Les alertes repartent sur le MÊME webhook Discord : un seul endroit à
      # regarder, et le secret existe déjà.
      monitoring = {
        enable = true;

        grafana = {
          # `metrics.` et non `grafana.` : le nom désigne ce qu'on vient voir,
          # pas l'outil qui l'affiche. Changer d'outil ne devrait pas obliger à
          # changer d'URL, ni à refaire un certificat.
          hostName = "metrics.nathanchampagne.com";
          # Publié par le tunnel, comme Nextcloud et le portail. Sans ça les
          # courbes ne se regardent que depuis la maison ou le VPN — c'est-à-dire
          # jamais au moment où l'on en a besoin, qui est celui où l'on est
          # ailleurs et où quelque chose ne va pas.
          public = true;
        };

        # CE QUE CES SONDES DISENT ET NE DISENT PAS. Elles partent de think, où
        # dnsmasq réécrit les noms publics vers le LAN : elles tapent donc sur
        # nginx en direct et ne traversent PAS le tunnel. Une panne de
        # cloudflared reste invisible ici — c'est le dead man's switch, jugé
        # depuis l'extérieur, qui couvre ce cas.
        blackbox.targets = {
          # Le chemin du VPN contourne le portail (règle `bypass` d'Authelia sur
          # la plage WireGuard), donc la sonde reçoit la VRAIE réponse de
          # Nextcloud : c'est la seule qui vérifie PHP et la base, pas seulement
          # nginx. Elle suppose le tunnel WireGuard monté, ce qui est le cas —
          # et son absence est en soi une chose qu'on veut savoir.
          nextcloud = {
            url = "https://cloud.vpn.nathanchampagne.com/status.php";
            module = "http_2xx";
          };

          # Le nom PUBLIC, qui doit répondre par une redirection vers le portail.
          # Un 200 signalerait que la protection est tombée, et la sonde le
          # compterait comme un échec.
          nextcloud-portail = {
            url = "https://cloud.nathanchampagne.com/";
            module = "http_authelia";
          };

          # Point de santé d'Authelia, servi sans authentification par le vhost
          # du portail. Il tombe si Redis ou le fichier d'utilisateurs sont
          # inaccessibles — deux pannes qui ferment l'accès à TOUT le reste.
          authelia = {
            url = "https://auth.nathanchampagne.com/api/health";
            module = "http_2xx";
          };

          grafana = {
            url = "https://metrics.nathanchampagne.com/";
            module = "http_authelia";
          };

          # LA SEULE SONDE QUI VÉRIFIE LE CHEMIN PUBLIC COMPLET, et elle vaut à
          # elle seule les quatre autres pour ça.
          #
          # Les autres visent des noms que dnsmasq réécrit vers le LAN (cf.
          # `dns.overrides`) : elles tapent sur nginx en direct et ne traversent
          # jamais le tunnel, donc une panne de cloudflared les laisse toutes au
          # vert. L'apex, lui, n'a AUCUNE réécriture — volontairement. La requête
          # sort jusqu'à l'edge Cloudflare et redescend par le tunnel, exactement
          # comme celle d'un visiteur.
          #
          # NE PAS ajouter d'override dnsmasq pour ce nom : ce serait raccourcir
          # le trajet, donc supprimer ce que cette sonde est seule à vérifier.
          #
          # `http_2xx` et non `http_authelia` : le portfolio est public, aucun
          # portail devant. Et il répond 200 sur `/` sans redirection de locale,
          # vérifié — `next-intl` sert ici la langue par défaut à la racine.
          portfolio = {
            url = "https://nathanchampagne.com/";
            module = "http_2xx";
          };
        };

        # Battement de cœur vers healthchecks.io, seul juge extérieur du montage.
        # L'URL de ping est une capacité — qui la détient peut maintenir le
        # service en « tout va bien » — donc elle vit dans sops.
        #
        # Santé physique des disques, découverte automatique. C'est la seule
        # chose surveillée ici dont la panne détruit des données : smartd la
        # détectait déjà, mais notifiait par `systembus-notify`, qui ne va nulle
        # part sur une machine sans session graphique.
        disks.enable = true;

        # À RÉGLER CÔTÉ HEALTHCHECKS : période 15 min, grâce 10 min. Coller au
        # plus près des 5 minutes ferait sonner à chaque rebuild nocturne
        # d'autoUpgrade, qui redémarre Alertmanager.
        deadManSwitch.enable = true;

        # Métriques des services, et pas seulement de la machine. Ce que ça
        # attrape et que rien d'autre ne voyait : un pool PHP saturé pendant que
        # le processeur dort, et des authentifications refusées en série sur un
        # portail qui répond 200 aux sondes.
        #
        apps.enable = true;

        # Jeton `serverinfo`, produit par l'instance et rangé dans les secrets.
        # DÉCLARER LA CLÉ D'ABORD : c'est cette déclaration qui fait apparaître
        # la règle de création dans le .sops.yaml du dépôt privé (bloc généré
        # par `nix run .#sops-policy`), et sans règle sops refuse de créer le
        # fichier. L'ordre inverse — créer le secret puis câbler l'option —
        # échoue sur « no matching creation rules found ».
        apps.nextcloudTokenKey = "nextcloud/serverinfo_token";
      };

      # UN SEUL NOM, deux chemins. `cloud.` répond l'adresse du LAN à la maison
      # et dans le VPN (réécriture dnsmasq ci-dessus), le tunnel ailleurs — et
      # c'est Authelia qui distingue les deux sur l'adresse source. Il n'y a donc
      # plus de nom interne dédié : `cloud.lan.` a été retiré, son seul apport
      # résiduel étant un mode d'échec plus lisible quand dnsmasq est à terre.
      #
      # La convention `.lan.` reste valable pour les noms internes ad hoc — le
      # joker dnsmasq les couvre tous, cf. `dns.overrides` — mais aucun service
      # déclaré ici n'en dépend.
      nextcloud = {
        enable = true;
        hostName = "cloud.nathanchampagne.com";

        # Nom du chemin RÉSERVÉ, résolu vers l'adresse de think DANS le tunnel
        # (10.8.0.1) par un enregistrement A public en nuage gris. Cette adresse
        # n'étant joignable que par WireGuard, le nom ne fonctionne que le tunnel
        # monté — ce qui est exactement la sémantique voulue.
        #
        # C'est lui que visent les clients de SYNCHRONISATION, qui ne savent pas
        # suivre une redirection d'authentification et ont donc besoin d'un nom
        # que les règles laissent passer. Le navigateur, lui, continue d'utiliser
        # `hostName` et passe par le portail.
        #
        # Pourquoi l'adresse du tunnel et non celle du LAN : les clients ne
        # routent que `10.8.0.0/24` vers le VPN, donc leur trafic ordinaire sort
        # par le réseau où ils se trouvent. Router le LAN à la place entrerait en
        # conflit, à la maison, avec le préfixe déjà connecté.
        extraHostNames = [ "cloud.vpn.nathanchampagne.com" ];

        # Liens de partage utilisables par quelqu'un d'EXTÉRIEUR : ni compte
        # Authelia, ni clé WireGuard. Sans ça, sa requête arrive par le tunnel,
        # nginx voit 127.0.0.1, et la règle `two_factor` plus bas — celle sans
        # `networks`, qui attrape toute origine — le renvoie sur une page de
        # connexion qu'il ne peut pas franchir.
        #
        # Le module injecte pour ça un `bypass` EN TÊTE des règles d'Authelia
        # (`mkBefore`), limité aux chemins d'une page de partage et au seul nom
        # public. Il n'apparaît pas dans la liste `authelia.rules` ci-dessous : la
        # note y renvoie ici.
        #
        # PAS de mot de passe imposé sur les liens, et c'est un choix : il ne
        # défendrait pas contre l'énumération, qui n'est pas praticable — jeton de
        # quinze caractères, plus de 80 bits, aucun point d'entrée ouvert ne liste
        # les partages, et `X-Robots-Tag: noindex` tient les moteurs de recherche
        # à l'écart. Il ne défendrait que contre la fuite d'un lien après coup,
        # au prix d'un code à transmettre à chaque partage et d'un abaissement
        # GLOBAL du plancher de `password_policy`, qui vaut aussi pour les mots de
        # passe de comptes. La case « protéger par un mot de passe » reste dans
        # l'interface pour les partages qui le méritent.
        #
        # L'expiration par défaut couvre le même risque de fuite sans aucune de
        # ces contreparties : elle ne demande rien au moment du partage.
        publicSharing = {
          enable = true;

          # SANS ÇA, un partage créé depuis l'application mobile sort en
          # `https://cloud.vpn.…/s/<jeton>`. L'application est configurée sur le
          # nom interne, Nextcloud fabrique ses liens d'après l'hôte de la
          # requête, et ce nom-là ne résout que vers l'adresse du tunnel : le
          # destinataire reçoit un lien mort, sans que rien ne l'ait signalé au
          # moment de l'envoyer.
          #
          # Vrai par défaut, redit ici parce que c'est le montage à DEUX NOMS qui
          # rend le réglage nécessaire : sur une instance à un seul nom il ne
          # ferait rien. Cf. l'option pour pourquoi ça ne passe pas par
          # `overwritehost`, qui aurait rendu `cloud.vpn.` non navigable.
          canonicalLinkHost = true;

          # Complète le réglage ci-dessus pour l'INTERFACE WEB, que la réécriture
          # nginx ne peut pas atteindre : le navigateur fabrique le lien à partir
          # de son URL, pas du champ renvoyé par le serveur. Ce réglage patche le
          # bundle Nextcloud pour figer l'hôte du lien de partage.
          #
          # DETTE ASSUMÉE : c'est du code minifié amont. Une garde au build
          # empêche le patch de disparaître en silence, mais au prix inverse — une
          # mise à jour Nextcloud qui change ces bundles fera ÉCHOUER le build
          # nocturne d'autoUpgrade jusqu'à réajustement du motif (alerte Discord,
          # ancienne génération conservée). Activé parce que le partage doit
          # marcher depuis le navigateur sur `cloud.vpn.` comme depuis l'app.
          canonicalLinkWebUi = true;

          # Deux mois : de quoi qu'une famille récupère des photos sans se
          # presser, largement en deçà de la durée pendant laquelle un lien
          # traîne dans une conversation. Rallongeable partage par partage depuis
          # l'interface, la valeur n'étant qu'un défaut.
          linkExpireDays = 60;
        };

        # Dernier levier de performance réel pour un usage photo et vidéo : le
        # reste des réglages gratte des millisecondes, celui-ci évite de
        # redimensionner une image de 12 mégapixels pendant que quelqu'un attend
        # devant sa galerie.
        previews.pregenerate = true;

        # Langue des NOUVEAUX comptes et de la page de connexion. Non imposée :
        # chacun reste libre de changer dans ses paramètres, et le compte admin
        # déjà créé garde l'anglais.
        language = "fr";
        locale = "fr_FR";

        # Authelia ne garde que le chemin public : sur le chemin interne, celui
        # du VPN et des applications, un compte n'est protégé que par son mot de
        # passe. Ce second facteur-ci comble ce trou, y compris pour les comptes
        # familiaux dont les mots de passe seront ce qu'ils seront.
        enforceTwoFactor = true;

        # Aplats de couleur, sans image de fond, tirés du schéma stylix actif.
        theming = {
          # Le FOND suit le schéma stylix du host (`base00`, `#1d2021`), la
          # primaire est CHOISIE. Le module met en garde contre son défaut, qui
          # reprend `base0D` — ici `#83a598`, un canard désaturé fait pour
          # ressortir sur du noir, donc terne sur l'interface claire de
          # Nextcloud. La réserve est justifiée, on la contourne en désignant la
          # teinte au lieu de la laisser dériver.
          #
          # `#8ec07c`, le `base0C` du même schéma : le vert doux de Gruvbox,
          # entre le canard d'origine et le vert-jaune vif. Les deux autres si
          # celui-ci ne convient pas à l'usage : `#b8bb26` (base0B), franchement
          # acide, et `#83a598` (base0D), le canard désaturé.
          primaryColor = "#8ec07c";

          # Le canard `base0D` en fond, plutôt que le `base00` presque noir du
          # schéma : deux verts de la même famille, l'un pour les boutons,
          # l'autre pour l'aplat, et le contraste avec les panneaux clairs de
          # Nextcloud cesse d'être brutal.
          backgroundColor = "#83a598";
          #
          # `name` reste nul à dessein : l'émetteur des URI TOTP vaut
          # « Nextcloud » par défaut, et les applications d'authentification y
          # trouvent la bonne icône, là où « Cloud » faisait afficher le logo
          # de X.
          #
          # Corollaire de `lockUserTheming`, vrai par défaut : personne ne peut
          # choisir ses propres couleurs, et une teinte posée depuis l'interface
          # est remise à zéro au prochain rebuild.
          enable = true;

          # S'applique indépendamment des couleurs, contrairement à ce que le
          # module imposait avant : masquer des éléments n'a rien à voir avec une
          # palette.
          #
          # Le menu contacts appartient au CŒUR de Nextcloud, aucune
          # désactivation d'application ne le retire (`contactsinteraction`, qu'on
          # a coupée, ne gère que la collecte automatique). La feuille de style
          # est le seul moyen. Sélecteurs susceptibles de changer à une mise à
          # jour majeure : la règle cesserait de s'appliquer, sans rien casser.
          customCss = ''
            /* Menu contacts de la barre supérieure. */
            #contactsmenu,
            .header-right .contactsmenu {
              display: none !important;
            }

            /* Le fondu haut-bas des icônes de la barre vient d'un MASQUE alpha,
               pas d'une opacité. Neutraliser la variable plutôt que le
               sélecteur, celui-ci portant une empreinte Vue ([data-v-…]) qui
               change à chaque version de Nextcloud.

               `body` ET les sélecteurs de thème, pas seulement `:root`, et c'est
               tout le sujet. Nextcloud pose ses variables sur `<body>` — vérifié
               dans le HTML servi, `<body data-themes="">` — alors que `:root`
               désigne `<html>`. Or `!important` ne franchit PAS l'héritage : il
               départage des déclarations portant sur le MÊME élément, et un
               `<body>` qui a la sienne, même non importante, l'emporte pour lui
               et tous ses descendants. Le header étant dans le corps, il
               héritait du dégradé quoi qu'on écrive sur `<html>`.

               Le défaut ne se voyait qu'en thème CLAIR : le dégradé se calcule
               depuis `--color-background-plain-text`, donc sur fond sombre il
               est invisible. Il était bien là aussi. */
            :root,
            body,
            [data-theme-default],
            [data-theme-light],
            [data-theme-dark],
            [data-theme-light-highcontrast],
            [data-theme-dark-highcontrast] {
              --header-menu-icon-mask: none !important;
            }

            /* Encart promotionnel en bas des informations personnelles :
               licence, réseaux sociaux, blog, infolettre. */
            .section.development-notice {
              display: none !important;
            }

            /* Champs de profil public et réseaux sociaux, sans objet pour un
               stockage familial. L'application `profile` est déjà désactivée,
               mais ces champs restent affichés par le panneau lui-même.
               Conservés à dessein : avatar, nom affiché, adresse électronique
               (indispensable à la réinitialisation de mot de passe), langue,
               format régional, fuseau horaire et récapitulatif de quota.
               NE PAS cibler les `#vue-…-section` du gabarit PHP : Vue remplace
               ces points de montage et leur identifiant disparaît du DOM. On
               vise donc la boîte parente d'après l'identifiant de son champ de
               saisie, stable car issu des constantes
               IAccountManager::PROPERTY_*. */
            .personal-settings-setting-box:has(#account-property-phone),
            .personal-settings-setting-box:has(#account-property-address),
            .personal-settings-setting-box:has(#account-property-birthdate),
            .personal-settings-setting-box:has(#account-property-website),
            .personal-settings-setting-box:has(#account-property-twitter),
            .personal-settings-setting-box:has(#account-property-bluesky),
            .personal-settings-setting-box:has(#account-property-fediverse),
            .personal-settings-setting-box:has(#account-property-organisation),
            .personal-settings-setting-box:has(#account-property-role),
            .personal-settings-setting-box:has(#account-property-headline),
            .personal-settings-setting-box:has(#account-property-biography),
            .personal-settings-setting-box:has(#account-property-pronouns) {
              display: none !important;
            }
          '';
        };

        # Taillé pour CET usage : stockage familial de photos, vidéos et
        # fichiers, avec des dossiers partagés entre comptes. Tout ce qui ne sert
        # pas ça est coupé, une application activée travaillant à chaque requête
        # même quand personne ne l'ouvre.
        #
        # Restent actives à dessein : files, dav et files_sharing pour le partage
        # et la synchro ; photos et viewer pour les médias ; files_versions et
        # files_trashbin, seul filet faute de sauvegarde.
        #
        # Certaines applications ne peuvent PAS être désactivées, Nextcloud les
        # inscrivant dans la liste `alwaysEnabled` de core/shipped.json : les
        # mettre ici ne produirait qu'une erreur silencieuse.

        # Sortie de `disabledApps` quand le relais SMTP est arrivé. Il faut la
        # rallumer EXPLICITEMENT : le mécanisme ne sait que désactiver.
        enabledApps = [ "sharebymail" ];

        disabledApps = [
          # Promotion et télémétrie de l'éditeur.
          "firstrunwizard"
          "nextcloud_announcements"
          "survey_client"
          "support"
          # La version vient de Nix, cette vérification ne sert à rien.
          "updatenotification"
          # Widgets et pages sans rapport avec du stockage de fichiers.
          "dashboard"
          "weather_status"
          "recommendations"
          "privacy"
          "related_resources"
          "files_reminders"
          # Fédération vers d'autres instances. Seul `federation` peut partir :
          # `federatedfilesharing`, `cloud_federation_api` et
          # `lookup_server_connector` sont dans `alwaysEnabled`.
          "federation"
          "contactsinteraction"
          # Limites de téléchargement sur liens publics, inutilisées.
          "files_downloadlimit"
          # Cercles : le partage de dossier entre comptes suffit à une famille.
          "circles"
          # Éditeur collaboratif, stockage externe, annuaire LDAP.
          "text"
          "files_external"
          "user_ldap"
          # Journal d'audit, coûteux, et chiffrement serveur déjà déconseillé.
          "admin_audit"
          "encryption"
          # Extensions externes et webhooks.
          "app_api"
          "webhook_listeners"
          # Détection de connexion suspecte, commentaires, présence.
          "suspicious_login"
          "comments"
          "user_status"
          # Deuxième facteur par notification : redondant avec TOTP, qu'on garde.
          "twofactor_nextcloud_notification"
          # Flux d'activité, la plus coûteuse des applications restantes : elle
          # accroche un écouteur sur CHAQUE opération de fichier. En échange on
          # perd l'historique de qui a fait quoi, seul moyen — sans sauvegarde —
          # de reconstituer ce qui est arrivé à un fichier disparu.
          "activity"
        ];
      };

      # Coffre-fort de mots de passe, joignable UNIQUEMENT par le tunnel
      # WireGuard : aucune route dans le tunnel Cloudflare, et nginx refuse
      # toute source hors de la plage du VPN. Cf. l'en-tête du module pour ce
      # qu'il faudrait ajouter — Authelia en tête — le jour où on le publierait.
      #
      # PRÉCONDITION HORS DÉPÔT, à poser avant le rebuild : un enregistrement A
      # `vault.vpn.nathanchampagne.com` vers 10.8.0.1 chez Cloudflare, en « DNS
      # only » (nuage gris), exactement comme `cloud.vpn.`. Sans lui le nom ne
      # résout nulle part, et la sonde que le module ajoute à
      # `monitoring.blackbox.targets` le dira bruyamment.
      vaultwarden = {
        enable = true;
        hostName = "vault.vpn.nathanchampagne.com";

        # TES APPAREILS, ET PAS TOUT LE TUNNEL. Le défaut du module autorise la
        # plage entière, donc les six peers — y compris les téléphones de la
        # famille, qui n'ont aucune raison d'atteindre ton coffre. Trois de
        # moins devant la page de connexion, et ce sont justement les trois que
        # tu ne maîtrises pas.
        #
        # Dérivé des peers PAR LEUR NOM plutôt que recopié en dur : le jour où
        # une adresse change dans la liste ci-dessus, l'autorisation suit. Le
        # `throwIf` couvre le cas inverse — un peer renommé disparaîtrait
        # silencieusement de cette liste, et le seul symptôme serait un 403
        # depuis l'appareil concerné, sans rien pour le relier à ce fichier.
        #
        # L'adresse de think en plus, pour la sonde de surveillance seule : elle
        # vise 10.8.0.1 mais ressort masquée en 192.168.1.32 (cf. l'option dans
        # le module).
        allowedNetworks =
          let
            miens = [
              "xiaomi_17t"
              "gram"
              "windows_gram"
            ];
            trouves = lib.filter (p: lib.elem p.name miens) config.systemSettings.vpn.wireguard.peers;
          in
          lib.throwIf (lib.length trouves != lib.length miens)
            "profiles/server : un appareil autorisé sur le coffre ne figure plus dans vpn.wireguard.peers. Renommer un peer lui retirerait l'accès en silence — corrige la liste `miens`."
            (map (p: "${p.address}/32") trouves)
          ++ [ "${config.systemSettings.network.staticIPv4.address}/32" ];

        # FERMÉE depuis la création du premier compte. Les suivants — la famille
        # — passent par une invitation envoyée depuis une organisation du
        # coffre : `INVITATIONS_ALLOWED` reste actif, donc un invité peut
        # s'enregistrer alors même que l'inscription libre est close. C'est le
        # chemin à préférer, il nomme le destinataire au lieu d'ouvrir la porte.
        #
        # La rouvrir se fait en repassant cette ligne à `true` le temps d'un
        # rebuild ; un avertissement s'affiche tant qu'elle l'est, pour qu'on
        # n'oublie pas de refermer.
        signups.enable = false;
      };

      # Portfolio, servi depuis une image construite par GitHub Actions à chaque
      # poussée sur `main` du dépôt du site. think ne détient aucune source : elle
      # tire une image et la fait tourner, c'est tout.
      #
      # Le digest se relève dans la sortie du run qui a publié l'image. Mettre à
      # jour le site = pousser, remplacer la ligne ci-dessous, rebuild.
      apps."portfolio" = {
        domain = "nathanchampagne.com";

        # Un seul conteneur, donc pas d'`entrypoint` à désigner et aucun réseau
        # posé : il n'y a personne à résoudre.
        containers.web = {
          image = "ghcr.io/nchpg/portfolio@sha256:6093e42281be766045cac3f474d29a4defe93244fdfa3eff6a1c69439d74d114";
          # Next en mode `standalone` écoute sur 3000 (cf. le Dockerfile du site).
          port = 3000;

          # PAS un secret, malgré son nom : ce jeton est servi dans un
          # `<meta name="google-site-verification">` du HTML, donc lisible par
          # quiconque affiche la source. Et le connaître ne permet à personne de
          # revendiquer le domaine — Google émet un jeton DIFFÉRENT par compte, la
          # difficulté étant de le placer sur le site, pas de le deviner. Il peut
          # donc rester en clair, là où `environmentFiles` serait requis pour une
          # vraie valeur sensible.
          #
          # Les variables `NEXT_PUBLIC_*` du site ne sont PAS ici, et ce n'est pas
          # un oubli : Next les remplace textuellement pendant `npm run build`,
          # donc les poser à l'exécution n'aurait aucun effet. Elles vivent dans
          # les `build-args` du workflow.
          environment.GOOGLE_SITE_VERIFICATION = "TfARlD-WI-dO71XO0G7bcmm5VvA_ra5idC-HK-Nd9qM";
        };
      };

      # RLkart : simulateur de karting piloté par apprentissage par renforcement.
      # Deux conteneurs, traduction directe de son `docker-compose.yml`.
      #
      # `frontend` sert les fichiers statiques et porte son propre nginx, qui
      # proxifie `/generate` et `/simulate` vers `http://backend:8000`. Cette
      # ligne-là fonctionne SANS ÊTRE TOUCHÉE : les deux conteneurs partagent le
      # réseau de l'application et s'y résolvent par leur nom.
      #
      # Ce que ça change par rapport au compose : `backend` ne publie plus
      # `8000:8000`. Il n'ouvre RIEN sur le host, donc plus personne sur le LAN
      # ne peut appeler l'API en court-circuitant nginx. Seul `frontend` est
      # publié, sur la boucle locale.
      apps."rlkart" = {
        domain = "rlkart.nathanchampagne.com";
        entrypoint = "frontend";

        containers = {
          frontend = {
            image = "ghcr.io/nchpg/rlkart-frontend@sha256:5f7b09c3452b9b1502e2b8c108f48bad28d31ef577b190b691624b1b7f282cb2";
            # L'image officielle nginx écoute sur 80. Sous 1024, donc le module
            # lui rend `CAP_NET_BIND_SERVICE` — sans quoi elle ne peut pas se
            # lier, même en root.
            port = 80;

            # Son nginx résout `backend` À L'ANALYSE de sa configuration, pas à
            # chaque requête. Démarré en premier, il meurt sur
            # `host not found in upstream` et boucle indéfiniment.
            dependsOn = [ "backend" ];

            # L'image officielle nginx démarre en root, s'approprie ses
            # répertoires de cache, puis abandonne ses privilèges pour ses
            # processus de travail. Sans ces trois-là, elle meurt sur
            # `chown("/var/cache/nginx/client_temp", 101) failed`.
            #
            # C'est le signe qu'une variante `nginxinc/nginx-unprivileged`
            # rendrait tout ça inutile : elle tourne en utilisateur non
            # privilégié sur un port haut, donc sans aucune de ces capacités ni
            # `NET_BIND_SERVICE`. À envisager la prochaine fois qu'on touche à ce
            # Dockerfile.
            capabilities = [
              "CHOWN"
              "SETUID"
              "SETGID"
            ];
          };

          backend = {
            image = "ghcr.io/nchpg/rlkart-backend@sha256:939e1f49e41a5b1e3a2fdf298a4d4f1ccd892ae6b92da9f9805e5b6937d7429d";
            # Rien n'est publié sur le host pour ce conteneur — seul le point
            # d'entrée l'est. Le port est déclaré quand même parce qu'il dit la
            # vérité sur ce que l'image écoute, et que le module s'en sert pour
            # décider des capacités à accorder.
            port = 8000;
          };
        };

        # LE POINT QUI COMPTE SUR CETTE APPLICATION-CI. `/simulate` déclenche une
        # simulation physique côté serveur, et `/generate` fabrique un tracé :
        # deux chemins qui coûtent du processeur à chaque appel. Exposés sans
        # limite, c'est un robinet ouvert sur internet — quelques boucles
        # suffisent à saturer think, ce qui emporterait Nextcloud et le reste.
        #
        # Les chemins sont désignés plutôt que l'application entière : charger la
        # page ne doit pas consommer le quota qui protège le calcul.
        rateLimit = {
          enable = true;
          paths = [
            "/generate"
            "/simulate"
          ];
        };
      };

      # Tunnel créé depuis gram (`cloudflared tunnel login` puis `tunnel create`,
      # qui exigent un navigateur). Ici ne tourne que le démon, nourri par le
      # JSON de credentials via sops.
      cloudflared = {
        enable = true;
        tunnelId = "4c8a6f06-b1cd-4a64-ba62-021113f68bda";
        ingress = {
          "cloud.nathanchampagne.com" = "https://127.0.0.1:443";
          # Le portail doit être publié lui aussi : la redirection
          # d'authentification se joue dans le navigateur du visiteur, qui doit
          # pouvoir l'atteindre depuis l'extérieur.
          "auth.nathanchampagne.com" = "https://127.0.0.1:443";
        };
      };

      # Équivalent auto-hébergé de Cloudflare Access, sans compte tiers ni carte
      # bancaire. Cf. le module pour la réserve sur l'absence d'audit.
      authelia = {
        enable = true;
        # Domaine RACINE, à contrecœur : le resserrer supposerait de loger le
        # portail sous cloud. (auth.cloud.…), or le certificat Universal SSL
        # gratuit de Cloudflare ne couvre qu'un niveau de joker et leur edge ne
        # présenterait alors aucun certificat valide.
        #
        # Conséquence assumée : le cookie de session part vers TOUS les
        # sous-domaines, site public compris. Il reste HttpOnly et Secure, donc
        # illisible par du JavaScript, mais le serveur qui héberge le site le
        # reçoit. À revoir si ce domaine héberge un jour quelque chose qui n'est
        # pas sous ton contrôle.
        domain = "nathanchampagne.com";
        portalHost = "auth.nathanchampagne.com";

        # sops ne fait plus que semer : on déclare une personne avec un hachage
        # aléatoire que personne ne connaît, elle pose son mot de passe elle-même
        # par « mot de passe oublié ». Contrepartie : retirer quelqu'un de sops ne
        # le supprime plus du fichier vivant, la révocation demande d'y toucher à
        # la main.
        mutableUsers = true;
        # Sans ça, une authentification réussie depuis le portail lui-même
        # (notamment au retour d'un lien d'enrôlement, qui perd le `rd` de la
        # requête d'origine) laisse l'utilisateur bloqué sur la page du portail.
        defaultRedirect = "https://cloud.nathanchampagne.com";
        # L'ORDRE COMPTE : la première règle qui correspond gagne, et la règle
        # sans `networks` en dernière position sert de filet. Toute origine non
        # listée tombe donc sur `two_factor`, jamais sur un contournement —
        # l'erreur possible est de refuser à tort, pas d'ouvrir.
        #
        # UNE RÈGLE NE FIGURE PAS ICI : le module nextcloud en injecte une, en
        # tête de liste (`mkBefore`), quand `nextcloud.publicSharing.enable` est
        # vrai. C'est un `bypass` sur `cloud.nathanchampagne.com` restreint aux
        # chemins d'une page de partage public — voir `publicSharing` plus haut
        # pour ce qu'elle ouvre et ce qu'elle laisse fermé. Passer avant les deux
        # contournements du VPN est sans effet, ce sont aussi des `bypass`.
        #
        # L'adresse évaluée est celle que nginx force depuis `$remote_addr` (cf.
        # modules/system/server/nextcloud) : l'adresse TCP réelle, qu'un client ne peut
        # pas falsifier par un en-tête. Vérifié en conditions réelles, un
        # X-Forwarded-For fabriqué et envoyé à travers le tunnel ne contourne
        # rien.
        rules = [
          # Atteint depuis le VPN : pas de portail.
          #
          # `192.168.1.0/24` a été RETIRÉ de cette liste, et c'est la seule
          # différence de fond entre les deux plages. Dans le tunnel, `AllowedIPs`
          # en /32 épingle l'adresse source de chaque peer à sa clé publique : un
          # appareil ne peut pas se présenter sous celle d'un autre, et un
          # appareil non appairé n'entre pas du tout. Sur le LAN, rien de tel —
          # n'importe quoi de branché sur le WiFi prend une adresse du /24, donc
          # sautait le second facteur en forçant simplement la résolution vers
          # 192.168.1.32 (DNS statique, `curl --resolve`, l'IP avec le bon
          # `Host`). Le contournement ne reposait sur rien d'autre que le fait
          # que personne n'essaie.
          #
          # CE QUE ÇA NE COÛTE PAS : les clients de synchronisation visent
          # `cloud.vpn.…` (cf. `nextcloud.extraHostNames`), qui passe par la
          # règle suivante — le tunnel de gram et du téléphone est monté en
          # permanence. Et les navigateurs de la maison tombaient DÉJÀ sur le
          # portail : la box ne distribue pas dnsmasq comme résolveur, donc
          # `cloud.` part vers l'edge Cloudflare et revient par le tunnel, où
          # nginx voit 127.0.0.1. Vérifié sur le moteur de règles d'Authelia.
          #
          # Bénéfice à retardement : le jour où le DHCP de la box pointe vers
          # dnsmasq — ce que modules/system/server/dns envisage explicitement —
          # tout le LAN se serait mis à contourner le portail sans un message.
          # La posture ne dépend plus d'un réglage hors dépôt.
          #
          # Si un appareil de la maison doit un jour se passer du portail, la
          # réponse est de l'appairer au VPN, pas de rouvrir le /24.
          {
            domain = "cloud.nathanchampagne.com";
            policy = "bypass";
            networks = [ config.systemSettings.vpn.wireguard.subnet ];
          }
          # Nom du chemin réservé, celui que visent les clients de
          # synchronisation. Il ne résout que vers l'adresse de think dans le
          # tunnel, donc l'atteindre suppose déjà une clé WireGuard déclarée.
          #
          # Les `networks` ne sont pas décoratives pour autant : sans elles la
          # règle serait un contournement INCONDITIONNEL, dont l'innocuité ne
          # tiendrait qu'à un enregistrement DNS et au `httpHostHeader` forcé
          # côté cloudflared — une ligne de configuration ailleurs, et le trou
          # s'ouvrirait sans un message.
          {
            domain = "cloud.vpn.nathanchampagne.com";
            policy = "bypass";
            networks = [ config.systemSettings.vpn.wireguard.subnet ];
          }
          # La MÊME chose, pour think elle-même, et uniquement pour la page
          # d'état. Elle existe pour la sonde de surveillance, qui vérifie que
          # Nextcloud répond vraiment — PHP et la base interrogés — et pas
          # seulement que nginx sert quelque chose.
          #
          # POURQUOI L'ADRESSE DU LAN et non celle du tunnel, alors que la sonde
          # vise bien `cloud.vpn.` donc `10.8.0.1` : le masquerade posé par
          # `networking.nat` pour le tunnel (cf. modules/system/server/vpn/wireguard)
          # correspond à toute source dans `10.8.0.0/24` sans exclure la moindre
          # interface. Un paquet que think émet vers sa propre adresse de tunnel
          # traverse POSTROUTING et ressort en 192.168.1.32. La règle au-dessus
          # ne peut donc PAS s'appliquer, et le chemin du VPN n'est pas
          # empruntable depuis la machine qui le sert.
          #
          # CE QUE ÇA N'OUVRE PAS. `resources` restreint à la seule page d'état,
          # qui ne divulgue que la version de Nextcloud. Et pour se présenter
          # sous cette adresse, il faut la détenir : une source falsifiée
          # n'établit pas de poignée de main TCP. En pratique, seule cette
          # machine correspond.
          #
          # Si le masquerade change un jour et cesse de réécrire ce trafic, la
          # règle précédente reprend la main toute seule — la sonde ne casse pas.
          {
            domain = "cloud.vpn.nathanchampagne.com";
            policy = "bypass";
            networks = [ "${config.systemSettings.network.staticIPv4.address}/32" ];
            resources = [ "^/status\\.php$" ];
          }
          # MÊME MONTAGE que la règle ci-dessus, et pour la même raison : l'appel
          # part de cette machine, donc ressort en 192.168.1.32 après masquerade.
          # Séparée d'elle parce que ce qu'elle ouvre n'est PAS de même nature et
          # devait être pesé à part.
          #
          # Sert l'exporteur Prometheus. L'API `serverinfo` en dit nettement plus
          # que `status.php` : occupation, comptes, partages, versions de PHP et
          # de la base, état des tâches de fond.
          #
          # AUTHELIA N'EST PAS LA SEULE SERRURE, et c'est ce qui rend l'ouverture
          # acceptable : Nextcloud exige sur ce chemin son propre jeton
          # `serverinfo`, que l'exporteur envoie en en-tête `NC-Token`. Retirer
          # le portail ne rend donc pas l'API publique, ça la ramène à
          # l'authentification que l'application fait elle-même. S'y ajoutent la
          # restriction d'origine — qu'une source falsifiée ne franchit pas,
          # faute de poignée de main TCP — et le fait que ce nom n'est ni dans
          # l'ingress du tunnel ni résolvable publiquement, vérifié.
          #
          # CHEMIN EXACT et non préfixe : `serverinfo/` couvrirait tout ce que
          # l'application ajoutera plus tard sous cette racine, y compris des
          # points d'entrée qui n'existent pas encore et que personne ne
          # relirait. Si l'exporteur change d'URL un jour, il tombera en 302 avec
          # du HTML au lieu de JSON — bruyant, donc réparable.
          {
            domain = "cloud.vpn.nathanchampagne.com";
            policy = "bypass";
            networks = [ "${config.systemSettings.network.staticIPv4.address}/32" ];
            resources = [ "^/ocs/v2\\.php/apps/serverinfo/api/v1/info" ];
          }
          # Nom PUBLIC, servi par le tunnel : deux facteurs, sans exception.
          # Aucune `networks` ici, donc cette règle attrape toute origine que les
          # précédentes n'ont pas reconnue.
          {
            domain = "cloud.nathanchampagne.com";
            policy = "two_factor";
          }
          # Grafana. Deux facteurs comme le reste, mais surtout `subject` :
          # c'est la SEULE chose qui empêche un compte familial d'y entrer, et
          # d'y entrer administrateur — Grafana délègue toute son
          # authentification au portail et donne le rôle Admin à quiconque le
          # franchit (cf. modules/system/server/monitoring).
          #
          # Aucune `networks` : contrairement à Nextcloud, rien ici n'a besoin
          # d'un chemin qui contourne. Ni depuis le LAN, ni depuis le VPN.
          #
          # Le nom du compte est celui du fichier d'utilisateurs d'Authelia, pas
          # celui du compte Unix — ils se ressemblent, ils n'ont pas à coïncider.
          # Une valeur fausse ferme l'accès (page « Accès refusé ») au lieu de
          # l'ouvrir, c'est le bon sens de l'erreur.
          {
            domain = "metrics.nathanchampagne.com";
            policy = "two_factor";
            subject = [ "user:nathan" ];
          }
        ];
      };

      # Cf. le module : l'écrasante majorité des compromissions à distance
      # exploitent une faille déjà corrigée. L'URL est distante à dessein, le
      # dépôt local de think n'étant pas forcément à jour.
      autoUpgrade = {
        enable = true;
        flake = "github:Nchpg/.dotfiles#server-think";
      };

      # Adressage posé par systemd-networkd, NetworkManager coupé : sur une
      # machine qu'on ne touche que par le réseau, l'adresse ne doit dépendre ni
      # du bail DHCP de la box ni de l'état persistant d'un démon.
      network.staticIPv4 = {
        address = "192.168.1.32";
        prefixLength = 24;
        gateway = "192.168.1.254";

        # dnsmasq local, et surtout PAS la passerelle, qui est le défaut du
        # module. Sinon think se retrouve avec deux résolveurs concurrents —
        # dnsmasq en portée globale (le module amont pose `resolveLocalQueries`)
        # et la box en portée de lien — et c'est celui qui répond le premier qui
        # gagne. Comme la box ignore les réécritures, `cloud.` et les noms en
        # `.lan.` résolvaient tantôt vers le LAN, tantôt vers l'edge Cloudflare
        # ou vers rien. Une seule entrée : un résolveur concurrent en secours
        # rendrait justement la panne intermittente.
        nameservers = [ "127.0.0.1" ];
      };
    };
  };
}
