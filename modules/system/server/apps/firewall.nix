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

  internalApps = lib.filter (n: lib.any (c: c.internal) (lib.attrValues cfg.${n}.containers)) names;
in
{
  config = lib.mkIf (cfg != { }) {
    # Sans cette règle, `nixos-fw` jette le DNS visant la passerelle avant aardvark-dns.
    networking.firewall.extraInputRules =
      lib.concatMapStrings (n: ''
        iifname "${cfg.${n}.bridge}" meta l4proto { tcp, udp } th dport 53 accept comment "resolution des conteneurs de ${n}"
      '') names
      + lib.concatMapStrings (n: ''
        iifname "${cfg.${n}.internalBridge}" meta l4proto { tcp, udp } th dport 53 accept comment "resolution interne de ${n}"
      '') internalApps;

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
      # Réseau interne : entre ses conteneurs seulement, aucune règle vers dehors.
      + lib.concatMapStrings (n: ''
        iifname "${cfg.${n}.internalBridge}" oifname "${cfg.${n}.internalBridge}" accept comment "reseau interne de ${n}"
      '') internalApps
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
