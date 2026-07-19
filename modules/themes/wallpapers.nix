# Métadonnées de thème hors spec base16 : fond d'écran par défaut, consommé
# par stylixSettings (modules/themes/default.nix).
#
# La polarité (dark/light) n'est PAS ici : elle se lit dans le champ
# `variant:` de chaque yaml (cf. themes.polarity), ce qui évite d'entretenir
# une table pour les ~500 thèmes amont.
#
# themeWallpaper : nom de thème -> nom d'entrée du registre ci-dessous.
# Volontairement PARTIEL. Un thème sans entrée reste utilisable (stylix vit
# sans image). Surchargeable par profil/user via
# systemSettings.stylix.wallpaper / userSettings.stylix.wallpaper.
{
  themeWallpaper = {
    alph = "alph";
    ashes = "ashes";
    atelier-cave = "atelier-cave";
    atelier-dune = "atelier-dune";
    atelier-estuary = "atelier-estuary";
    atelier-forest = "atelier-forest";
    atelier-heath = "atelier-heath";
    atelier-lakeside = "atelier-lakeside";
    atelier-plateau = "atelier-plateau";
    atelier-savanna = "atelier-savanna";
    atelier-seaside = "atelier-seaside";
    atelier-sulphurpool = "atelier-sulphurpool";
    ayu-dark = "ayu-dark";
    bespin = "bespin";
    caret = "caret";
    catppuccin-frappe = "catppuccin-frappe";
    catppuccin-mocha = "catppuccin-mocha";
    darkmoss = "darkmoss";
    doom-one = "doom-one";
    dracula = "dracula";
    ember = "ember";
    emil = "emil";
    eris = "eris";
    eva = "eva";
    everforest = "everforest";
    fairy-floss = "fairy-floss";
    gigavolt = "gigavolt";
    gruvbox-dark-custom = "gruvbox-dark";
    gruvbox-dark-hard = "gruvbox-dark";
    gruvbox-dark-medium = "gruvbox-dark";
    gruvbox-light-hard = "gruvbox-light";
    gruvbox-light-medium = "gruvbox-light";
    helios = "helios";
    henna = "henna";
    horizon-dark = "horizon-dark";
    io = "io";
    isotope = "isotope";
    manegarm = "manegarm";
    material-vivid = "material-vivid";
    miramare = "miramare";
    monokai = "monokai";
    nord = "nord";
    oceanic-next = "oceanic-next";
    old-hope = "old-hope";
    orichalcum = "orichalcum";
    outrun-dark = "outrun-dark";
    selenized-dark = "solarized-dark";
    selenized-light = "solarized-light";
    solarized-dark = "solarized-dark";
    solarized-light = "solarized-light";
    spaceduck = "spaceduck";
    stella = "stella";
    summerfruit-dark = "summerfruit-dark";
    tomorrow-night = "tomorrow-night";
    twilight = "twilight";
    ubuntu = "ubuntu";
    uwunicorn = "uwunicorn";
    windows-95 = "windows-95";
    woodland = "woodland";
    xcode-dusk = "xcode-dusk";
  };

  # Registre central des wallpapers : nom → source fetchurl. Une URL morte se
  # corrige ICI, une seule fois ; un fond peut être partagé par plusieurs
  # thèmes (cf. gruvbox-dark) ou n'appartenir à aucun.
  #
  # Deux formes d'entrée :
  #   <nom> = { url = "..."; sha256 = "..."; };   # téléchargé (fetchurl)
  #   <nom>.path = ./wallpapers/<fichier>;        # fichier local du repo
  registry = {
    # Fond perso de nchpg (ex-wallpaper.png de la config sway) : pagode du
    # temple Daigo-ji à Kyoto. Rattaché à aucun thème — sélectionné via
    # userSettings.stylix.wallpaper = "custom-kyoto".
    custom-kyoto.path = ./wallpapers/custom-kyoto.png;

    alph = {
      url = "https://r4.wallpaperflare.com/wallpaper/132/401/75/painting-clouds-sky-landscape-wallpaper-57bfb2f40fd59f8acf4284a1e191c785.jpg";
      sha256 = "sha256-ZM0X0IXsUwAgxdZileDOol8kBANxjW8oGrgha3OFjYE=";
    };
    ashes = {
      url = "https://images.hdqwalls.com/wallpapers/anime-road-to-city-everlasting-summer-4k-ep.jpg";
      sha256 = "sha256-ul7ecqPw9bSr+JRSd+3OlKwVfB+5378L7ObYydJDsgQ=";
    };
    atelier-cave = {
      url = "https://images.hdqwalls.com/wallpapers/anime-girl-angel-ring-5k-7c.jpg";
      sha256 = "sha256-AVPJYFLEQr9x1V2yQLkMc1g7GqcBPJiKRFuj8MaKe5c=";
    };
    atelier-dune = {
      url = "https://images.hdqwalls.com/wallpapers/tengen-toppa-gurren-lagann-4k-1m.jpg";
      sha256 = "sha256-wplFIlIIYHTofJMuBLtpSWwrFyzz8ao1Gq4wGqgz7qY=";
    };
    atelier-estuary = {
      url = "https://r4.wallpaperflare.com/wallpaper/352/194/322/digital-art-artwork-dragon-skeleton-wallpaper-15f339ed090d16293ff528ba738d87f9.jpg";
      sha256 = "sha256-f97njdnllbsnnIjZnz/j0l2qIFWbEsGF2QtV1JTF2Yg=";
    };
    atelier-forest = {
      url = "https://w.wallhaven.cc/full/72/wallhaven-72p97v.jpg";
      sha256 = "sha256-+ayGF3G14PfZwZnIeqCpnV/awnwdpue3OBmJYTirb2U=";
    };
    atelier-heath = {
      url = "https://r4.wallpaperflare.com/wallpaper/861/102/512/moonlight-fantasy-landscape-moon-full-moon-wallpaper-0960b8dd31ca4d2b96b7684fd021067d.jpg";
      sha256 = "sha256-KuPdCD5IT0/LJghqQKuAFiFtztp+FyRJRdsjdrAzPI8=";
    };
    atelier-lakeside = {
      url = "https://r4.wallpaperflare.com/wallpaper/410/867/750/vector-forest-sunset-forest-sunset-forest-wallpaper-b3abc35d0d699b056fa6b247589b18a8.jpg";
      sha256 = "sha256-8ytn00rZUiJxgtjXqTxtR7qusokxjY68u+UiWuwD8Bs=";
    };
    atelier-plateau = {
      url = "https://r4.wallpaperflare.com/wallpaper/428/434/322/art-computer-digital-art-concept-art-wallpaper-b9a0c85d016a9d0b66a7b84f509116ad.jpg";
      sha256 = "sha256-GL4QjCZFLAgsMM05cLqAx9Sd293NfU79azFhuzBGhW0=";
    };
    atelier-savanna = {
      url = "https://r4.wallpaperflare.com/wallpaper/760/955/638/artwork-landscape-sky-mountains-wallpaper-78664db880d01c78404c214e28e2847a.jpg";
      sha256 = "sha256-0ubzlyIj3Uz9vQa+qvz/+q/1trgbNUEpQysqtEFs54g=";
    };
    atelier-seaside = {
      url = "https://r4.wallpaperflare.com/wallpaper/714/495/609/landscape-artwork-digital-art-fantasy-art-wallpaper-9960e89d112afd2ba6e738ff70b1e63d.jpg";
      sha256 = "sha256-GcHU4qYRGFubobNENwp8prpd/da4tzHwRyN+rsH2dYA=";
    };
    atelier-sulphurpool = {
      url = "https://r4.wallpaperflare.com/wallpaper/13/960/9/digital-art-fantasy-art-colorful-space-art-wallpaper-99330d2ae61a6c661d5ea4793fc17511.jpg";
      sha256 = "sha256-mnh2uKy3PO0otUdTw4Bv4JDnMYj/m7Gt7P7XDJb2+c0=";
    };
    ayu-dark = {
      url = "https://w.wallhaven.cc/full/zy/wallhaven-zy8wwo.jpg";
      sha256 = "sha256-0BiSjEZnwh6KnWuNau+9lf1PVBYRnq228l4OA/nm5YI=";
    };
    bespin = {
      url = "https://r4.wallpaperflare.com/wallpaper/597/635/621/sword-fantasy-forest-twilight-river-hd-wallpaper-f98078cd21caad7b46d7b83fb021566d.jpg";
      sha256 = "sha256-uVPfyCXyyBVSfgbiQy5rhngNjuAmxk89btary3Iiwq0=";
    };
    caret = {
      url = "https://raw.githubusercontent.com/D3Ext/aesthetic-wallpapers/main/images/gruvbox_retrocity.png";
      sha256 = "sha256-sHr/BFWhRvzr0gVD73E7fSlGG8/9G2D3/M46UNf+qvU=";
    };
    catppuccin-frappe = {
      url = "https://images3.alphacoders.com/126/1266078.jpg";
      sha256 = "sha256-krJtLOP+9mV87l0/XCkqtk558VeHP3ZjThLEh97ESek=";
    };
    catppuccin-mocha = {
      url = "https://images7.alphacoders.com/126/1266081.jpg";
      sha256 = "sha256-wCXKHemZYxVYnWVwh6Ng/nGlUroRotXgvcOdSfqRPeo=";
    };
    darkmoss = {
      url = "https://w.wallhaven.cc/full/0w/wallhaven-0wrp3p.jpg";
      sha256 = "sha256-JGEY8mhpXNLCXPoWCXvGWbLkfkpeZRl+hxiLPGwVmSQ=";
    };
    doom-one = {
      url = "https://r4.wallpaperflare.com/wallpaper/834/299/692/city-lights-girl-moon-wallpaper-e178a9faa68bf35ee7e3f2afc50e43fc.jpg";
      sha256 = "sha256-gYGwWAgRjpZQGUMZsw5GJ11dKKrU6/bX3xcKXQZVOac=";
    };
    dracula = {
      url = "https://images.hdqwalls.com/wallpapers/heights-are-not-scary-5k-7s.jpg";
      sha256 = "sha256-rgJkrd7S/uWugPyBVTicbn6HtC8ru5HtEHP426CRSCE=";
    };
    ember = {
      url = "https://w.wallhaven.cc/full/x8/wallhaven-x82ldl.jpg";
      sha256 = "sha256-3HX1ADHBXR50YGmS0Y7i6n19AUX74sy8tJnOLZzMjEw=";
    };
    emil = {
      url = "https://r4.wallpaperflare.com/wallpaper/535/845/69/digital-art-artwork-fantasy-art-planet-sun-hd-wallpaper-d866fd38b0b06cd800cc016ed8d284fa.jpg";
      sha256 = "sha256-qD/yPZHqDgpMwhqPNtyO4r3dtAnR9oMx6DLizZvDHpk=";
    };
    eris = {
      url = "https://r4.wallpaperflare.com/wallpaper/531/951/621/digital-digital-art-artwork-illustration-minimalism-hd-wallpaper-08869d3810a06c28a09cf1be487204ea.jpg";
      sha256 = "sha256-w8BF0TvHX0LBZqPvgKJi0Zg6aWIKLgS/jyoRRu6M54A=";
    };
    eva = {
      url = "https://w.wallhaven.cc/full/13/wallhaven-13m9z9.jpg";
      sha256 = "sha256-eWXpVrveYCG8cq3Pu/734DbO8tdofjUUIlrSNfOUTlM=";
    };
    everforest = {
      url = "https://w.wallhaven.cc/full/83/wallhaven-839ppy.png";
      sha256 = "sha256-xtnvDoIs+kKvRXo/L+ifq/q+yWNeqh1EUsaRkmDTtz4=";
    };
    fairy-floss = {
      url = "https://w.wallhaven.cc/full/rr/wallhaven-rrgydw.jpg";
      sha256 = "sha256-bv9c0RWYGT3EX8tfqzanQ8ZwVNcxbpmRYv5ymk7hido=";
    };
    gigavolt = {
      url = "https://r4.wallpaperflare.com/wallpaper/240/608/936/anime-original-bird-building-city-hd-wallpaper-d3ead31ac8d55c6d18129e0391683261.jpg";
      sha256 = "sha256-5H/VP5qzdJQgpzndacXt12wbFcfxaWDqAoZxFSetekg=";
    };
    gruvbox-dark = {
      url = "https://w.wallhaven.cc/full/39/wallhaven-3911w9.jpg";
      sha256 = "sha256-dBmKkLR8yI1W7d9IRTOaErHf0KApSq0UsY5LWxAaSuA=";
    };
    gruvbox-light = {
      url = "https://w.wallhaven.cc/full/dp/wallhaven-dppjk3.jpg";
      sha256 = "sha256-12U/Z4HGv31MihexuwCnTX6mcfOvkdUsMghahKzoPBE=";
    };
    helios = {
      url = "https://images.hdqwalls.com/wallpapers/one-last-time-8h.jpg";
      sha256 = "sha256-KDp90rltTtMEiQtsA8VPq2Msi/D51mPPEdo1tiRIo7E=";
    };
    henna = {
      url = "https://r4.wallpaperflare.com/wallpaper/71/196/981/digital-art-minimalism-nature-hills-wallpaper-88f64d4860b08ca8d02c41def8f2349a.jpg";
      sha256 = "sha256-0skcwkVzZ3VdLImlMUT9sab3631vTttKk8LupTqM71Q=";
    };
    horizon-dark = {
      url = "https://r4.wallpaperflare.com/wallpaper/966/951/802/digital-digital-art-artwork-illustration-fantasy-art-hd-wallpaper-4856fd282030fc78505c71cea802646a.jpg";
      sha256 = "sha256-a09gjqeVRB6JlDvis+QRDquNuefDAj/NHw9FHAj8yys=";
    };
    io = {
      url = "https://images.hdqwalls.com/wallpapers/aurora-s-embrace-a-borealis-beauty-in-anime-ub.jpg";
      sha256 = "sha256-GjM/Bu0zispdtPCFPzAk+zGlKYYg5XwTTxZ0TXOW9Fg=";
    };
    isotope = {
      url = "https://r4.wallpaperflare.com/wallpaper/108/140/869/digital-digital-art-artwork-fantasy-art-drawing-hd-wallpaper-d8b62d28c0f06c48d03c114ec8f2b4aa.jpg";
      sha256 = "sha256-zYzUBaCvYVgmfw1/irgleRpTIrm4dsP8F3RmR8m/DBk=";
    };
    manegarm = {
      url = "https://r4.wallpaperflare.com/wallpaper/86/440/1017/digital-digital-art-artwork-illustration-drawing-hd-wallpaper-60cb37b6dd08e0d36729f856e7bcb083.jpg";
      sha256 = "sha256-JdL2TfIJCQdzmoex/uqJzJJ1V8nVmTWRBC296O8ynnw=";
    };
    material-vivid = {
      url = "https://w.wallhaven.cc/full/e7/wallhaven-e7z71l.jpg";
      sha256 = "sha256-LBgsEyiFJUv1FT26dq2ACIFtQZXTIeKtEk92cLoNv4g=";
    };
    miramare = {
      url = "https://w.wallhaven.cc/full/v9/wallhaven-v9qy9l.jpg";
      sha256 = "sha256-3Yo3qdzMRQGh/C3Qo5gpS2V1D4u1MptmqsXb+QO9EsE=";
    };
    monokai = {
      url = "https://w.wallhaven.cc/full/xl/wallhaven-xl225z.png";
      sha256 = "sha256-zQXOIdWGxvwh6KFeiWwfRFNqIHtWzCsVHK8ondcYi2w=";
    };
    nord = {
      url = "https://r4.wallpaperflare.com/wallpaper/976/74/465/multiple-display-mountains-snow-nature-wallpaper-c1b4ba2a902ec5b27032d3c4aefe604d.jpg";
      sha256 = "sha256-+zlCkbmA6GwJStrL1+BP08GezbhDB07TTYBgu86xWOw=";
    };
    oceanic-next = {
      url = "https://r4.wallpaperflare.com/wallpaper/1024/162/573/nature-beach-ocean-sea-wallpaper-c8660d98d0b02c48b02cb11e3882646a.jpg";
      sha256 = "sha256-F67ItsyBFzcU3KNvqwL8DEeXHZlLpmg8xRT8Fr0dolI=";
    };
    old-hope = {
      url = "https://r4.wallpaperflare.com/wallpaper/218/1018/501/star-wars-star-wars-the-rise-of-skywalker-jedi-kylo-ren-lightsaber-hd-wallpaper-534b63fd3d29abf5efe66267283ba8c8.jpg";
      sha256 = "sha256-3Z8kpA+JBs3nQhe+zUZF0zoXFGbJCfePp3/RzpcuN6Q=";
    };
    orichalcum = {
      url = "https://wallpapers.com/images/hd/alluring-sunset-anime-scenery-r2gmgtcp8h9iwo9u.webp";
      sha256 = "sha256-jOd9SznQTa8AoO6cZGy0LhN8lBadrRf60FvyCEs2tLo=";
    };
    outrun-dark = {
      url = "https://r4.wallpaperflare.com/wallpaper/586/965/67/night-sky-illustration-futuristic-art-night-wallpaper-88366d08c0d00c08207cf12ef892b49a.jpg";
      sha256 = "sha256-wySC8BjvJKZAnbGOeyyp1xwt/EMAwsTON0os6n1/fp8=";
    };
    solarized-dark = {
      url = "https://r4.wallpaperflare.com/wallpaper/474/140/1011/stars-sea-clouds-night-wallpaper-7bede9caa0ccfc6d8a1eb0759c9972b0.jpg";
      sha256 = "sha256-ugnjfKCIpyH0enWB5l52j+1pWG1FwX8X5BeRh68NRuE=";
    };
    solarized-light = {
      url = "https://r4.wallpaperflare.com/wallpaper/790/734/537/landscape-digital-art-coast-sky-wallpaper-2fbce811ee788644e4f742a5f338be69.jpg";
      sha256 = "sha256-QFWU0b/dKHA1duzpDFZ4PfTt1ku4ZnekUnUZKX1drxQ=";
    };
    spaceduck = {
      url = "https://w.wallhaven.cc/full/6d/wallhaven-6d5k6x.jpg";
      sha256 = "sha256-+xl4H3UiVmMRNvMhIlaLdVTYYqnSyCTSX2UOTGsDQ8c=";
    };
    stella = {
      url = "https://r4.wallpaperflare.com/wallpaper/662/963/756/artwork-night-stars-sailing-ship-wallpaper-f8e6cdf800802ca8b0acb18ea86274ca.jpg";
      sha256 = "sha256-ZdzYsYawW2pINFG8bHLBd62iyD4p/9Iw09H3pB0SUyw=";
    };
    summerfruit-dark = {
      url = "https://w.wallhaven.cc/full/rr/wallhaven-rrow61.png";
      sha256 = "sha256-/3k+6paAH2Z36f5g4eeK62+dXF+8szDj4EO8vXYRg8o=";
    };
    tomorrow-night = {
      url = "https://w.wallhaven.cc/full/28/wallhaven-28867y.png";
      sha256 = "sha256-G8wLZitUlaquirgCtHCFu6dQHJophD8/c7INNMhh49M=";
    };
    twilight = {
      url = "https://w.wallhaven.cc/full/q6/wallhaven-q6m557.png";
      sha256 = "sha256-5s6cyM2rv/uFW1upqruYiqcofEakdHylAEy65OfArZ4=";
    };
    ubuntu = {
      url = "https://images.hdqwalls.com/download/sea-of-dreamscape-r4-1920x1080.jpg";
      sha256 = "sha256-W2v1uQngxqcQ+xBSTRxo7blKzgaL1pW06E6n0vP2Z88=";
    };
    uwunicorn = {
      url = "https://r4.wallpaperflare.com/wallpaper/30/586/460/artwork-fantasy-art-digital-art-forest-wallpaper-3cdadbae5dd4b0ca4dd008fd72d13bf3.jpg";
      sha256 = "sha256-vNBappcgqa8O2aj+Zz4aBrSsD97v0dDXQDeyC4o0gpc=";
    };
    windows-95 = {
      url = "https://w.wallhaven.cc/full/01/wallhaven-01e6xw.jpg";
      sha256 = "sha256-xgMi6fH3yMGk0txu0p5x01OY9qC4x597vEgSy/G9TBY=";
    };
    woodland = {
      url = "https://images.hdqwalls.com/wallpapers/beyond-the-railroad-crossing-5k-5b.jpg";
      sha256 = "sha256-lbmtPDD0+PP7UXy6MO0UdFtQIwsnvNUczolqTZW7k88=";
    };
    xcode-dusk = {
      url = "https://w.wallhaven.cc/full/yx/wallhaven-yxe85x.jpg";
      sha256 = "sha256-z/attvjcG1nReBjCVBY/JS2Eu2U44+Pd2OtIF1dPb1M=";
    };
  };
}
