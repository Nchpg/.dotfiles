{
  config,
  lib,
  myLib,
  ...
}:

# Pare-feu des applications : le DNS de leurs conteneurs en entrée, leur trafic
# interne et leur éventuelle sortie vers internet en traversée.
let
  cfg = config.systemSettings.apps;

  names = lib.attrNames cfg;

  egressApps = lib.filter (n: cfg.${n}.internetAccess) names;
in
{
  config = lib.mkIf (cfg != { }) {
    # DNS ENTRE CONTENEURS, ouvert dans le pare-feu du host.
    #
    # Sans cette règle, un conteneur ne résout AUCUN de ses pairs, et le seul
    # symptôme est une application qui ne démarre pas. Le diagnostic est
    # trompeur de bout en bout : le réseau existe, `dns_enabled` est vrai,
    # aardvark-dns tourne et écoute sur la passerelle, son fichier de zone
    # contient les bons noms et les bons alias — et rien ne répond.
    #
    # POURQUOI. La requête part du conteneur vers la passerelle du pont, qui est
    # une adresse DU HOST : elle arrive donc dans la chaîne d'entrée du pare-feu,
    # pas dans une chaîne de traversée. netavark pose bien un `accept` pour
    # elle, mais DANS SA PROPRE TABLE — et en nftables, toutes les tables
    # accrochées au même point sont évaluées, un `drop` dans l'une annulant un
    # `accept` dans l'autre. `nixos-fw` jette le paquet avant qu'aardvark-dns le
    # voie.
    #
    # C'est le miroir de l'avertissement de modules/system/network, qui prévoit
    # qu'un conteneur devienne joignable en CONTOURNANT le pare-feu. Ici c'est
    # l'inverse : le pare-feu bloque un trafic interne légitime.
    #
    # Portée aussi étroite que possible : seulement le port 53, et seulement
    # depuis les ponts NOMMÉMENT désignés — pas un joker `podman*`, qui
    # couvrirait aussi le réseau par défaut de podman et tout pont futur créé
    # hors de ce module. Les conteneurs n'obtiennent aucun autre accès au host.
    networking.firewall.extraInputRules = lib.concatMapStrings (n: ''
      iifname "${cfg.${n}.bridge}" meta l4proto { tcp, udp } th dport 53 accept comment "resolution des conteneurs de ${n}"
    '') names;

    # TRAFIC ENTRE CONTENEURS, dans la chaîne de TRAVERSÉE cette fois.
    #
    # Même cause que la règle ci-dessus, autre chaîne — et il faut les deux. Une
    # requête vers aardvark-dns vise la passerelle du pont, donc une adresse du
    # host : elle arrive en ENTRÉE. Une requête d'un conteneur vers un autre
    # traverse le host : elle passe par la chaîne de FORWARD, que
    # `networking.firewall.filterForward` fait jeter par défaut.
    #
    # Le symptôme est particulièrement trompeur : la résolution fonctionne, le
    # conteneur obtient bien l'adresse de son pair, ouvre une connexion — et
    # attend. Les paquets sont jetés sans refus, donc rien ne répond jamais et
    # l'appelant meurt sur un délai. Vu ici comme un 504 après soixante
    # secondes, le délai par défaut de nginx, sans qu'aucune requête n'ait jamais
    # atteint le service visé.
    #
    # UNE RÈGLE PAR APPLICATION, entrée et sortie sur LE MÊME pont — et c'est le
    # point le plus important de tout ce module.
    #
    # La version précédente écrivait `iifname "podman*" oifname "podman*"`, sur
    # l'affirmation que netavark isolait déjà les applications entre elles.
    # C'ÉTAIT FAUX : sa page de manuel dit que l'option `isolate` « bloque le
    # trafic entre les réseaux QUI L'ONT ACTIVÉE », et elle n'est pas active par
    # défaut. Rien ne séparait donc deux applications sinon le `drop` de
    # `nixos-fw` — précisément celui que cette règle levait. Une base de données
    # d'une application devenait joignable depuis le conteneur d'une autre.
    #
    # Nommer les ponts permet d'exiger que la source ET la destination soient sur
    # le même, ce qui rend le cloisonnement structurel plutôt que déclaratif.
    # Combiné à `isolate=true` posé à la création, deux barrières indépendantes
    # le tiennent.
    #
    # CE QUI RESTE FERMÉ, à dessein : la sortie vers internet depuis un
    # conteneur, sauf pour les applications qui la déclarent (`internetAccess`).
    # Les autres échouent bruyamment le jour où elles essaient, plutôt que de
    # disposer en silence d'un accès que personne ne leur a accordé.
    #
    # Par `forwardRules` et non `networking.firewall.extraForwardRules`, que
    # `modules/system/server/vpn/wireguard` a besoin de soustraire à la règle
    # sans restriction de `networking.nat` : une définition ordinaire de
    # l'option amont serait écartée EN SILENCE par le `mkForce` qui l'en
    # protège. Constaté, du temps où chaque module forçait lui-même : la règle
    # n'apparaissait pas dans le ruleset produit. Cf. la description de
    # `systemSettings.network.forwardRules`.
    systemSettings.network.forwardRules =
      lib.concatMapStrings (
        n:
        let
          br = cfg.${n}.bridge;
        in
        ''
          iifname "${br}" oifname "${br}" accept comment "trafic interne a ${n}"
        ''
      ) names
      # La sortie vers internet, pour les seules applications qui la
      # déclarent (cf. `internetAccess`). Le masquerade est posé par netavark
      # sur chaque réseau qu'il crée, rien à ajouter de ce côté.
      + lib.concatMapStrings (
        n:
        let
          br = cfg.${n}.bridge;
        in
        ''
          iifname "${br}" oifname != "${br}" ip daddr != { ${lib.concatStringsSep ", " myLib.server.nonRoutableIPv4} } accept comment "${n} vers internet"
        ''
      ) egressApps;
  };
}
