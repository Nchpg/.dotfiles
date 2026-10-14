function searchf --description "Search files and their content using fzf"
    # Le token sert UNIQUEMENT à préremplir --query de fzf (cf. plus bas).
    # Surtout pas d'`eval` ici : $token est du texte non validé tapé ou collé
    # par l'utilisateur, et un chemin contenant $(...), ; ou des backticks
    # serait exécuté au simple appui sur le raccourci. Une expansion du ~
    # suffit à l'usage voulu.
    set -f token (commandline --current-token)
    set -f unescaped_exp_token (string replace -r '^~' -- $HOME $token)

    # Toutes les lignes de tous les fichiers texte sous le dossier courant,
    # « fichier:ligne:contenu » ; fzf ne cherche que dans le contenu (--nth 3..).
    # rg saute d'office les binaires, les fichiers cachés et ceux ignorés par
    # git, comme le faisait le couple fd + `file` d'avant.
    set results (
        rg --line-number --no-heading --with-filename --color=always \
            --colors path:fg:green --colors line:fg:magenta --colors line:style:intense \
            '' | fzf --ansi \
                 --multi \
                 --layout=reverse \
                 --preview "bash -c 'header=\$(echo \"\$1\" | cut -d: -f1-2); \
                            file=\$(echo \"\$header\" | cut -d: -f1); \
                            line=\$(echo \"\$header\" | cut -d: -f2); \
                            total=\$(wc -l < \"\$file\"); \
                            height=\$(( FZF_PREVIEW_LINES - 1 )); \
                            start=\$(( line - height / 2 )); \
                            max_start=\$(( total - height + 1 )); \
                            [ \$start -gt \$max_start ] && start=\$max_start; \
                            [ \$start -lt 1 ] && start=1; \
                            BAT_THEME=$__bat_preview_theme bat --wrap=never --style=numbers --color=always --highlight-line=\$line \"\$file\" | tail -n +\$start | head -n \"\$height\"' _ {}" \
                 --preview-window=right:60%:nowrap \
                 --nth 3.. \
                 --delimiter=: \
                 --height=90% \
                 --border \
                 --prompt='Recherche > ' \
                 --query "$unescaped_exp_token" \
                 --exact \
                 --no-sort \
                 --no-hscroll
    )

    if test -n "$results"
        for line in $results
            # Nettoyer les codes ANSI du nom de fichier pour vim
            set file_with_color (echo $line | cut -d: -f1)
            set file (string replace -ra '\e\[[0-9;]*m' '' "$file_with_color")
            set lineno (echo $line | cut -d: -f2)
            vim +$lineno "$file"
        end
    end
    commandline --function repaint
end

function fzf_custom_bindings --description "Bind keys to searchf"
    status is-interactive; or return

    set key_sequence $argv[1]
    set function $argv[2]

    bind --erase -- $key_sequence
    bind --erase --mode insert -- $key_sequence

    for mode in default insert
        bind --mode $mode $key_sequence $function
    end
end


function man
      # BAT_THEME=$__bat_preview_theme dans la preview (posé par
      # shell/fish/default.nix) : sans tty, bat ne peut pas détecter la
      # polarité du terminal et retomberait sur Monokai au lieu de gruvbox.
      set MAN_ARGS $argv
      if test (count $argv) -eq 0;
          set selected_page (command man -k . | sort | fzf --ansi --multi --delimiter=" - " --border --prompt='Manual > ' --height=90% --reverse -e --preview="bash -c '
           echo \"\$1\" \
           | sed \"s/, /\n/g;\" \
           | sed \"s/\([^(]*\)(\([0-9A-Za-z ]\))/\2\t\1/g\" \
           | xargs -n2 batman 2>/dev/null | env BAT_THEME=$__bat_preview_theme bat --paging=never --language=man --style=plain --color=always
           ' _ {1}")
          if test -z "$selected_page"
            return
          end
          # Une ligne par page choisie (--multi), « nom[, alias…] (section) - … » :
          # on garde le premier nom et sa section, passés sous la forme
          # `nom(section)` (`man 1 ls 3 printf` ne lirait que la première).
          for line in $selected_page
              set -l parts (string match -r --groups-only '^(.*?) *\(([0-9a-zA-Z ]+)\)' -- $line)
              or continue
              set -l name (string split -f 1 ',' -- $parts[1] | string trim)
              set -a MAN_ARGS "$name("(string trim -- $parts[2])")"
          end
      end
      command man $MAN_ARGS 2> /dev/null | bat --paging=always --language=man --style=plain --color=always
  end

function man_wrapper
    man $argv
    commandline --function repaint
end
