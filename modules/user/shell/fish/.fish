for profile in (string split " " $NIX_PROFILES)
    set -a fish_function_path $profile/share/fish/vendor_functions.d
    set -a fish_complete_path $profile/share/fish/vendor_completions.d
end


set -Ux fish_history_file "$HOME/.local/share/fish/fish_history"
set -Ux fish_history_max 10000

if test -n "$KITTY_INSTALLATION_DIR"
    set -x KITTY_SHELL_INTEGRATION no-rc
    if test -f "$KITTY_INSTALLATION_DIR/shell-integration/fish/kitty.fish"
        source "$KITTY_INSTALLATION_DIR/shell-integration/fish/kitty.fish"
    end
end

export 0=fish

function git_branch
    if not command git rev-parse --is-inside-work-tree >/dev/null 2>&1
        return
    end

    # Récupère la branche ou le commit HEAD
    set branch (command git symbolic-ref --short HEAD 2>/dev/null)
    if test $status -eq 0
        echo (set_color red)" $branch"(set_color normal)
    else
        set commit (command git rev-parse --short HEAD 2>/dev/null)
        echo (set_color red)" $commit"(set_color normal)
    end
end

    
if test "$SHLVL" -eq 1
    set -g __fish_first_prompt 1
else
    set -g __fish_first_prompt 0
end

function fish_prompt
    set -l last_status $status

    if test "$__fish_first_prompt" = "0"
        echo ""
    else
        set -g __fish_first_prompt 0
    end
    set_color cyan
    echo -n (whoami)@(hostname -s)" "
    set_color blue
    echo -n (pwd | string replace -r "^$HOME" "~")
    set_color normal

    set gitb (git_branch)
    if test -n "$gitb"
    echo -n " "$gitb" "
    end
    echo ""

    if test $last_status -ne 0
        set_color red
        echo -n "✘$last_status "
        set_color normal
    end

    set_color green

    if test "$SHLVL" -gt 1
        echo -n "$SHLVL"
    end
    echo -n "❯ "
    set_color normal
end

set -g fish_greeting ""
set -g fish_term24bit 1

function nix-shell
    set has_run 0
    for arg in $argv
        if test "$arg" = "--run"
            set has_run 1
            break
        end
    end

    if test $has_run -eq 1
        command nix-shell $argv
    else
        command nix-shell $argv --run "exec fish"
    end
end

function clear
    set -g __fish_first_prompt 1
    command clear
end

function searchf
      set -l pattern $argv

      # Recherche avec ripgrep et affichage via fzf (input en haut)
      set results (rg --column --line-number --no-heading --color=always "$pattern" . | fzf --ansi \
                                  --multi \
                                  --layout=reverse \
                                  --preview "file=\$(echo {} | cut -d: -f1); line=\$(echo {} | cut -d: -f2); bat --style=numbers --color=always --highlight-line=\$line \$file" \
                                  --preview-window=right:60% \
                                  --nth 4.. \
                                  --height=90% \
                                  --border \
                                  --prompt='Recherche > '\
                                  --exact)

      if test -n "$results"
          for line in $results
              # Récupère le fichier et le numéro de ligne
              set file (echo $line | cut -d: -f1)
              set lineno (echo $line | cut -d: -f2)
              # Ouvre vim à la ligne correspondante
              vim +$lineno $file
          end
      end
  end

bind \e\cc searchf



fzf_configure_bindings \
--directory=\e\cf \
--git_log=\e\cl \
--git_status=\e\cs \
--history=\cr \
--processes=\e\cp \
--variables=\e\cv