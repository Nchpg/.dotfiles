{ ... }:

# Adressage de la machine.
{
  systemSettings = {
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
}
