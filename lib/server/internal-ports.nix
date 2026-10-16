# extraInputRules (nft) et non firewall.interfaces, dont `iifname` sans guillemets casse le motif `en*` ;
# iptables l'ignore en silence. La forme de l'attribut ne doit pas dépendre de `config` (récursion infinie).
lib:

config:

{
  tcp ? [ ],
  udp ? [ ],
}:

let
  iifnames = config.systemSettings.network.internalIifnames;
  perInterface = iifnames != [ ];

  ifaceSet = "{ ${lib.concatMapStringsSep ", " (i: "\"${i}\"") iifnames} }";

  portSet = ports: "{ ${lib.concatMapStringsSep ", " toString ports} }";

  rule =
    proto: ports:
    lib.optionalString (ports != [ ]) ''
      iifname ${ifaceSet} ${proto} dport ${portSet ports} accept
    '';
in
{
  networking.firewall = {
    allowedTCPPorts = lib.mkIf (!perInterface) tcp;
    allowedUDPPorts = lib.mkIf (!perInterface) udp;
    extraInputRules = lib.mkIf perInterface (rule "tcp" tcp + rule "udp" udp);
  };
}
