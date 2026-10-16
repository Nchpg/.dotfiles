# `status` n'a pas de hook git : via fish_postexec plutôt qu'une fonction `git`.
function __secrets_after_git_status --on-event fish_postexec
    command -q secrets; or return

    string match -qr '[|;&<>()$]' -- $argv[1]; and return
    set -l args (string split -n ' ' -- $argv[1] | string replace -r '^~(?=/|$)' -- $HOME | string trim -c '\'"')
    test "$args[1]" = git; or return
    set -e args[1]

    set -l dir .
    while set -q args[1]
        switch $args[1]
            case -C
                set dir $args[2]
                set -e args[1..2]
            case -c --git-dir --work-tree --namespace --config-env
                set -e args[1..2]
            case '-*'
                set -e args[1]
            case '*'
                break
        end
    end
    set -q args[1]; or return

    set -l sub $args[1]
    set -l seen
    while test "$sub" != status; and not contains -- $sub $seen
        set -a seen $sub
        set -l expansion (command git -C $dir config --get alias.$sub 2>/dev/null | string split -n ' ')
        set -q expansion[1]; or return
        set sub $expansion[1]
    end

    set -l top (command git -C $dir rev-parse --show-toplevel 2>/dev/null); or return
    set -q MY_FLAKE; or return
    test (path resolve $top) = (path resolve $MY_FLAKE); or return

    set -l out (secrets status)
    if set -q out[1]
        echo
        printf '%s\n' $out
    end
end
