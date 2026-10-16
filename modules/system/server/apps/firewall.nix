{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.apps;

  names = lib.attrNames cfg;

  egressApps = lib.filter (n: cfg.${n}.internetAccess) names;
in
{
  config = lib.mkIf (cfg != { }) {
    # Sans cette règle, `nixos-fw` jette le DNS visant la passerelle avant aardvark-dns.
    networking.firewall.extraInputRules = lib.concatMapStrings (n: ''
      iifname "${cfg.${n}.bridge}" meta l4proto { tcp, udp } th dport 53 accept comment "resolution des conteneurs de ${n}"
    '') names;

    # Via `forwardRules` : `extraForwardRules` serait écarté en silence par le mkForce de `networking.nat`.
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
