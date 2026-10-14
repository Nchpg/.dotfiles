{ ... }:

# Nextcloud : stockage familial de photos, vidéos et fichiers.
let
  domain = import ./domain.nix;
in
{
  systemSettings = {
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
      hostName = "cloud.${domain}";

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
      extraHostNames = [ "cloud.vpn.${domain}" ];

      # Liens de partage utilisables par quelqu'un d'EXTÉRIEUR : ni compte
      # Authelia, ni clé WireGuard. Sans ça, sa requête arrive par le tunnel,
      # nginx voit 127.0.0.1, et la règle `two_factor` plus bas — celle sans
      # `networks`, qui attrape toute origine — le renvoie sur une page de
      # connexion qu'il ne peut pas franchir.
      #
      # Le module injecte pour ça un `bypass` EN TÊTE des règles d'Authelia
      # (`mkBefore`), limité aux chemins d'une page de partage et au seul nom
      # public — avec le reste de la politique d'accès de Nextcloud, que le
      # module tire de `hostName` et `extraHostNames`.
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
        customCss = builtins.readFile ./nextcloud.css;
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
  };
}
