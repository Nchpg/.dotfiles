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
    set -g __fish_nb_prompt 0
else
    set -g __fish_first_prompt 0
    set -g __fish_nb_prompt 10000000
end

set -g VIRTUAL_ENV_DISABLE_PROMPT 1

function fish_prompt
    set -l last_status $status

    if test "$__fish_first_prompt" = "0" && test "$__fish_nb_prompt" != "0"
        echo ""
    else
        set -g __fish_first_prompt 0
    end
    set -g __fish_nb_prompt (math $__fish_nb_prompt + 1)
    set_color cyan
    echo -n (whoami)@(hostname -s)" "
    set_color blue
    echo -n (pwd | string replace -r "^$HOME" "~")
    set_color normal

    set venv_name ""

    if test -n "$VIRTUAL_ENV"
        set venv_name "($(basename "$(dirname "$VIRTUAL_ENV")")/$(basename "$VIRTUAL_ENV")) "
    else if test -n "$NIX_DEV_SHELL_PYTHON"
        set venv_name "($NIX_DEV_SHELL_PYTHON) "
    end

    for var in (set -n | grep '^NIX_DEV_SHELL_')
        if test "$var" = "NIX_DEV_SHELL_PYTHON"
            continue
        end

        set current (eval echo \$$var)
        set venv_name "$venv_name($current) "
    end

    set_color yellow
    echo -n " $venv_name"
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

    set -l shlvl_display $SHLVL

    if test "$TERM_PROGRAM" = "vscode"
        set shlvl_display (math "$shlvl_display" - 1)
    end

    # si vide -> 0
    if test -z "$shlvl_display"
        set shlvl_display 0
    end

    if test "$shlvl_display" -gt 1
        echo -n "$shlvl_display"
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

function nix
  if test $argv[1] = "develop"
    if contains -- "--command" $argv
      command nix $argv
    else
      command nix develop $argv[2..-1] --command fish
    end
  else
    command nix $argv
  end
end


function fish_preexec --on-event fish_preexec
    set -g __fish_last_cmd $argv[1]
    echo $__fish_last_cmd >> ~/last_cmd.txt
end

function clear
    set -g __fish_first_prompt 1
    set -g __fish_nb_prompt 0
    command clear
end

function setdev
      echo "use flake \"\$MY_FLAKE#$argv[1]\"" > .envrc
      direnv allow
end

fzf_configure_bindings \
--directory=\e\cf \
--git_log=\e\cl \
--git_status=\e\cs \
--history=\cr \
--processes=\e\cp \
--variables=\e\cv

fzf_custom_bindings \e\cr 'searchf'
fzf_custom_bindings \em 'man_wrapper'