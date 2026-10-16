# acmeRoot = null : sinon enableACME bascule en HTTP-01, injoignable ici ; hérite du DNS-01 de security.acme.
vhost:

{
  forceSSL = true;
  enableACME = true;
  acmeRoot = null;
}
// vhost
