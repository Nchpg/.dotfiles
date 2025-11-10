{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.shell.fish;
in {
  options = {
    userSettings.shell.fish = {
      enable = lib.mkEnableOption "Enable  fish";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.fish = {
        enable = true;

        shellInit = ''
          fish_add_path ${cfg.pkgs.fishPlugins.fzf-fish}/bin
        '';

        interactiveShellInit = ''
        for profile in (string split " " $NIX_PROFILES)
            set -a fish_function_path $profile/share/fish/vendor_functions.d
            set -a fish_complete_path $profile/share/fish/vendor_completions.d
        end

        set -a fish_function_path ${cfg.pkgs.fishPlugins.fzf-fish}/functions
        set -a fish_complete_path ${cfg.pkgs.fishPlugins.fzf-fish}/completions

        set -Ux fish_history_file "$HOME/.local/share/fish/fish_history"
        set -Ux fish_history_max 10000

        if test -n "$KITTY_INSTALLATION_DIR"
            set -x KITTY_SHELL_INTEGRATION no-rc
            if test -f "$KITTY_INSTALLATION_DIR/shell-integration/fish/kitty.fish"
                source "$KITTY_INSTALLATION_DIR/shell-integration/fish/kitty.fish"
            end
        end

        set -x LS_COLORS "di=0;34:ln=0;36:ex=0;32:*.tar=0;31:*.zip=0;31"

        alias ls='eza --icons=auto'
        alias grep='grep --color=auto'
        alias fgrep='fgrep --color=auto'
        alias egrep='egrep --color=auto'
        alias la='ls -A --color=auto'
        alias l='ls -CF --color=auto'
        alias ll='eza -lha --icons=auto --sort=name --group-directories-first'
        alias su='sudo su -s (which fish)'
        alias cls='set -g __fish_prompt_shown_before 0 && clear'

        export EDITOR=vim
        export VISUAL=vim

        function git_branch
            # Vérifie si on est dans un dépôt Git
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

       

        function fish_prompt
            if test "$__fish_prompt_shown_before" = "1"
              echo ""
            else
              set -g __fish_prompt_shown_before 1
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

            if test $status -ne 0
                set_color red
                echo -n "✘"(echo $status)" "
                set_color normal
            end
            set_color green
            echo -n "❯ "
            set_color normal
        end

        function fish_right_prompt
            set_color yellow
            date "+%H:%M:%S "
            set_color normal
        end

        set -g fish_greeting ""
        set -g fish_term24bit 1

        fzf_configure_bindings \
        --directory=\e\cf \
        --git_log=\e\cl \
        --git_status=\e\cs \
        --history=\cr \
        --processes=\e\cp \
        --variables=\e\cv
        '';
    };

    home.packages = with cfg.pkgs; [
      fishPlugins.fzf-fish
      ripgrep
      fzf
    ];
  };
}
