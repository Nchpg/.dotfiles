lib: rec {
  hostsFor =
    deployments: profiles:
    lib.attrNames (lib.filterAttrs (_host: runs: lib.any (p: lib.elem p profiles) runs) deployments);

  audience =
    {
      deployments,
      secretProfiles,
      host,
    }:
    name: if secretProfiles ? ${name} then hostsFor deployments secretProfiles.${name} else [ host ];
}
