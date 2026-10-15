# Vhost nginx en TLS, avec son certificat ACME :
#
#   services.nginx.virtualHosts."exemple.fr" = myLib.server.mkTlsVhost {
#     locations."/".proxyPass = "http://127.0.0.1:8080";
#   };
#
# `acmeRoot = null` est la raison d'être du helper. `enableACME` pose sinon un
# répertoire de challenge, ce qui bascule le certificat en HTTP-01 et ignore le
# `dnsProvider` de modules/system/server/proxy. Or aucun nom servi ici n'est joignable
# en HTTP depuis internet : les publics passent par le tunnel, les internes ne
# sortent pas du LAN. L'émission échoue alors sans bruit, et nginx démarre avec
# un certificat auto-signé. `null` fait hériter de `security.acme`, donc du
# DNS-01.
#
# Les attributs passés écrasent ces défauts, `forceSSL` compris.
vhost:

{
  forceSSL = true;
  enableACME = true;
  acmeRoot = null;
}
// vhost
