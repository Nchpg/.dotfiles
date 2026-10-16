for profile in (string split " " $NIX_PROFILES)
    set -ga fish_function_path $profile/share/fish/vendor_functions.d
    set -ga fish_complete_path $profile/share/fish/vendor_completions.d
end

if set -q NIX_DEVSHELL_FISH_COMPLETIONS
    set -ga fish_complete_path $NIX_DEVSHELL_FISH_COMPLETIONS
end

export 0=fish
export SH=fish

function git_branch
    if not command git rev-parse --is-inside-work-tree >/dev/null 2>&1
        return
    end

    set branch (command git symbolic-ref --short HEAD 2>/dev/null)
    if test $status -eq 0
        echo (set_color red)" $branch"(set_color normal)
    else
        set commit (command git rev-parse --short HEAD 2>/dev/null)
        echo (set_color red)" $commit"(set_color normal)
    end
end

set -g SHELL_DEPTH $SHLVL
test "$TERM_PROGRAM" = vscode; and set SHELL_DEPTH (math $SHELL_DEPTH - 1)

if test "$SHELL_DEPTH" -le 1
    set -g __fish_first_prompt 1
else
    set -g __fish_first_prompt 0
end

# Décidé sur fish_prompt (une fois par prompt), pas dans la fonction (repaint).
function __fish_prompt_new_line --on-event fish_prompt
    if test "$__fish_first_prompt" = 1
        set -g __fish_prompt_new_line 0
        set -g __fish_first_prompt 0
    else
        set -g __fish_prompt_new_line 1
    end
end

set -g VIRTUAL_ENV_DISABLE_PROMPT 1

function fish_prompt
    set -l last_status $status

    test "$__fish_prompt_new_line" = 1; and echo ""
    set_color cyan
    echo -n (whoami)@(hostname -s)" "
    set_color blue
    echo -n (pwd | string replace -r "^$HOME" "~")
    set_color normal

    set venv_name ""

    if test -n "$VIRTUAL_ENV"
        set venv_base (dirname "$VIRTUAL_ENV")
        if test "$venv_base" = "/"
            set venv_name "($(basename "$VIRTUAL_ENV")) "
        else
            set venv_name "($(basename "$venv_base")/$(basename "$VIRTUAL_ENV")) "
        end
    else if test -n "$NIX_DEV_SHELL_PYTHON"
        set venv_name "($NIX_DEV_SHELL_PYTHON) "
    end

    for var in (set -n | grep '^NIX_DEV_SHELL_')
        if test "$var" = "NIX_DEV_SHELL_PYTHON"
            continue
        end

        set current $$var
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
    test "$SHELL_DEPTH" -gt 1; and echo -n $SHELL_DEPTH

    echo -n "❯ "
    set_color normal
end

set -g fish_greeting ""
set -g fish_term24bit 1

function clear
    set -g __fish_first_prompt 1
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
