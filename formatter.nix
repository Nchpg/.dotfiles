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
      git ls-files '*.nix' ':!:*hardware-configuration.nix' | xargs -r nixfmt
    else
      exec nixfmt "$@"
    fi
  '';
}
