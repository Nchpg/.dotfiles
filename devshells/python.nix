# Devshell Python minimal : python nix + uv, aucun paquet figé. Chaque projet
# a son .venv uv ; wheels et interpréteurs sont téléchargés une fois puis
# hardlinkés depuis le cache partagé ~/.cache/uv. Les outils (mkvenv,
# mkkernel, …) sont de vrais scripts dans python/.
#
# Exposé en fonction pour être étendu par d'autres devshells — voir xpu.nix.
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

  # Complétion tab des noms de kernels. bash la découvre via XDG_DATA_DIRS ;
  # le fish nixpkgs (patché pour ignorer XDG_DATA_DIRS) et zsh passent par les
  # variables NIX_DEVSHELL_{FISH,ZSH}_COMPLETIONS, consommées par
  # modules/user/shell/{fish/.fish,zsh/.zshrc}.
  # NB : fish autoloade par nom de commande → fichier nommé <commande>.fish.
  fishCompletions = completion "/share/fish/vendor_completions.d/rmkernel.fish" ./python/completions/rmkernel.fish;
  bashCompletions = completion "/share/bash-completion/completions/rmkernel" ./python/completions/rmkernel.bash;
  zshCompletions = completion "/share/zsh/site-functions/_rmkernel" ./python/completions/_rmkernel;

  # Libs que la plupart des wheels compilés (numpy, torch, …) dlopen à l'import.
  commonLibs = [
    pkgs.stdenv.cc.cc.lib
    pkgs.glibc
    pkgs.zlib
    pkgs.libxml2
    pkgs.ncurses
  ];
in
pkgs.mkShell (
  {
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
      # Cache uv partagé entre devshells/projets, hardlinks vers les .venv.
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
  }
  // extraEnv
)
