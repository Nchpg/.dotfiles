# Remplace le requireFile (licence Synaptics) par un fetchurl : seule l'URL est à maintenir au bump.
final: prev: {
  displaylink = prev.displaylink.overrideAttrs (old: {
    src = final.fetchurl {
      inherit (old.src) name;
      hash = old.src.outputHash;
      url = "https://www.synaptics.com/sites/default/files/exe_files/2025-09/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.2-EXE.zip";
    };
  });
}
