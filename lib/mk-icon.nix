# Codepoint hexa -> glyphe, BMP ou plan astral (icônes Material Design >
# U+FFFF -> paire de substitution UTF-16). Évite de taper le glyphe en dur
# dans les sources (il se ferait stripper au copier-coller / au formatage).
#
# `lib` est pré-appliqué par lib/default.nix : usage direct `myLib.mkIcon "f009a"`.
lib:

hex:
let
  digits = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    "a" = 10;
    "b" = 11;
    "c" = 12;
    "d" = 13;
    "e" = 14;
    "f" = 15;
  };
  toInt = s: lib.foldl (acc: ch: acc * 16 + digits.${lib.toLower ch}) 0 (lib.stringToCharacters s);
  toHex4 = x: lib.toLower (lib.fixedWidthString 4 "0" (lib.toHexString x));
  n = toInt hex;
in
if n <= 65535 then
  builtins.fromJSON ''"\u${toHex4 n}"''
else
  let
    v = n - 65536;
    hi = 55296 + (v / 1024);
    lo = 56320 + (v - (v / 1024) * 1024);
  in
  builtins.fromJSON ''"\u${toHex4 hi}\u${toHex4 lo}"''
