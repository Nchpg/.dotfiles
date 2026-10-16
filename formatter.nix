{ pkgs }:

pkgs.writeShellApplication {
  name = "nixfmt-dotfiles";
  runtimeInputs = [
    pkgs.git
    pkgs.findutils
    pkgs.nixfmt
  ];
  text = ''
    if [ "$#" -eq 0 ]; then
      git ls-files -z '*.nix' ':!:*hardware-configuration.nix' | xargs -r0 nixfmt
    else
      exec nixfmt "$@"
    fi
  '';
}
