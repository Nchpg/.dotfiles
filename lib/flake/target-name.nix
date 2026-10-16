# Même calcul en bash dans scripts/rebuild.sh.
lib: rec {
  machine = target: "${target.profile}-${target.host}";

  full =
    target:
    machine target + lib.optionalString ((target.variant or "dark") != "dark") "-${target.variant}";
}
