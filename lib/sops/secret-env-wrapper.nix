# writeShellApplication : un `cat` en échec ne doit pas lancer le CLI avec un jeton vide.
lib:
{
  pkgs,
  config,
  name,
  secret,
  envVar,
  exec,
  env ? { },
}:
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    ${envVar}="$(cat ${config.sops.secrets.${secret}.path})"
    export ${envVar}
    ${
      lib.concatStrings (lib.mapAttrsToList (n: v: "export ${n}=${lib.escapeShellArg v}\n") env)
    }exec ${exec} "$@"
  '';
}
