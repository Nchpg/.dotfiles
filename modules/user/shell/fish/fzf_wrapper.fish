function searchf --description "Search files and their content using fzf"
    # Le token sert UNIQUEMENT à préremplir --query de fzf (cf. plus bas).
    # Surtout pas d'`eval` ici : $token est du texte non validé tapé ou collé
    # par l'utilisateur, et un chemin contenant $(...), ; ou des backticks
    # serait exécuté au simple appui sur le raccourci. Une expansion du ~
    # suffit à l'usage voulu.
    set -f token (commandline --current-token)
    set -f unescaped_exp_token (string replace -r '^~' -- $HOME $token)

    set results (
        bash -c "
            set -o pipefail
            fd -t f | while IFS= read -r line; do
                dirname=\"\$(dirname \"\$line\")\"
                basename=\"\$(basename \"\$line\")\"

                colored_path=\"\"
                if [ \"\$dirname\" = \".\" ]; then
                    colored_path=\"\$(echo -e \"\e[32m\$basename\e[0m\")\"
                else
                    colored_path=\"\$(echo -e \"\e[34m\$dirname/\e[90m\e[32m\$basename\e[0m\")\"
                fi

                # Utilisez echo -e pour gérer les séquences d'échappement ANSI si elles ne sont pas nettoyées.
                # Cependant, string replace est meilleur pour nettoyer.
                raw_file=\$(echo \"\$colored_path\" | sed -r 's/\x1B\[[0-9;]*m//g') # Nettoyage plus robuste des codes ANSI

                if [ -f \"\$raw_file\" ]; then
                    if file \"\$raw_file\" | grep \"text\" > /dev/null 2>&1; then
                        awk -v filename=\"\$colored_path\" \\
                            -v color_line_num=\"\033[95m\" \\
                            -v reset_color=\"\033[0m\" \\
                            '{print filename \":\" color_line_num NR reset_color \":\" \$0}' \"\$raw_file\" || break # Ajout de || break ici
                    fi
                fi
            done
        " | fzf --ansi \
                 --multi \
                 --layout=reverse \
                 --preview "header=\$(echo {} | cut -d: -f1-2); \
                            file=\$(echo \"\$header\" | cut -d: -f1); \
                            line=\$(echo \"\$header\" | cut -d: -f2); \
                            total=\$(wc -l < \"\$file\"); \
                            height=\$(( FZF_PREVIEW_LINES - 1 )); \
                            start=\$(( line - height / 2 )); \
                            max_start=\$(( total - height + 1 )); \
                            [ \$start -gt \$max_start ] && start=\$max_start; \
                            [ \$start -lt 1 ] && start=1; \
                            bat --wrap=never --style=numbers --color=always --highlight-line=\$line \"\$file\" | tail -n +\$start | head -n \"\$height\" " \
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
    set -g __fish_nb_prompt (math $__fish_nb_prompt - 1)
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

    function unbind_searchf --inherit-variable key_sequence
        bind --erase -- $key_sequence
        bind --erase --mode insert -- $key_sequence
    end
end


function man
      set MAN_ARGS $argv
      if test (count $argv) -eq 0;
          set selected_page (command man -k . | sort | fzf --ansi --multi --delimiter=" - " --border --prompt='Manual > ' --height=90% --reverse -e --preview="
           echo {1} \
           | sed 's/, /\n/g;' \
           | sed 's/\([^(]*\)(\([0-9A-Za-z ]\))/\2\t\1/g' \
           | xargs -n2 batman 2> /dev/null | bat --paging=never --language=man --style=plain --color=always
           ")
          if test -z "$selected_page"
            return
          end
          set -l selected_page_unaliased (echo "$selected_page" | string split -f 1 ',' | string trim)
          for line in (echo "$selected_page_unaliased" | string split '\n')
              if string match -r '^(.*?) *\(([0-9a-zA-Z ]+)\).*' "$line" > /dev/null
                  set -l matched_parts (string match -r '^(.*?) *\(([0-9a-zA-Z ]+)\).*' --groups "$line")

                  set -l page_name (echo "$matched_parts[1]" | string trim)
                  set -l section_name (echo "$matched_parts[2]" | string trim)
                  set -a MAN_ARGS "$section_name" "$page_name"
              end
          end
      end
      command man $MAN_ARGS 2> /dev/null | bat --paging=always --language=man --style=plain --color=always
  end

function man_wrapper
    man $argv
    set -g __fish_nb_prompt (math $__fish_nb_prompt - 1)
    commandline --function repaint
end
