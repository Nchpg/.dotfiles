{ pkgs }:

let
  python = pkgs.python3.withPackages (ps: with ps; [
    # interactive plots
    #matplotlib

    # lib gcc needed for some packages
    #numpy
    #torch
    
    # Jupyter
    ipykernel
    jupyterlab
    notebook
  ]);

  mkvenv = pkgs.writeShellScriptBin "mkvenv" ''
    #!/usr/bin/env bash

    read -p "Nom du venv : " VENV_NAME

    SITE=$(python -c "import site; print(site.getsitepackages()[0])")
    PY_VER=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

    python -m venv "$VENV_NAME"
    echo "$SITE" > "$VENV_NAME/lib/python$PY_VER/site-packages/nix-site-packages.pth"

    echo "✔️ venv '$VENV_NAME' créé et connecté au site-packages Nix."
  '';


  updatevenv = pkgs.writeShellScriptBin "updatevenv" ''
    #!/usr/bin/env bash

    if [ -n "$VIRTUAL_ENV" ]; then
      echo "⚠️ Tu es déjà dans un venv : $VIRTUAL_ENV"
      read -p "Veux-tu continuer ? (y/n) " answer

      if [[ "$answer" =~ ^[Nn]$ ]]; then
        exit 0
      fi
    fi

    VENV_PATH=$(poetry env info --path 2>/dev/null || true)

    if [ -z "$VENV_PATH" ]; then
      read -p "Nom du venv : " VENV_PATH
    fi

    SITE=$(python -c "import site; print(site.getsitepackages()[0])")
    PY_VER=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

    echo "$SITE" > "$VENV_PATH/lib/python$PY_VER/site-packages/nix-site-packages.pth"

    echo "✔️ venv '$VENV_PATH' mis à jour avec le site-packages Nix."
  '';

  mkkernel = pkgs.writeShellScriptBin "mkkernel" ''
    #!/usr/bin/env bash

    read -p "Nom du kernel : " KERNEL_NAME

    python -m ipykernel install --user --name="$KERNEL_NAME" --display-name="Python ($KERNEL_NAME)"

    echo "✔️ Kernel '$KERNEL_NAME' créé."
  '';


  rmkernel = pkgs.writeShellScriptBin "rmkernel" ''
    #!/usr/bin/env bash

    read -p "Nom du kernel : " KERNEL_NAME

    jupyter kernelspec uninstall -f "$KERNEL_NAME"

    echo "✔️ Kernel '$KERNEL_NAME' supprimé."
  '';

  lskernel = pkgs.writeShellScriptBin "lskernel" ''
    #!/usr/bin/env bash

    jupyter kernelspec list --json \
         | jq -r '.kernelspecs | to_entries[] | "\(.key)\t\(.value.spec.argv[0])\t\(.value.resource_dir)"' \
         | column -t
  '';

  buildubuntu = pkgs.writeShellScriptBin "buildubuntu" ''
    #!/usr/bin/env bash

    docker build -f $MY_FLAKE/devshells/Dockerfile.python -t ubuntu-xpu .
  '';


  runubuntu = pkgs.writeShellScriptBin "runubuntu" ''
    #!/usr/bin/env bash


    if [ "$(docker inspect -f '{{.State.Running}}' ubuntu-xpu 2>/dev/null)" = "true" ]; then
      echo "🚀 Le conteneur est déjà en cours d'exécution. Connexion..."
      docker exec \
        -w /root/$(echo "$PWD" | sed "s|^/home/$USERNAME||") \
        -it ubuntu-xpu /entrypoint.sh "$@"
    else
      echo "🚀 Démarrage du conteneur Ubuntu XPU..."
      docker run --rm -it \
          --group-add video \
          --device /dev/dri \
          -e SHELL=$SH \
          -e BTOP=$(whereis btop | awk '{print $2}') \
          -v $HOME:/root \
          -v /tmp/ubuntu-kernel:/root/.local/share/jupyter \
          -v /tmp/ubuntu-cache:/root/.cache \
          -v /nix/store:/nix/store:ro \
          --cap-add SYS_ADMIN \
          --mount type=bind,source=/sys,target=/sys,readonly \
          --mount type=bind,source=/sys/kernel/debug,target=/sys/kernel/debug,readonly \
          --network host \
          -w /root/$(echo "$PWD" | sed "s|^/home/$USERNAME||") \
          --name ubuntu-xpu \
          ubuntu-xpu "$@"
      fi
  '';

  stopubuntu = pkgs.writeShellScriptBin "stopubuntu" ''
    #!/usr/bin/env bash

    docker stop ubuntu-xpu || echo "🚫 Le conteneur n'était pas en cours d'exécution."
  '';

in
pkgs.mkShell {
  name = "python-dev";

  packages = [
    python

    mkvenv
    updatevenv
    mkkernel
    rmkernel
    lskernel
    buildubuntu
    runubuntu
    stopubuntu

    pkgs.poetry
    pkgs.jq

    # LD_LIBRARY_PATH needs to be set for some python packages to find their dependencies
    pkgs.stdenv.cc.cc.lib
    pkgs.glibc
    pkgs.zlib
    pkgs.libxml2
    pkgs.ncurses
  ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.glibc
    pkgs.zlib
    pkgs.libxml2
    pkgs.ncurses
  ];

  shellHook = ''
    echo "🐍 Python dev shell ready"
    echo "📓 Run: jupyter lab/notebook"
    export NIX_DEV_SHELL_PYTHON="python"
    poetry config virtualenvs.in-project true --local 2>/dev/null || true
  '';
}
