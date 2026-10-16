{ config, ... }:

let
  domain = import ./domain.nix;
  lanIp = config.systemSettings.network.staticIPv4.address;
in
{
  systemSettings = {
    dns = {
      enable = true;

      # `cloud.vpn.` pointe vers 10.8.0.1 par un A public : le rebinding le rejetterait.
      rebindOkDomains = [ "vpn.${domain}" ];

      overrides = {
        # Absente du DNS public. Si dnsmasq s'arrête, les noms internes sont irrésolvables partout.
        "lan.${domain}" = lanIp;
      };
    };
  };
}
