lib: pkgs: file:
pkgs.fetchurl { inherit (lib.importJSON file) url hash; }
