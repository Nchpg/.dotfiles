# Après un `git status` dans le dépôt de config, l'état du dépôt de secrets
# (`secrets status`, muet si les deux sont en phase). Pull et push n'ont pas
# besoin de ça : les hooks de .githooks s'en chargent, quel que soit l'alias ou
# le client. `status` n'a pas de hook git, d'où ce relais.
#
# Par l'événement fish_postexec et PAS par une fonction `git` : git reste le
# vrai binaire, ses complétions et ses alias intacts, et rien ne change pour les
# scripts. Les alias sont résolus par git lui-même, donc `git st` (ou tout alias
# vers status, en chaîne) compte comme `git status`.
function __secrets_after_git_status --on-event fish_postexec
    command -q secrets; or return

    # Une commande simple seulement : un status dans un tube, redirigé ou
    # enchaîné n'est pas lu par un humain à cet endroit.
    string match -qr '[|;&<>()$]' -- $argv[1]; and return
    # `~` développé et guillemets retirés : la ligne est du texte brut, et
    # `git -C ~/.dotfiles status` ne serait sinon jamais reconnu. Un chemin
    # contenant une espace reste hors de portée (découpage sur l'espace).
    set -l args (string split -n ' ' -- $argv[1] | string replace -r '^~(?=/|$)' -- $HOME | string trim -c '\'"')
    test "$args[1]" = git; or return
    set -e args[1]

    # Options globales avant la sous-commande ; -C change le dépôt visé.
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

    # Arrêt sur un alias shell (`!…`, jamais égal à status) ou une boucle.
    set -l sub $args[1]
    set -l seen
    while test "$sub" != status; and not contains -- $sub $seen
        set -a seen $sub
        set -l expansion (command git -C $dir config --get alias.$sub 2>/dev/null | string split -n ' ')
        set -q expansion[1]; or return
        set sub $expansion[1]
    end

    set -l top (command git -C $dir rev-parse --show-toplevel 2>/dev/null); or return
    set -l flake $HOME/.dotfiles
    set -q MY_FLAKE; and set flake $MY_FLAKE
    test (path resolve $top) = (path resolve $flake); or return

    set -l out (secrets status)
    if set -q out[1]
        echo
        printf '%s\n' $out
    end
end
