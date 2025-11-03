#!/usr/bin/env bash

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [rebuild|toggle|lock|unlock|hide|show]"
    exit 1
fi

ACTION="$1"
PRIVATE_FILE="private.nix"
PRIVATE_FILE_BAK="private.bak.nix"


git_check_commit() {
    local file="$1" 

    local grep_pattern=$(echo "$file" | sed 's/\./\\./g')

    local modified_or_untracked=$(git status --short | grep "$grep_pattern" || true)

    if [ -n "$modified_or_untracked" ]; then
        echo "⚠️ Certains fichiers private.nix ont des modifications non commitées :"
        echo "$modified_or_untracked"
        echo
        echo "➡️ Fais un 'git commit' + 'git push' avant de continuer."
        exit 1
    fi
}

git_restore() { 
    local file="$1" 

    local grep_pattern=$(echo "$file" | sed 's/\./\\./g')

    git restore $(git ls-files | grep "$grep_pattern$")
}

git_ignore_change() {
    local pattern="$1" 

    local grep_pattern=$(echo "$pattern" | sed 's/\./\\./g')

    git update-index --assume-unchanged $(git ls-files | grep "$grep_pattern$")
}

git_unignore_change() {
    local pattern="$1" 

    local grep_pattern=$(echo "$pattern" | sed 's/\./\\./g')

    git update-index --no-assume-unchanged $(git ls-files | grep "$grep_pattern$")
}

move_file() {
    local src="$1"
    local dest="$2"
    find . -type f -name "$src" -execdir mv {} "$dest" \;
}

lock_file() {
    local file="$1"
    sudo find . -type f -name "$file" -exec chattr +i {} \;
}


unlock_file() {
    local file="$1"
    sudo find . -type f -name "$file" -exec chattr -i {} \;
}

get_real_private_file() {
    local exclude_file=".git/info/exclude"

    if [ -f "$exclude_file" ] && grep -qxF 'private.bak.nix' "$exclude_file"; then
        echo "$PRIVATE_FILE_BAK"
    else
        echo "$PRIVATE_FILE"
    fi
}

git_exclude_file() { 
    local file="$1" 
    local exclude_file=".git/info/exclude" 
    
    mkdir -p "$(dirname "$exclude_file")" 
    touch "$exclude_file" 
    
    grep -Fxq "$file" "$exclude_file" || echo "$file" >> "$exclude_file" 
}

git_unexclude_file() {
    local file="$1"
    local exclude_file=".git/info/exclude"

    [ -f "$exclude_file" ] || return

    sed -i "/^$(printf '%s\n' "$file" | sed 's/[^^]/[&]/g')$/d" "$exclude_file"

}

# Choisir la commande Git selon l'action
if [ "$ACTION" == "toggle" ] || [ "$ACTION" == "rebuild" ]; then
    if [ "$(get_real_private_file)" == "$PRIVATE_FILE_BAK" ]; then
        # check files that will be overwritten
        git_check_commit "$PRIVATE_FILE"

        # unlock files
        unlock_file "$PRIVATE_FILE_BAK"

        # move files
        move_file "$PRIVATE_FILE_BAK" "$PRIVATE_FILE"

        # manage tracked files
        git_ignore_change "$PRIVATE_FILE"
        git_unignore_change "$PRIVATE_FILE_BAK"

        # manage untracked files
        git_exclude_file "$PRIVATE_FILE"
        git_unexclude_file "$PRIVATE_FILE_BAK"

        # lock files
        lock_file "$PRIVATE_FILE"
    elif [ "$ACTION" != "rebuild" ]; then
        # unlock files
        unlock_file "$PRIVATE_FILE"

        # move files
        move_file "$PRIVATE_FILE" "$PRIVATE_FILE_BAK"

        # restore pushed files
        git_restore "$PRIVATE_FILE"

        # manage tracked files
        git_ignore_change "$PRIVATE_FILE_BAK"
        git_unignore_change "$PRIVATE_FILE"

        # manage untracked files
        git_unexclude_file "$PRIVATE_FILE"
        git_exclude_file "$PRIVATE_FILE_BAK"

        # lock files
        lock_file "$PRIVATE_FILE_BAK"
    fi
elif [ "$ACTION" == "lock" ]; then
    # lock files
    lock_file "$(get_real_private_file)"
elif [ "$ACTION" == "unlock" ]; then
    # unlock files
    unlock_file "$(get_real_private_file)"
elif [ "$ACTION" == "hide" ]; then
    git_ignore_change "$(get_real_private_file)"
    git_exclude_file "$(get_real_private_file)"
elif [ "$ACTION" == "show" ]; then
    git_unignore_change "$(get_real_private_file)"
    git_unexclude_file "$(get_real_private_file)"
else
    echo "Argument invalide : $ACTION. Utilisez 'git', 'toggle', 'lock', 'unlock', 'hide' or 'show'"
    exit 1
fi

echo "✅ switch effectué avec succès"