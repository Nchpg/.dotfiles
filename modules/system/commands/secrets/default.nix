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
# précisément qu'un agent ou un prebuild npm ne lise pas les secrets des
# services.
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
        # `find` et `sed`, que `list` et `updatekeys` emploient pour parcourir
        # l'arborescence des secrets. Déclarés, et pas laissés au PATH ambiant :
        # c'est toute la raison d'être de ce bloc, et un `find` pris ailleurs
        # serait un binaire choisi à l'exécution dans une commande dont une
        # partie s'exécute sous sudo.
        pkgs-stable.findutils
        pkgs-stable.gnused
        # Pour relever TA clé publique et savoir, fichier par fichier, si tu en
        # es destinataire — donc s'il faut passer par root ou non.
        pkgs-stable.age
      ];
      text = ''
        flake="''${MY_FLAKE:-$HOME/.dotfiles}"
        store="''${MY_SECRETS:-$HOME/.secrets}"
        sopsConfig="$store/.sops.yaml"
        keyFile=/var/lib/sops-nix/key.txt

        # UN SECRET = UN FICHIER : `wireguard/gram_preshared_key` vit dans
        # $store/wireguard/gram_preshared_key.yaml, scellé pour les seules
        # machines qui en ont besoin (cf. `nix run .#sops-policy`).
        secretPath() { printf '%s/%s.yaml' "$store" "$1"; }

        # L'ENSEMBLE DES FICHIERS DE SECRETS, en un seul endroit. `list`,
        # `updatekeys` et `recipients` doivent voir exactement le même, sans
        # quoi on audite un ensemble et on rescelle l'autre.
        #
        # `-mindepth 1` et non 2, et ce n'était pas un détail : un secret dont
        # le nom ne contient pas de barre — ce que `secrets edit foo` crée sans
        # un mot — atterrit à la racine du dépôt, donc à la profondeur 1. Il
        # échappait aux TROIS commandes à la fois : jamais listé, jamais
        # rescellé lors d'un enrôlement de machine, jamais montré par l'audit
        # des destinataires. Un fichier que `updatekeys` saute en silence est
        # exactement la panne pour laquelle `--yes` est obligatoire plus bas.
        #
        # `! -name '.*'` en contrepartie : descendre à la profondeur 1 fait
        # entrer `.sops.yaml` dans le lot, que la profondeur 2 écartait par
        # accident. Ce n'est pas un secret, c'est la politique elle-même — sops
        # n'a aucune règle pour lui et `updatekeys` échouerait dessus.
        secretFiles() {
          find "$store" -mindepth 1 -name '*.yaml' ! -name '.*' -not -path '*/.git/*' | sort
        }

        usage() {
          cat >&2 <<'USAGE'
        usage: secrets <commande>

          secrets edit <clé>     édite un secret, le CRÉE s'il n'existe pas,
                                 puis synchronise
                                 ex. secrets edit wireguard/gram_preshared_key
          secrets show <clé>     affiche une valeur
          secrets list           liste les secrets (aucun déchiffrement)
          secrets updatekeys     resynchronise les destinataires des fichiers
                                 ouvrables ICI, après modification de .sops.yaml
          secrets recipients     liste, fichier par fichier, qui peut l'ouvrir
          secrets sync           commit du dépôt privé et mise à jour du lock,
                                 sans passer par l'éditeur

        Les secrets vivent dans un dépôt PRIVÉ ($MY_SECRETS, ~/.secrets par
        défaut). Les secrets système ne sont déchiffrables que par root, et c'est
        voulu : du code lancé sous ton compte ne doit pas pouvoir les lire.

        Et pas par toutes les machines : chaque fichier n'est scellé que pour
        celles qui en ont l'usage. Une machine ne peut donc pas éditer un secret
        qui ne la concerne pas — c'est le comportement recherché, pas une panne.
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

        # QUELLE IDENTITÉ pour ce fichier ? Depuis qu'un secret est un fichier,
        # la question se pose par fichier et non plus par catégorie : `smtp/
        # password` ne s'ouvre qu'en root, `gh/token` qu'avec ta clé de compte,
        # et `cloudflare/api_token` avec l'une ou l'autre.
        #
        # On tranche sur les DESTINATAIRES du fichier, pas par essai-erreur :
        # sops en mode édition sort en échec aussi bien quand il ne peut pas
        # déchiffrer que quand tu abandonnes l'édition, donc « essayer sous ton
        # compte puis retomber sur root » relancerait un éditeur ROOT chaque
        # fois que tu quittes sans enregistrer.
        userPub="$(age-keygen -y "$HOME/.config/sops/age/keys.txt" 2> /dev/null | grep '^age1pq1' | head -1 || true)"

        forUser() {
          [ -n "$userPub" ] && grep -q "recipient: $userPub" "$1"
        }

        # sops réécrit le fichier sur place, donc l'inode et son propriétaire
        # survivent. Mais ça tient à un détail d'implémentation amont : si une
        # version future écrivait un fichier temporaire puis le renommait, le
        # fichier passerait à root et tes commandes git échoueraient dessus. On
        # vérifie plutôt que de le supposer.
        #
        # DEUX PRÉCAUTIONS sur le `chown`, et elles ne sont pas décoratives :
        # c'est un chown lancé en ROOT sur un chemin qui vit sous ton compte,
        # donc sur un chemin qu'un processus non privilégié peut remplacer.
        #
        #   - `-h` : sans lui, chown DÉRÉFÉRENCE. Et `stat` sans `-L` décrit le
        #     LIEN, pas sa cible. Un attaquant qui remplace le fichier par un
        #     lien vers /etc/shadow entre le `stat` final et le `chown` obtient
        #     donc /etc/shadow à son nom — la fenêtre est celle d'un fork+exec
        #     de sudo, largement gagnable en boucle. Le comble : ce helper existe
        #     pour parer un risque hypothétique, et ouvrait un chemin réel vers
        #     root dans la commande dont tout le propos est de le fermer.
        #   - refus net si le chemin EST un lien : `-h` empêche l'escalade, il ne
        #     rend pas l'opération sensée pour autant. Un fichier de secrets qui
        #     devient un lien symbolique, c'est une anomalie à signaler.
        keepOwner() {
          local file="$1"
          shift
          local before after
          if [ -L "$file" ]; then
            echo "secrets : $file est un lien symbolique — refus." >&2
            exit 1
          fi
          before="$(stat -c '%u:%g' "$file")"
          "$@"
          after="$(stat -c '%u:%g' "$file")"
          if [ "$before" != "$after" ]; then
            sudo chown -h "$before" -- "$file"
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

        case "''${1:-help}" in
          edit)
            # Plus de commande par défaut : il n'y a plus de « fichier des
            # secrets » à ouvrir, il faut dire lequel. `secrets` tout court
            # affiche donc l'aide plutôt que d'ouvrir quelque chose au hasard.
            if [ $# -lt 2 ]; then usage; exit 2; fi
            pullFirst
            file="$(secretPath "$2")"

            if [ ! -f "$file" ]; then
              # CRÉATION. Elle se fait sous ton compte quel que soit le secret,
              # et sans sudo : chiffrer ne demande que des clés PUBLIQUES, seule
              # la relecture exige d'être destinataire. Un secret système créé
              # ici sera donc scellé pour la machine qui le consomme, et
              # aussitôt illisible pour toi — ce qui est le comportement voulu.
              #
              # L'ORDRE COMPTE, et sops le fait respecter tout seul : sans règle
              # correspondante dans .sops.yaml, il refuse net (« no matching
              # creation rules »). Un secret se DÉCLARE donc d'abord dans un
              # module, on régénère la politique, et seulement ensuite on pose
              # la valeur. C'est ce qui garantit qu'aucune valeur n'existe sans
              # que ses destinataires aient été calculés.
              #
              # `--config` EXPLICITE, pour la même raison que dans `updatekeys` :
              # sops cherche le `.sops.yaml` à partir du RÉPERTOIRE COURANT, pas
              # de celui du fichier qu'on lui donne. Sans ça, une création lancée
              # d'ailleurs que du dépôt de secrets — c'est-à-dire depuis le dépôt
              # de configuration, neuf fois sur dix — échoue en « config file not
              # found », alors que la règle existe.
              #
              # Uniquement sur la CRÉATION, et pas sur les deux appels d'édition
              # plus bas : eux rechiffrent avec les destinataires inscrits dans le
              # fichier, la politique ne les concerne pas. Leur passer une config
              # ne gagnerait rien et ouvrirait la seule panne que tout ce montage
              # cherche à éviter, une audience réécrite sans qu'on l'ait demandé.
              echo "secrets : $2 n'existe pas, création." >&2
              echo "  Structure attendue dans l'éditeur :" >&2
              echo "    ''${2%%/*}:" >&2
              echo "        ''${2#*/}: <valeur>" >&2
              echo >&2
              mkdir -p "$(dirname "$file")"
              EDITOR="$editorBin" "$sopsBin" --config "$sopsConfig" "$file"
              sync "chore: add secret $2"
              exit 0
            fi

            if forUser "$file"; then
              # Même éditeur figé que sous root : ici il n'y a pas d'élévation à
              # empêcher, mais deux chemins de code qui divergent finissent par
              # diverger sur ce qui compte.
              EDITOR="$editorBin" "$sopsBin" "$file"
            else
              keepOwner "$file" asRoot "$file"
            fi
            sync "chore: update secret $2"
            ;;

          show)
            if [ $# -lt 2 ]; then usage; exit 2; fi
            file="$(secretPath "$2")"
            requireFile "$file"
            if forUser "$file"; then
              "$sopsBin" --decrypt --extract "$(sopsPath "$2")" "$file"
            else
              asRoot --decrypt --extract "$(sopsPath "$2")" "$file"
            fi
            ;;

          list)
            # AUCUN DÉCHIFFREMENT : depuis qu'un secret est un fichier, la liste
            # des noms est la liste des chemins. La version précédente
            # déchiffrait tout puis masquait les valeurs par une expression
            # régulière — un masquage de bonne volonté, que la moindre valeur
            # multiligne ou entre guillemets traversait. Ne pas déchiffrer est
            # une garantie, masquer n'en était pas une.
            secretFiles | sed "s|^$store/||;s|\.yaml$||"
            ;;

          updatekeys)
            pullFirst

            # `--config` explicite : sops cherche .sops.yaml à partir du
            # RÉPERTOIRE COURANT, pas de celui du fichier qu'on lui donne. Sans
            # ça, la commande échoue sur « config file not found » dès qu'on la
            # lance d'ailleurs que du dépôt de secrets — c'est-à-dire presque
            # toujours.
            #
            # EN BOUCLE, et surtout SANS S'ARRÊTER au premier refus : resceller
            # un fichier exige de pouvoir déjà l'ouvrir, or cette machine ne
            # peut plus ouvrir les secrets qui ne la concernent pas. C'est la
            # propriété recherchée, donc un fichier illisible ici n'est pas une
            # erreur — c'est un fichier à resceller DEPUIS L'AUTRE MACHINE. On
            # le dit, et on continue.
            # `--yes` OBLIGATOIRE, et son absence produit la panne la plus
            # sournoise possible ici : `sops updatekeys` DEMANDE CONFIRMATION.
            # Sans lui, dans une boucle, son invite lit le flux qui alimente la
            # boucle, la commande échoue, et si l'on masque sa sortie d'erreur
            # elle annonce « rescellé » en n'ayant rien fait. Constaté : un
            # `updatekeys` vert, un commit qui ne touchait aucun fichier
            # chiffré, et un destinataire manquant découvert au rebuild suivant.
            #
            # La liste est lue EN ENTIER avant la boucle, pour la même raison :
            # tant qu'un `while read` consomme un tube, tout ce qui tourne
            # dedans hérite de ce tube comme entrée standard.
            mapfile -t files < <(secretFiles)

            skipped=""
            for f in "''${files[@]}"; do
              if forUser "$f"; then
                run=("$sopsBin")
              else
                run=(asRoot)
              fi

              # La sortie d'erreur est CAPTURÉE et non jetée : « je ne peux pas
              # déchiffrer ce fichier » est normal ici et se range dans les
              # ignorés, tout le reste est une vraie panne et doit se voir.
              if err="$(keepOwner "$f" "''${run[@]}" --config "$sopsConfig" updatekeys --yes "$f" 2>&1)"; then
                echo "secrets : ''${f#"$store"/} rescellé"
              elif [[ "$err" == *"no matching creation rules"* ]]; then
                echo "secrets : ''${f#"$store"/} — AUCUNE règle dans .sops.yaml, regénère la politique (nix run .#sops-policy)" >&2
              else
                skipped="$skipped ''${f#"$store"/}"
              fi
            done

            if [ -n "$skipped" ]; then
              echo >&2
              echo "secrets : non déchiffrables sur cette machine, à resceller depuis celle qui les détient :" >&2
              for s in $skipped; do echo "  $s" >&2; done
            fi

            sync "chore: update sops recipients"
            ;;

          recipients)
            # LE contrôle qui compte, et le seul qui ne puisse pas se déduire
            # d'un rebuild réussi : un fichier scellé trop largement fonctionne
            # mieux, pas moins. Une erreur de destinataire ne casse rien, elle
            # élargit en silence.
            #
            # Même parcours que `list`, par `secretFiles` : il n'y a aucune
            # raison que les deux commandes ne voient pas le même ensemble de
            # fichiers, et c'est justement quand elles divergent qu'un secret
            # échappe à l'audit.
            #
            # Clés ENTIÈRES et non tronquées. La version précédente coupait à
            # seize caractères après `age1`, ce qui suffit à distinguer deux
            # machines mais pas à faire ce que cette commande existe pour
            # faire : une clé hybride commence par `age1pq1`, une classique par
            # `age1` tout court, et c'est le SEUL endroit du montage qui puisse
            # signaler qu'un fichier a gardé un destinataire classique — sops
            # accepte le mélange sans un mot et le fichier s'ouvre alors avec la
            # seule clé faible. Un préfixe tronqué laissait juste assez de doute
            # pour ne pas le voir.
            secretFiles | while IFS= read -r f; do
              printf '%s\n' "''${f#"$store"/}"
              grep -oE 'recipient: age1[a-z0-9]+' "$f" | sed 's/^/    /' || true
            done
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
