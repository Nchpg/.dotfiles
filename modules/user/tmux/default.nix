{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tmux;
  shell = config.userSettings.shell.default;
in
{
  options = {
    userSettings.tmux = {
      enable = lib.mkEnableOption "Enable tmux";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = lib.mkIf cfg.enable {
    stylix.targets.tmux.enable = true;

    # TMUX_TMPDIR aligné sur home-manager ($XDG_RUNTIME_DIR), sinon sessions invisibles entre elles.
    home.file.".config/sway/conf.d/tmux.conf" = lib.mkIf config.userSettings.windowManager.sway.enable {
      text = ''
        bindsym Control+Return exec ${
          myLib.desktop.mkTerminalCmd {
            inherit config;
            exec = "env TMUX_TMPDIR=$XDG_RUNTIME_DIR tmux new-session -A -s main";
          }
        }
      '';
    };

    programs.tmux = {
      enable = true;
      shell = myLib.desktop.mkTerminalShellBin {
        inherit (config.userSettings.shell.${shell}) pkgs;
        inherit shell;
      };
      terminal = "tmux-256color";
      historyLimit = 100000;
      escapeTime = 10;
      baseIndex = 1;
      keyMode = "vi";
      mouse = true;

      plugins = with cfg.pkgs.tmuxPlugins; [
        sensible
        yank
        {
          plugin = resurrect;
          extraConfig = "set -g @resurrect-strategy-nvim 'session'";
        }
        {
          plugin = continuum;
          extraConfig = ''
            set -g @continuum-restore 'on'
            set -g @continuum-save-interval '10'
          '';
        }
      ];

      extraConfig = ''
        unbind C-b
        set -g prefix C-a
        bind C-a send-prefix

        bind r source-file ~/.config/tmux/tmux.conf \; display "Config rechargée !"

        bind | split-window -h -c "#{pane_current_path}"
        bind - split-window -v -c "#{pane_current_path}"
        unbind '"'
        unbind %

        bind -n M-h select-pane -L
        bind -n M-l select-pane -R
        bind -n M-k select-pane -U
        bind -n M-j select-pane -D

        bind -r H resize-pane -L 5
        bind -r J resize-pane -D 5
        bind -r K resize-pane -U 5
        bind -r L resize-pane -R 5

        bind -n M-Left previous-window
        bind -n M-Right next-window

        bind -T copy-mode-vi v send-keys -X begin-selection
        bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel

        set -ga terminal-overrides ",*256col*:Tc"

        # image.nvim (Kitty graphics protocol)
        set -gq allow-passthrough on

        set -g renumber-windows on

        set -g monitor-activity on
        set -g visual-activity off
      '';
    };
  };
}
