# Destinations IPv4 qu'une sortie « vers internet » n'atteint JAMAIS : tout ce
# qui n'est pas de l'internet public — LAN, tunnel, boucle locale, CGNAT,
# lien local, multicast et plage réservée.
#
# Sans cette liste, « sortie internet » voudrait dire « accès au LAN » dès que
# la destination est privée, et le filtrage ne servirait à rien. Partagée entre
# la sortie des peers (modules/system/server/vpn/wireguard) et celle des
# conteneurs (modules/system/server/apps), pour qu'une plage ajoutée à l'une ne
# manque pas à l'autre.
#
# Les adresses du host restent joignables : elles sont délivrées localement et
# ne traversent pas la chaîne de forward, où cette liste s'applique.
[
  "10.0.0.0/8"
  "172.16.0.0/12"
  "192.168.0.0/16"
  "169.254.0.0/16"
  "127.0.0.0/8"
  "100.64.0.0/10"
  "224.0.0.0/4"
  "240.0.0.0/4"
]
