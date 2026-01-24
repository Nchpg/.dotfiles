{ pkgs }:

let
  python = pkgs.python3.withPackages (ps: with ps; [
    # interactive plots
    matplotlib

    # lib gcc needed for some packages
    numpy
    torch
    
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

    pkgs.poetry
    pkgs.jq
  ];

  shellHook = ''
    echo "🐍 Python dev shell ready"
    echo "📓 Run: jupyter lab/notebook"
    export NIX_DEV_SHELL_NAME="python"
    poetry config virtualenvs.in-project true --local 2>/dev/null || true
  '';
}