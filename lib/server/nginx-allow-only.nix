# Filtrage par source d'un vhost nginx, au format `allow` :
#
#   extraConfig = ''
#     ${myLib.server.nginxAllowOnly [ "10.8.0.0/24" ]}
#   '';
#
# donne une ligne `allow` par source puis `deny all;`, sans saut de ligne
# final. Posé au niveau `server`, les locations en héritent, et une location
# ajoutée plus tard ne peut pas l'oublier.
#
# `allow` ne regarde que l'adresse de la connexion TCP (`$remote_addr`), jamais
# un en-tête : une décision d'accès ne s'appuie sur rien que le client puisse
# écrire.
lib: networks: "${lib.concatMapStrings (n: "allow ${n};\n") networks}deny all;"
