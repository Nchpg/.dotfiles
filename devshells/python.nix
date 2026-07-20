# Devshell Python minimal : python nix + uv, aucun paquet figé. Chaque projet
# a son .venv uv, wheels/interpréteurs hardlinkés depuis ~/.cache/uv partagé.
# Exposé en fonction pour être étendu par d'autres devshells (cf. xpu.nix).
{
  pkgs,
  name ? "python-dev",
  extraPackages ? [ ],
  extraLibs ? [ ],
  extraLdPaths ? [ ],
  extraEnv ? { },
  extraShellHook ? "",
}:

let
  tool = n: pkgs.writeShellScriptBin n (builtins.readFile (./python + "/${n}.sh"));

  completion =
    destination: source:
    pkgs.writeTextFile {
      name = baseNameOf source;
      inherit destination;
      text = builtins.readFile source;
    };

  # bash découvre via XDG_DATA_DIRS ; fish (patché pour l'ignorer) et zsh
  # passent par NIX_DEVSHELL_{FISH,ZSH}_COMPLETIONS (shell/{fish,zsh}).
  fishCompletions = completion "/share/fish/vendor_completions.d/rmkernel.fish" ./python/completions/rmkernel.fish;
  bashCompletions = completion "/share/bash-completion/completions/rmkernel" ./python/completions/rmkernel.bash;
  zshCompletions = completion "/share/zsh/site-functions/_rmkernel" ./python/completions/_rmkernel;

  # Dlopen par les wheels compilés (numpy, torch...) à l'import. PAS de glibc
  # ici : ça ferait charger sa libc à tout binaire du shell, y compris ceux
  # linkés contre une AUTRE glibc (segfault possible, xpu.nix instancie ce
  # shell en unstable). Les wheels manylinux trouvent leur libc via nix-ld.
  commonLibs = [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.libxml2
    pkgs.ncurses
  ];
in
pkgs.mkShell {
  inherit name;

  packages = [
    pkgs.python313
    pkgs.uv
    pkgs.jq
    fishCompletions
    bashCompletions
    zshCompletions
  ]
  ++ map tool [
    "mkvenv"
    "mkkernel"
    "rmkernel"
    "lskernel"
    "lab"
  ]
  ++ extraPackages;

  LD_LIBRARY_PATH = pkgs.lib.concatStringsSep ":" (
    [ (pkgs.lib.makeLibraryPath (commonLibs ++ extraLibs)) ] ++ extraLdPaths
  );

  shellHook = ''
    export UV_CACHE_DIR="''${UV_CACHE_DIR:-$HOME/.cache/uv}"
    export UV_LINK_MODE="''${UV_LINK_MODE:-hardlink}"

    export XDG_DATA_DIRS="${bashCompletions}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    export NIX_DEVSHELL_FISH_COMPLETIONS="${fishCompletions}/share/fish/vendor_completions.d"
    export NIX_DEVSHELL_ZSH_COMPLETIONS="${zshCompletions}/share/zsh/site-functions"
    export NIX_DEV_SHELL_PYTHON="python"

    echo "🐍 Python dev shell ready (uv)"
    echo
    echo "  venv:      mkvenv [--python 3.X] [nom]"
    echo "  packages:  uv pip install <pkg> / -r requirements.txt"
    echo "  Jupyter:   lab (serveur) · mkkernel / rmkernel / lskernel (venv activé)"
  ''
  + extraShellHook;

  # Via `env` (pas un `//` sur l'attrset) : extraEnv.packages/.shellHook ne
  # peut plus écraser silencieusement les attributs ci-dessus.
  env = extraEnv;
}
