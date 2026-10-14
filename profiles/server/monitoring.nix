{ ... }:

# Surveillance : métriques, journaux, sondes et alertes.
let
  domain = import ./domain.nix;
in
{
  systemSettings = {
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
        hostName = "metrics.${domain}";
        # Publié par le tunnel, comme Nextcloud et le portail. Sans ça les
        # courbes ne se regardent que depuis la maison ou le VPN — c'est-à-dire
        # jamais au moment où l'on en a besoin, qui est celui où l'on est
        # ailleurs et où quelque chose ne va pas.
        public = true;
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

      # Les JOURNAUX à côté des courbes, dans la même interface et sur le même
      # axe de temps. Ce que ça change concrètement : une alerte Discord
      # arrivait jusqu'ici avec `journalctl -u <unité> -n 50` en pied de
      # message, commande qu'on ne peut pas taper depuis un téléphone. La
      # réponse est maintenant à deux clics de la courbe qui a décroché.
      #
      # Aucun port ouvert, aucun compte à créer, rien qui sorte de la maison —
      # contrairement au chemin Datadog, dont c'est précisément le produit
      # payant. Les deux cohabitent sans se gêner : Datadog garde les métriques
      # vues de l'extérieur, Loki garde le texte.
      logs.enable = true;

      # Trente jours par défaut, gardés tels quels. Le journal sert à
      # comprendre un incident récent ; c'est la COURBE qu'on relit à trois
      # mois, et elle est chez Prometheus pour quatre-vingt-dix jours.
      #
      # Rien dans `excludeUnits` non plus : on collecte tout. La sonde blackbox
      # produit à elle seule un tiers des lignes, toutes normales, et c'est le
      # premier candidat si le volume devient un jour un sujet — il ne l'est
      # pas à 4 Mo par jour.

      # Jeton `serverinfo`, produit par l'instance et rangé dans les secrets.
      # DÉCLARER LA CLÉ D'ABORD : c'est cette déclaration qui fait apparaître
      # la règle de création dans le .sops.yaml du dépôt privé (bloc généré,
      # posé tout seul par `secrets edit`), et sans règle sops refuse de créer
      # le fichier. Dans l'ordre inverse, `secrets edit` refuse et le dit.
      apps.nextcloudTokenKey = "nextcloud/serverinfo_token";
    };

    proxy.sites."metrics.${domain}" = {
      # Grafana : sans cette ligne, regarder ses courbes depuis le salon fait sortir la
      # requête jusqu'à l'edge Cloudflare pour redescendre par le tunnel vers
      # une machine qui est sur le même commutateur.
      #
      # `public` reste faux ICI : la route du tunnel est posée par le module de
      # surveillance lui-même (`grafana.public` ci-dessus).
      lanShortcut = true;

      # CE QUE CES SONDES DISENT ET NE DISENT PAS. Elles partent de think, où
      # dnsmasq réécrit les noms publics vers le LAN : elles tapent donc sur
      # nginx en direct et ne traversent PAS le tunnel. Une panne de
      # cloudflared reste invisible ici — c'est le dead man's switch, jugé
      # depuis l'extérieur, qui couvre ce cas.
      probes.grafana.module = "http_authelia";
    };

    authelia.rules = [
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
        domain = "metrics.${domain}";
        policy = "two_factor";
        subject = [ "user:nathan" ];
      }
    ];
  };
}
