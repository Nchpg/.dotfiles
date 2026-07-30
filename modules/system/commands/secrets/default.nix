{ config, pkgs-stable, ... }:

# Accès aux secrets sops, des deux côtés de la frontière posée par
# modules/system/sops : les secrets SYSTÈME ne se déchiffrent qu'en root, les
# tiens avec ta clé age.
#
# Raison d'être, en deux temps.
#
# L'invocation correcte pour les secrets système est imprononçable : la bonne
# clé, et surtout des chemins ABSOLUS. `sops` et `nvim` ne sont installés que
# dans le profil home-manager de l'utilisateur, donc `sudo sops` échoue en
# « command not found » — root ne les a pas dans son PATH.
#
# Ces chemins sont figés AU BUILD, jamais résolus depuis ton environnement, et
# c'est une propriété de sécurité et non de commodité. Tout ce que cette
# commande passe à sudo s'exécute en root : un binaire choisi à l'exécution via
# $EDITOR ou via ton PATH rendait root à n'importe quel code tournant sous ton
# compte, qui n'avait qu'à attendre le prochain `secrets`. Ça annulait toute la
# frontière que modules/system/sops construit, et dont la raison d'être est
# précisément qu'un agent ou un prebuild npm ne lise pas system.yaml.
#
# `env` plutôt que `sudo VAR=... commande` : les deux marchent ici, les règles
# sudo de NixOS accordant SETENV par défaut, mais `env` reste lisible et ne
# dépend pas de ce réglage.
#
# Et depuis que les valeurs vivent dans un dépôt PRIVÉ à part (cf. l'entrée
# `secrets` de flake.nix), une modification demande DEUX commits : un ici pour
# la valeur, un là-bas pour bouger le lock. Oublier le second, c'est croire
# qu'on a fait tourner un secret alors que les machines déploient toujours
# l'ancien. Cette commande enchaîne les deux.
{
  environment.systemPackages = [
    (pkgs-stable.writeShellApplication {
      name = "secrets";
      runtimeInputs = [
        pkgs-stable.sops
        pkgs-stable.coreutils
        pkgs-stable.git
      ];
      text = ''
        flake="''${MY_FLAKE:-$HOME/.dotfiles}"
        store="''${MY_SECRETS:-$HOME/.secrets}"
        systemFile="$store/system.yaml"
        userFile="$store/secrets.yaml"
        sopsConfig="$store/.sops.yaml"
        keyFile=/var/lib/sops-nix/key.txt

        usage() {
          cat >&2 <<'USAGE'
        usage: secrets [commande]

          secrets                édite les secrets SYSTÈME, puis synchronise
          secrets user           édite TES secrets, puis synchronise
          secrets show <clé>     affiche une valeur système
                                 ex. secrets show wireguard/gram_preshared_key
          secrets list           liste les clés système, valeurs masquées
          secrets updatekeys     resynchronise les destinataires des deux
                                 fichiers après modification de .sops.yaml
          secrets sync           commit du dépôt privé et mise à jour du lock,
                                 sans passer par l'éditeur

        Les secrets vivent dans un dépôt PRIVÉ ($MY_SECRETS, ~/.secrets par
        défaut). Les secrets système ne sont déchiffrables que par root, et c'est
        voulu : du code lancé sous ton compte ne doit pas pouvoir les lire.
        USAGE
        }

        # `sops`, `git` et les coreutils viennent de `runtimeInputs`, que
        # writeShellApplication place EN TÊTE du PATH : `command -v` les résout
        # donc dans le store, hors d'atteinte d'un PATH trafiqué.
        sopsBin="$(command -v sops)"

        # `nix` n'y est pas, et le résoudre depuis ton PATH revenait à laisser
        # choisir le binaire que `sudo` allait exécuter dans sync(). Celui du
        # système, pas un autre : c'est lui qui écrit le lock.
        nixBin=${config.nix.package}/bin/nix

        # ÉDITEUR FIGÉ AU BUILD, jamais lu depuis $EDITOR. C'est sops, lancé par
        # sudo, qui l'exécute : le résoudre à l'exécution suffisait à obtenir
        # root en posant `EDITOR=/tmp/x` dans un fichier de démarrage du shell.
        #
        # `--clean` en plus du chemin du store, et ce n'est pas de la ceinture et
        # des bretelles : sans lui nvim lit $XDG_CONFIG_HOME/nvim/init.lua et
        # charge tout $XDG_DATA_HOME/nvim/site/pack/*/start. Ces chemins-là sont
        # des liens symboliques qui T'APPARTIENNENT — donc remplaçables par un
        # fichier ordinaire, donc exécutables en root. Le runtime de nvim reste
        # chargé, la coloration YAML avec.
        #
        # CE QU'ON PERD : le thème stylix et le LSP pendant l'édition d'un
        # secret. Un YAML de treize kilo-octets s'édite très bien sans. C'est le
        # prix de la frontière posée par modules/system/sops, qui ne vaut rien si
        # cette commande-ci la reperce.
        editorBin="${pkgs-stable.neovim}/bin/nvim --clean"

        # HOME et XDG posés EXPLICITEMENT sur root plutôt que repris de ton
        # environnement : on ne dépend donc pas de ce que sudo fait de HOME, et
        # l'éditeur ne peut charger aucun fichier venu de ton compte. Ça règle du
        # même coup ce que la version précédente rattrapait à la main — nvim
        # n'écrit plus son shada ni ses fichiers d'échange dans ton home en tant
        # que root.
        asRoot() {
          sudo env \
            SOPS_AGE_KEY_FILE="$keyFile" \
            EDITOR="$editorBin" \
            HOME=/root \
            XDG_CONFIG_HOME=/root/.config \
            XDG_DATA_HOME=/root/.local/share \
            XDG_STATE_HOME=/root/.local/state \
            XDG_CACHE_HOME=/root/.cache \
            "$sopsBin" "$@"
        }

        # sops réécrit le fichier sur place, donc l'inode et son propriétaire
        # survivent. Mais ça tient à un détail d'implémentation amont : si une
        # version future écrivait un fichier temporaire puis le renommait, le
        # fichier passerait à root et tes commandes git échoueraient dessus. On
        # vérifie plutôt que de le supposer.
        keepOwner() {
          local file="$1"
          shift
          local before after
          before="$(stat -c '%u:%g' "$file")"
          "$@"
          after="$(stat -c '%u:%g' "$file")"
          if [ "$before" != "$after" ]; then
            sudo chown "$before" "$file"
            echo "secrets : propriétaire de $file restauré ($before)" >&2
          fi
        }

        requireFile() {
          if [ ! -f "$1" ]; then
            echo "secrets : $1 introuvable — clone le dépôt privé ou définis MY_SECRETS." >&2
            exit 1
          fi
        }

        # AVANT toute édition. Le clone local peut être en retard si un secret a
        # été modifié depuis l'autre machine : on éditerait alors un état périmé,
        # et le commit qui suit ferait diverger les deux historiques. Au mieux le
        # push est refusé, au pire on résout un conflit à la main sur un fichier
        # chiffré, ce qui n'a aucun sens — les deux versions sont des blobs.
        #
        # `--ff-only` à dessein : s'il y a divergence, on s'arrête au lieu de
        # fabriquer une fusion. C'est une situation qui se règle en connaissance
        # de cause, pas au milieu d'une édition de secret.
        pullFirst() {
          git -C "$store" remote get-url origin > /dev/null 2>&1 || return 0

          if [ -n "$(git -C "$store" status --porcelain)" ]; then
            echo "secrets : modifications non commitées dans $store, mise à jour ignorée." >&2
            return 0
          fi

          if ! git -C "$store" pull --ff-only -q; then
            echo "secrets : impossible de mettre $store à jour (historiques divergents ?)." >&2
            echo "  Règle-le avant d'éditer : git -C $store status" >&2
            exit 1
          fi
        }

        # Notation sops : wireguard/gram_preshared_key -> ["wireguard"]["gram_preshared_key"]
        sopsPath() {
          local out="" part
          local IFS=/
          for part in $1; do
            out="''${out}[\"$part\"]"
          done
          printf '%s' "$out"
        }

        # LES DEUX MOITIÉS d'un changement de secret. Sans la seconde, le lock du
        # dépôt public continue de pointer sur l'ancienne révision et les
        # machines déploient l'ancienne valeur, sans un message.
        sync() {
          if [ -z "$(git -C "$store" status --porcelain)" ]; then
            echo "secrets : rien à synchroniser."
            return 0
          fi

          git -C "$store" add -A
          git -C "$store" commit -q -m "''${1:-chore: update secrets}"
          echo "secrets : commit dans $store"

          if git -C "$store" remote get-url origin >/dev/null 2>&1; then
            git -C "$store" push -q
            echo "secrets : poussé"
          else
            echo "secrets : aucun remote sur $store, pousse-le à la main." >&2
          fi

          if [ ! -f "$flake/flake.nix" ]; then
            echo "secrets : $flake/flake.nix introuvable, lock non mis à jour." >&2
            return 1
          fi

          # `--refresh` est INDISPENSABLE, et son absence produit la panne la
          # plus sournoise de tout ce montage. Nix considère une entrée
          # récupérée comme fraîche pendant une heure (`tarball-ttl`), donc deux
          # modifications de secrets dans la même heure et la seconde n'est
          # jamais résolue : le lock repart sur la révision précédente, le
          # rebuild déploie l'ancienne valeur, et RIEN ne le signale. Constaté
          # sur une rotation de clé de chiffrement Authelia, où la base et le
          # secret ont divergé sans un message.
          #
          # SOUS SUDO, et c'est la conséquence directe d'un jeton en 0600 root :
          # récupérer une entrée de flake se fait dans l'évaluateur, donc sous
          # l'utilisateur qui lance la commande. Sans sudo, cette ligne échoue en
          # 404 sur le dépôt privé.
          #
          # `safe.directory` posé au passage : git refuse d'opérer sur un dépôt
          # appartenant à quelqu'un d'autre, et ici root travaille sur un dépôt
          # qui t'appartient. Inutile si nix passe par libgit2 sans validation de
          # propriétaire, sans effet de bord s'il ne s'en sert pas.
          keepOwner "$flake/flake.lock" \
            sudo env \
              GIT_CONFIG_COUNT=1 \
              GIT_CONFIG_KEY_0=safe.directory \
              GIT_CONFIG_VALUE_0="$flake" \
              "$nixBin" flake update secrets --refresh --flake "$flake"
          # LE point de contrôle qui manquait. Entre ton édition et la machine il
          # y a quatre étages — le dépôt privé, sa remote, le lock, le rebuild —
          # et chacun peut avaler un changement sans un mot : un push qui
          # échoue, une résolution mise en cache, une mise à jour de lock
          # interrompue. Le symptôme est toujours le même, un rebuild qui
          # réussit en déployant l'ANCIENNE valeur.
          #
          # Trois pannes de ce type en une soirée, dont une base Authelia et un
          # tunnel WireGuard. On compare donc explicitement ce que le lock
          # déploie et ce que le dépôt contient.
          local locked head
          locked="$(grep -A 12 '"secrets": {' "$flake/flake.lock" | grep -m1 '"rev"' | cut -d'"' -f4)"
          head="$(git -C "$store" rev-parse HEAD)"
          if [ "$locked" != "$head" ]; then
            echo >&2
            echo "secrets : ATTENTION, le lock ne pointe PAS sur ton dernier commit." >&2
            echo "  dépôt : $head" >&2
            echo "  lock  : $locked" >&2
            echo "  Un rebuild déploierait l'ancienne valeur. Relance :" >&2
            echo "    sudo nix flake update secrets --refresh --flake $flake" >&2
            return 1
          fi

          echo
          echo "── lock à jour sur $head ──"
          git -C "$flake" --no-pager diff --stat flake.lock
          echo "   git -C $flake commit -am 'chore: bump secrets' && git -C $flake push"
        }

        case "''${1:-edit}" in
          edit)
            pullFirst
            requireFile "$systemFile"
            keepOwner "$systemFile" asRoot "$systemFile"
            sync "chore: update system secrets"
            ;;

          user)
            pullFirst
            requireFile "$userFile"
            "$sopsBin" "$userFile"
            sync "chore: update user secrets"
            ;;

          show)
            if [ $# -lt 2 ]; then usage; exit 2; fi
            requireFile "$systemFile"
            asRoot --decrypt --extract "$(sopsPath "$2")" "$systemFile"
            ;;

          list)
            requireFile "$systemFile"
            # Valeurs remplacées à la volée : la liste sert à retrouver un nom
            # de clé, pas à en révéler le contenu dans un terminal partagé ou
            # dans l'historique d'un multiplexeur.
            asRoot --decrypt "$systemFile" \
              | sed -E 's/^([[:space:]]*[A-Za-z0-9_/.-]+):[[:space:]]*.+$/\1: <valeur>/'
            ;;

          updatekeys)
            pullFirst
            requireFile "$systemFile"
            requireFile "$userFile"
            # `--config` explicite : sops cherche .sops.yaml à partir du
            # RÉPERTOIRE COURANT, pas de celui du fichier qu'on lui donne. Sans
            # ça, la commande échoue sur « config file not found » dès qu'on la
            # lance d'ailleurs que du dépôt de secrets — c'est-à-dire presque
            # toujours.
            keepOwner "$systemFile" asRoot --config "$sopsConfig" updatekeys "$systemFile"
            "$sopsBin" --config "$sopsConfig" updatekeys "$userFile"
            sync "chore: update sops recipients"
            ;;

          sync)
            sync "''${2:-chore: update secrets}"
            ;;

          -h | --help | help)
            usage
            ;;

          *)
            echo "secrets : commande inconnue « $1 »" >&2
            usage
            exit 1
            ;;
        esac
      '';
    })
  ];
}
