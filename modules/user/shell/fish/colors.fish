# Depuis fish 4.x, le thème "default" livré en boîte met fish_color_command
# à --reset (couleur du terminal, pas de vert) si aucun thème n'a jamais été
# choisi explicitement sur la machine. Fixé ici pour que toutes les machines
# aient le même rendu, sans dépendre de fish_variables (état local non
# versionné).
#
# Deux registres, volontairement :
#   - noms ANSI (green, cyan…) : suivent la palette du terminal, donc le thème
#     stylix actif — et en SSH, celle du terminal client ;
#   - @stylix_baseXX@ : injectés au build par default.nix, pour les rôles que
#     les 16 couleurs ANSI ne portent pas (gris de commentaire, fond de
#     sélection). Ces slots étaient des hex Catppuccin arrivés là par un
#     `fish_config theme dump` sur gram : ils ne bougeaient plus avec le
#     thème, et restaient illisibles sur la variante claire.
set -g fish_color_autosuggestion @stylix_base03@
set -g fish_color_cancel -r
set -g fish_color_command green
set -g fish_color_comment @stylix_base03@
set -g fish_color_cwd green
set -g fish_color_cwd_root red
set -g fish_color_end brblack
set -g fish_color_error red
set -g fish_color_escape yellow
set -g fish_color_history_current --bold
set -g fish_color_host normal
set -g fish_color_host_remote yellow
set -g fish_color_match --background=brblue
set -g fish_color_normal normal
set -g fish_color_operator blue
set -g fish_color_param cyan
set -g fish_color_quote yellow
set -g fish_color_redirection cyan
set -g fish_color_search_match white --background=@stylix_base02@
set -g fish_color_selection white --bold --background=@stylix_base02@
set -g fish_color_status red
set -g fish_color_user brgreen
set -g fish_color_valid_path --underline
set -g fish_pager_color_completion normal
set -g fish_pager_color_description yellow --dim
set -g fish_pager_color_prefix white --bold
set -g fish_pager_color_progress brwhite --background=cyan
set -g fish_pager_color_selected_background -r
