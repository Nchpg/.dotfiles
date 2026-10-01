{
  config,
  lib,
  myLib,
  ...
}:

# `kat` : un `cat` qui choisit l'affichage selon le TYPE du fichier (mime,
# extension en appoint). Texte et code -> bat, markdown -> glow, image ->
# chafa (protocole graphique kitty, à travers tmux grâce à son
# allow-passthrough), PDF et documents -> texte, vidéo et audio -> lus par
# mpv, mermaid (fichier ou bloc dans du markdown) -> diagramme rendu,
# archive -> contenu, base SQLite -> schéma, dossier -> arbre.
let
  cfg = config.userSettings.cli.kat;

  mermaidTheme = if config.stylix.polarity == "light" then "default" else "dark";

  kat = cfg.pkgs.writeShellApplication {
    name = "kat";
    runtimeInputs = with cfg.pkgs; [
      file
      coreutils
      config.programs.bat.package
      glow
      jq
      chafa
      poppler-utils # pdftotext, pdfinfo
      libarchive # bsdtar : zip, tar.*, 7z, rar, iso…
      pandoc
      sqlite
      eza
      hexyl
      mpv
      mermaid-cli # mmdc (rendu via un Chromium headless, ~3 s)
    ];
    text = ''
      usage() {
        echo "usage: kat FICHIER... (sans argument : lit l'entrée standard)" >&2
      }

      # Images : protocole kitty si le terminal le parle, passthrough si on
      # est dans tmux. chafa retombe sur des blocs Unicode ailleurs.
      # $2 (optionnel) = taille en cases « COLxLIG », ou « native » : pixel
      # pour pixel, chafa mesurant lui-même les cases (hors tmux).
      show_image() {
        local args=()
        if [ -n "''${KITTY_WINDOW_ID:-}" ]; then
          args+=(--format kitty)
          [ -n "''${TMUX:-}" ] && args+=(--passthrough tmux)
        fi
        if [ "''${2:-}" = native ]; then
          :
        elif [ -n "''${2:-}" ]; then
          args+=(--size "$2" --scale max)
        else
          args+=(--size "''${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}x30")
        fi
        chafa "''${args[@]}" "$1"
      }

      # Taille en cases d'une image affichée pixel pour pixel, bornée à la
      # largeur du terminal. Hors tmux, chafa s'en charge (« native »). Dans
      # tmux, il interroge le terminal pour la taille des cases, tmux ne
      # transmet pas la question, et l'image finit étirée à toute la
      # largeur : on calcule donc ici, tmux >= 3.4 donnant cette taille.
      native_size() {
        local w h cw ch cols rows max=''${COLUMNS:-80}
        if [ -z "''${TMUX:-}" ]; then
          echo native
          return
        fi
        read -r cw ch < <(tmux display -p '#{client_cell_width} #{client_cell_height}' 2>/dev/null) || return 0
        [ "''${cw:-0}" -gt 0 ] && [ "''${ch:-0}" -gt 0 ] || return 0
        read -r w h < <(file -b "$1" | sed -E 's/.*, ([0-9]+) x ([0-9]+),.*/\1 \2/')
        cols=$(((w + cw - 1) / cw))
        rows=$(((h + ch - 1) / ch))
        if [ "$cols" -gt "$max" ]; then
          rows=$((rows * max / cols + 1))
          cols=$max
        fi
        echo "''${cols}x$rows"
      }

      # Diagramme rendu en PNG puis affiché comme une image. Thème calé sur
      # la polarité stylix, fond transparent pour se fondre dans le terminal.
      # Source affichée telle quelle si le rendu échoue (syntaxe invalide).
      show_mermaid() {
        local png
        png=$(mktemp --suffix .png)
        if mmdc -q -i "$1" -o "$png" -t ${mermaidTheme} -b transparent -s 2 >/dev/null 2>&1; then
          # Rendu x2 affiché pixel pour pixel : le texte du diagramme a alors
          # à peu près la taille de celui du terminal.
          show_image "$png" "$(native_size "$png")"
        else
          echo "kat: rendu mermaid impossible, source affichée" >&2
          bat "$1"
        fi
        rm -f "$png"
      }

      # Markdown : glow ne sait pas dessiner les blocs ```mermaid. Le fichier
      # est découpé en morceaux (texte / diagramme) rendus dans l'ordre, le
      # texte par glow, chaque diagramme par show_mermaid (~3 s chacun).
      show_markdown() {
        local f=$1 dir n=0 inblock=0 cur line seg width=''${COLUMNS:-100}
        if ! grep -q '^```[[:space:]]*mermaid' "$f"; then
          glow -w "$width" "$f"
          return
        fi
        dir=$(mktemp -d)
        cur=$dir/000.md
        : >"$cur"
        while IFS= read -r line || [ -n "$line" ]; do
          if [ "$inblock" = 0 ] && [[ $line =~ ^\`\`\`[[:space:]]*mermaid ]]; then
            n=$((n + 1)); inblock=1
            cur=$dir/$(printf %03d "$n").mmd
            : >"$cur"
          elif [ "$inblock" = 1 ] && [[ $line =~ ^\`\`\`[[:space:]]*$ ]]; then
            n=$((n + 1)); inblock=0
            cur=$dir/$(printf %03d "$n").md
            : >"$cur"
          else
            printf '%s\n' "$line" >>"$cur"
          fi
        done <"$f"
        for seg in "$dir"/*; do
          case "$seg" in
            *.mmd) show_mermaid "$seg" ;;
            # Morceau vide ou blanc (entre deux diagrammes) : rien à afficher.
            *)
              if grep -q '[^[:space:]]' "$seg"; then
                glow -w "$width" "$seg"
              fi
              ;;
          esac
        done
        rm -rf "$dir"
      }

      show() {
        local f=$1 mime ext
        if [ -d "$f" ]; then
          eza --tree --level 2 --icons --group-directories-first "$f"
          return
        fi
        if [ ! -e "$f" ]; then
          echo "kat: $f : fichier introuvable" >&2
          return 1
        fi

        mime=$(file --mime-type -b -L "$f")
        ext=''${f##*.}
        ext=''${ext,,}

        # Extension d'abord pour les cas où le mime est trop vague
        # (text/plain pour du markdown, du json…).
        case "$ext" in
          md | markdown) show_markdown "$f"; return ;;
          json) jq -C . "$f" 2>/dev/null || bat "$f"; return ;;
          mmd | mermaid) show_mermaid "$f"; return ;;
        esac

        case "$mime" in
          inode/x-empty) echo "(fichier vide)" ;;
          image/svg+xml) bat "$f" ;;
          image/*) show_image "$f" ;;
          application/pdf)
            pdfinfo "$f" | sed -nE \
              -e 's/^Title: +/Titre      /p' -e 's/^Author: +/Auteur     /p' \
              -e 's/^Pages: +/Pages      /p' -e 's/^Page size: +/Format     /p'
            echo
            pdftotext -layout "$f" - | bat --file-name "$f" -l txt
            ;;
          # Vidéo dans le terminal seulement si c'est en pleine qualité :
          # protocole graphique kitty, hors tmux (mpv ne sait pas le faire
          # passer à travers tmux : écran noir). Sinon fenêtre mpv, jamais de
          # rendu en blocs pixelisés.
          video/*)
            if [ -n "''${KITTY_WINDOW_ID:-}" ] && [ -z "''${TMUX:-}" ]; then
              mpv --really-quiet --vo=kitty --vo-kitty-use-shm=yes "$f"
            elif [ -n "''${WAYLAND_DISPLAY:-}" ]; then
              mpv "$f"
            else
              echo "kat: pas de session graphique pour lire la vidéo" >&2
              file -b "$f"
            fi
            ;;
          # --audio-display=no : sinon une pochette intégrée ouvre une fenêtre.
          audio/*) mpv --no-video --audio-display=no "$f" ;;
          application/zip | application/x-tar | application/gzip | application/x-gzip \
          | application/x-bzip2 | application/x-xz | application/zstd | application/x-7z-compressed \
          | application/vnd.rar | application/x-rar | application/x-iso9660-image \
          | application/java-archive)
            bsdtar -tvf "$f" 2>/dev/null || file -b "$f"
            ;;
          application/vnd.openxmlformats-officedocument.wordprocessingml.document \
          | application/vnd.oasis.opendocument.text | application/epub+zip \
          | application/rtf | text/rtf | text/html)
            pandoc -t gfm "$f" 2>/dev/null | glow -w "''${COLUMNS:-100}" -
            ;;
          application/vnd.sqlite3 | application/x-sqlite3)
            sqlite3 -readonly "$f" .tables
            echo
            sqlite3 -readonly "$f" .schema | bat -l sql
            ;;
          application/json) jq -C . "$f" 2>/dev/null || bat "$f" ;;
          text/* | application/javascript | application/xml | application/x-shellscript \
          | application/toml | application/x-yaml)
            bat "$f"
            ;;
          *)
            # Binaire inconnu : ce que `file` en dit + le début en hexa.
            file -b "$f"
            hexyl --length 256 "$f"
            ;;
        esac
      }

      case "''${1:-}" in
        -h | --help) usage; exit 0 ;;
      esac

      if [ $# -eq 0 ]; then
        exec bat
      fi

      status=0
      for f in "$@"; do
        # En-tête entre les fichiers quand il y en a plusieurs.
        if [ $# -gt 1 ]; then
          printf '\n\033[1m── %s ──\033[0m\n' "$f"
        fi
        show "$f" || status=1
      done
      exit "$status"
    '';
  };
in
{
  options = {
    userSettings.cli.kat = {
      enable = lib.mkEnableOption "kat (cat qui affiche selon le type : image, pdf, vidéo, archive…)";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.userSettings.cli.bat.enable;
        message = "userSettings.cli.kat s'appuie sur programs.bat (userSettings.cli.bat).";
      }
    ];
    home.packages = [ kat ];
  };
}
