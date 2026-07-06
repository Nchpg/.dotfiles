{ config, lib, ... }:

let
  cfg = config.userSettings.tmux;
in {
  options = {
    userSettings.tmux = {
      enable = lib.mkEnableOption "Enable tmux";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # NB : home-manager (programs.tmux) fixe déjà
    #   TMUX_TMPDIR = $XDG_RUNTIME_DIR
    # pour les shells. Le binding sway (Ctrl+Return) s'aligne sur cette même
    # valeur pour viser le même serveur tmux — sinon sway utiliserait /tmp et
    # les sessions seraient invisibles entre elles.

    # Stylix colore tmux avec la même palette base16 que le reste du système.
    stylix.targets.tmux.enable = true;

    programs.tmux = {
      enable = true;
      shell = "${cfg.pkgs.${config.userSettings.shell.default}}/bin/${config.userSettings.shell.default}";
      terminal = "tmux-256color";
      historyLimit = 100000;
      escapeTime = 10;          # latence Esc minimale (utile pour vim/neovim)
      baseIndex = 1;            # fenêtres/panes numérotés à partir de 1
      keyMode = "vi";
      mouse = true;

      plugins = with cfg.pkgs.tmuxPlugins; [
        sensible
        yank             # copie vers le presse-papier système
        {
          plugin = resurrect;   # sauvegarde/restaure les sessions
          extraConfig = "set -g @resurrect-strategy-nvim 'session'";
        }
        {
          plugin = continuum;   # sauvegarde automatique périodique
          extraConfig = ''
            set -g @continuum-restore 'on'
            set -g @continuum-save-interval '10'
          '';
        }
      ];

      extraConfig = ''
        # Préfixe : Ctrl-a (plus accessible que Ctrl-b)
        unbind C-b
        set -g prefix C-a
        bind C-a send-prefix

        # Recharger la config
        bind r source-file ~/.config/tmux/tmux.conf \; display "Config rechargée !"

        # Splits avec | et - (et garde le répertoire courant)
        bind | split-window -h -c "#{pane_current_path}"
        bind - split-window -v -c "#{pane_current_path}"
        unbind '"'
        unbind %

        # Navigation entre panes à la vim (sans préfixe)
        bind -n M-h select-pane -L
        bind -n M-l select-pane -R
        bind -n M-k select-pane -U
        bind -n M-j select-pane -D

        # Redimensionnement des panes
        bind -r H resize-pane -L 5
        bind -r J resize-pane -D 5
        bind -r K resize-pane -U 5
        bind -r L resize-pane -R 5

        # Navigation entre fenêtres (sans préfixe)
        bind -n M-Left previous-window
        bind -n M-Right next-window

        # Sélection façon vim en mode copie
        bind -T copy-mode-vi v send-keys -X begin-selection
        bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel

        # Couleurs true color
        set -ga terminal-overrides ",*256col*:Tc"

        # Laisse passer les séquences graphiques (Kitty graphics protocol) à
        # travers tmux : requis par image.nvim pour afficher les images.
        set -gq allow-passthrough on

        # Renumérote les fenêtres quand on en ferme une
        set -g renumber-windows on

        # Notifications d'activité
        set -g monitor-activity on
        set -g visual-activity off
      '';
    };
  };
}
