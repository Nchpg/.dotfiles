# Un bump touchant sway/lock.c fait échouer le build : rebaser ou retirer le patch.
myLib: _final: prev: {
  sway-unwrapped = myLib.packaging.mkGuardedPatch {
    package = prev.sway-unwrapped;
    patch = ./sway-smooth-lock.patch;
    files = {
      "sway/lock.c" = "d147eebafe77eb2986a49dffa7a12f88d50e8793e158aa1a28192771a70a10f5";
      "include/sway/server.h" = "80af1b5ae13164f4d09851201a931d8aea7a3838b093391fc94e8337e4c1d3e5";
    };
    where = "overlays/sway/default.nix";
  };
}
