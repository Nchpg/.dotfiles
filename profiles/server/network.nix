{ ... }:

{
  systemSettings = {
    network.staticIPv4 = {
      address = "192.168.1.32";
      prefixLength = 24;
      gateway = "192.168.1.254";

      # dnsmasq local seul : deux résolveurs concurrents rendraient intermittentes les réécritures que la box ignore.
      nameservers = [ "127.0.0.1" ];
    };
  };
}
