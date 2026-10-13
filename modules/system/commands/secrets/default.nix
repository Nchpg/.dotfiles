{
  config,
  pkgs-stable,
  target,
  ...
}:

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
        # `find` et `sed`, que `list` et le rescellement emploient pour parcourir
        # l'arborescence des secrets. Déclarés, et pas laissés au PATH ambiant :
        # c'est toute la raison d'être de ce bloc, et un `find` pris ailleurs
        # serait un binaire choisi à l'exécution dans une commande dont une
        # partie s'exécute sous sudo.
        pkgs-stable.findutils
        pkgs-stable.gnused
        # `grep` et `awk` aussi : forUser, forRoot, misSealed.
        pkgs-stable.gnugrep
        pkgs-stable.gawk
        # Pour relever TA clé publique et savoir, fichier par fichier, si tu en
        # es destinataire — donc s'il faut passer par root ou non.
        pkgs-stable.age
        # Lecture de la révision épinglée dans flake.lock (`status`, `sync`,
        # hooks git).
        pkgs-stable.jq
      ];
      text = ''
        flake="''${MY_FLAKE:-$HOME/.dotfiles}"
        # Chemin RÉSOLU : un ~/.secrets lien symbolique n'était pas parcouru par
        # `find` (aucun fichier vu, `policy` déclarait tout conforme), et un
        # MY_SECRETS terminé par `/` faussait tous les chemins relatifs.
        store="$(realpath -m "''${MY_SECRETS:-$HOME/.secrets}")"
        sopsConfig="$store/.sops.yaml"
        keyFile=/var/lib/sops-nix/key.txt
        # Ancre de la clé système de CETTE machine dans le .sops.yaml, figée au
        # build : c'est par elle qu'on sait, sans sudo, si root ouvrira un
        # fichier (la clé privée est en 0600 root).
        sysAnchor="${target.host}-sys"
        # `secrets policy --yes` : rescellement sans confirmation (usage scripté).
        assumeYes=""

        # UN SECRET = UN FICHIER : `wireguard/gram_preshared_key` vit dans
        # $store/wireguard/gram_preshared_key.yaml, scellé pour les seules
        # machines qui en ont besoin (cf. `secrets policy`).
        secretPath() { printf '%s/%s.yaml' "$store" "$1"; }

        # L'ENSEMBLE DES FICHIERS DE SECRETS, en un seul endroit. `list`,
        # `status` et le rescellement doivent voir exactement le même, sans
        # quoi on contrôle un ensemble et on rescelle l'autre.
        #
        # `-mindepth 1` et non 2, et ce n'était pas un détail : un secret dont
        # le nom ne contient pas de barre — ce que `secrets edit foo` crée sans
        # un mot — atterrit à la racine du dépôt, donc à la profondeur 1. Il
        # échappait à tout à la fois : jamais listé, jamais rescellé lors d'un
        # enrôlement de machine, jamais contrôlé. Un fichier que le rescellement
        # saute en silence est exactement la panne pour laquelle `--yes` est
        # obligatoire plus bas.
        #
        # `! -name '.*'` en contrepartie : descendre à la profondeur 1 fait
        # entrer `.sops.yaml` dans le lot, que la profondeur 2 écartait par
        # accident. Ce n'est pas un secret, c'est la politique elle-même — sops
        # n'a aucune règle pour lui et le rescellement échouerait dessus.
        secretFiles() {
          find "$store" -mindepth 1 -name '*.yaml' ! -name '.*' -not -path '*/.git/*' | sort
        }

        usage() {
          cat >&2 <<'USAGE'
        usage: secrets <commande>

          secrets edit <clé>     édite un secret, le CRÉE s'il n'existe pas
                                 (politique régénérée d'abord), puis
                                 synchronise
                                 ex. secrets edit wireguard/gram_preshared_key
          secrets show <clé>     affiche une valeur
          secrets list           liste les secrets (aucun déchiffrement)
          secrets policy         régénère les règles du .sops.yaml depuis les
                                 configurations, rescelle tout fichier dont les
                                 destinataires diffèrent (après confirmation ;
                                 --yes sans terminal), puis synchronise
          secrets sync           commit et push du dépôt privé, puis mise à
                                 jour du lock, sans passer par l'éditeur
          secrets status         état du dépôt privé face au lock (muet si
                                 tout est synchro ; code 1 si `sync` a du
                                 travail, 2 s'il faut d'abord tirer)

        Les secrets vivent dans un dépôt PRIVÉ ($MY_SECRETS, ~/.secrets par
        défaut). Les secrets système ne sont déchiffrables que par root, et c'est
        voulu : du code lancé sous ton compte ne doit pas pouvoir les lire.

        Et pas par toutes les machines : chaque fichier n'est scellé que pour
        celles qui en ont l'usage. Une machine ne peut donc pas éditer un secret
        qui ne la concerne pas — c'est le comportement recherché, pas une panne.

        Les hooks git du dépôt de config (.githooks) appellent `secrets git-hook`
        pour garder les deux dépôts en phase : pull dans la config = pull ici,
        push de la config = push d'ici d'abord.
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
        #
        # Calculée au premier besoin, pas au lancement : `status` et les hooks
        # git tournent à chaque `git status`/`pull`/`push` dans la config et
        # n'ont rien à faire de la clé.
        userPub=""
        forUser() {
          if [ -z "$userPub" ]; then
            # TOUTES les identités hybrides du fichier : après une rotation, la
            # bonne n'est pas forcément la première.
            userPub="$(age-keygen -y "$HOME/.config/sops/age/keys.txt" 2> /dev/null | grep '^age1pq1' | sed 's/^/recipient: /' || true)"
            [ -n "$userPub" ] || userPub=none
          fi
          [ "$userPub" != none ] && grep -qF "$userPub" "$1"
        }

        # Root ouvrira-t-il ce fichier ? Oui s'il cite la clé de l'ancre
        # `<host>-sys` de cette machine. Sinon, inutile de demander sudo.
        forRoot() {
          local pub
          pub="$(sed -nE "s/^[[:space:]]*-[[:space:]]+&''${sysAnchor}[[:space:]]+(age1[a-z0-9]+).*/\1/p" "$sopsConfig" 2> /dev/null | tail -1)"
          [ -n "$pub" ] && grep -q "recipient: $pub" "$1"
        }

        # LES FICHIERS SCELLÉS AUTREMENT QUE LE .sops.yaml, une ligne par
        # fichier, « type<TAB>fichier<TAB>changements » : type « here » s'il se
        # rescelle d'ici, « elsewhere » si aucune clé d'ici ne l'ouvre,
        # « norule » s'il n'a pas de règle du tout ; changements « +ancre » pour
        # un accès à donner, « -ancre » pour un accès à retirer.
        #
        # Comparer les clés RÉELLES aux clés ATTENDUES couvre tout ce qui fait
        # diverger un fichier, et pas seulement un changement de règle : l'ancre
        # d'une machine réinstallée qu'on remplace (le bloc généré, qui ne cite
        # que `*gram-sys`, ne bouge alors pas d'un octet), une clé en trop, une
        # clé classique oubliée — que sops accepte sans un mot, et qui rouvre le
        # fichier à la seule clé faible.
        #
        # UN SEUL passage d'awk sur le .sops.yaml puis tous les fichiers, et pas
        # un par fichier : la commande tourne après chaque `git status`.
        #   - le .sops.yaml donne les ancres (nom -> clé) et, pour chaque règle
        #     du bloc généré, son motif et les clés de ses alias ;
        #   - chaque fichier donne ses destinataires réels ;
        #   - attendu = clés de la PREMIÈRE règle dont le motif correspond au
        #     chemin (comme sops) ; égalité d'ensembles = même nombre de clés
        #     distinctes et chaque clé attendue présente. Une ancre citée mais
        #     introuvable donne une clé « ? », jamais présente : divergence.
        misSealed() {
          local kind f
          [ -f "$sopsConfig" ] || return 0
          mapfile -t files < <(secretFiles)
          [ ''${#files[@]} -gt 0 ] || return 0
          awk -v store="$store/" '
            function nm(k) { return (k in rev) ? rev[k] : (k ~ /^\?/ ? substr(k, 2) "(ancre introuvable)" : substr(k, 1, 16) "…(inconnue)") }
            NR == FNR {
              sub(/\r$/, "")
              # Ancres : entrées de liste seulement, hors bloc généré — une
              # ligne commentée qui en cite une ne compte pas, comme pour YAML.
              if (!gen && match($0, /^[[:space:]]*-[[:space:]]+&[A-Za-z0-9_-]+[[:space:]]+age1[a-z0-9]+/)) {
                sub(/^[^&]*&/, "&")
                match($0, /&[A-Za-z0-9_-]+[[:space:]]+age1[a-z0-9]+/)
                split(substr($0, RSTART + 1, RLENGTH - 1), a, /[[:space:]]+/)
                key[a[1]] = a[2]; rev[a[2]] = a[1]
              }
              if ($0 ~ /^# ATTENTION : bloc GÉNÉRÉ/) gen = 1
              if (gen && $0 ~ /^  - path_regex:/) { re[++r] = $3; next }
              if (gen && r && match($0, /\*[A-Za-z0-9_-]+/)) alias[r, ++na[r]] = substr($0, RSTART + 1, RLENGTH - 1)
              next
            }
            match($0, /recipient: age1[a-z0-9]+/) {
              k = substr($0, RSTART + 11, RLENGTH - 11)
              if (!((FILENAME, k) in act)) { act[FILENAME, k] = 1; nact[FILENAME]++; actl[FILENAME] = actl[FILENAME] " " k }
            }
            END {
              # La liste vient des ARGUMENTS, pas des lignes lues : un fichier
              # vide est sans aucune ligne, et ne serait jamais contrôlé.
              for (i = 2; i < ARGC; i++) {
                f = ARGV[i]; rel = substr(f, length(store) + 1); m = 0
                for (j = 1; j <= r; j++) if (rel ~ re[j]) { m = j; break }
                if (!m) { print "norule\t" f; continue }
                split("", want); nwant = 0; bad = 0
                for (x = 1; x <= na[m]; x++) {
                  k = (alias[m, x] in key) ? key[alias[m, x]] : "?" alias[m, x]
                  if (!(k in want)) { want[k] = 1; nwant++; if (!((f, k) in act)) bad = 1 }
                }
                if (bad || nwant != nact[f] + 0) {
                  ch = ""
                  for (k in want) if (!((f, k) in act)) ch = ch " +" nm(k)
                  na2 = split(actl[f], al, " ")
                  for (x = 1; x <= na2; x++) if (!(al[x] in want)) ch = ch " -" nm(al[x])
                  print "bad\t" f "\t" substr(ch, 2)
                }
              }
            }
          ' "$sopsConfig" "''${files[@]}" | while IFS=$'\t' read -r kind f ch; do
            if [ "$kind" = norule ]; then
              printf 'norule\t%s\t\n' "$f"
            elif forUser "$f" || forRoot "$f"; then
              printf 'here\t%s\t%s\n' "$f" "$ch"
            else
              printf 'elsewhere\t%s\t%s\n' "$f" "$ch"
            fi
          done
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
          local before after rc=0
          if [ -L "$file" ]; then
            echo "secrets : $file est un lien symbolique — refus." >&2
            return 1
          fi
          before="$(stat -c '%u:%g' "$file")"
          # LE CODE DE LA COMMANDE, rendu à l'appelant après la restauration.
          # Sans ça la fonction rendait celui du dernier `if`, donc 0 : appelée
          # dans un `if err=$(…)`, où `set -e` ne joue pas, elle annonçait
          # « rescellé » des fichiers que sops avait refusés.
          "$@" || rc=$?
          after="$(stat -c '%u:%g' "$file")"
          if [ "$before" != "$after" ]; then
            sudo chown -h "$before" -- "$file"
            echo "secrets : propriétaire de $file restauré ($before)" >&2
          fi
          return "$rc"
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

          if ! git -C "$store" rev-parse -q --verify '@{u}' > /dev/null; then
            if upRef > /dev/null; then
              echo "secrets : $store ne suit pas origin, mise à jour ignorée (git -C $store branch -u origin/$(git -C "$store" branch --show-current))." >&2
            else
              echo "secrets : $store ne suit aucune branche distante, mise à jour ignorée." >&2
            fi
            return 0
          fi

          # Fichiers non suivis exclus : ils ne gênent pas un fast-forward.
          if [ -n "$(git -C "$store" status --porcelain --untracked-files=no)" ]; then
            echo "secrets : modifications non commitées dans $store, mise à jour ignorée." >&2
            return 0
          fi

          # `return` et non `exit` : l'édition s'arrête là-dessus, le hook
          # post-merge seulement le signale (cf. git-hook).
          if ! git -C "$store" pull --ff-only -q; then
            echo "secrets : impossible de mettre $store à jour (historiques divergents ?)." >&2
            echo "  À régler à la main : git -C $store status" >&2
            return 1
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

        # RÉVISION ÉPINGLÉE de l'entrée `secrets`, lue sur l'entrée standard (un
        # flake.lock). Par le nœud que la racine désigne et non par le nom en
        # dur : Nix renomme un nœud (`secrets_2`) quand deux entrées portent le
        # même nom. Seule lecture du lock de tout le montage : `rebuild.sh` passe
        # par `status` et `sync`.
        lockedRev() {
          jq -r '.nodes[.nodes.root.inputs.secrets // ""].locked.rev // empty'
        }

        # Commits locaux absents de la branche suivie. 0 sans branche suivie :
        # il n'y a alors rien vers quoi pousser, `status` le signale à part.
        aheadCount() {
          local up
          up="$(upRef)" || { echo 0; return 0; }
          git -C "$store" rev-list --count "$up..HEAD" 2> /dev/null || echo 0
        }

        # LA BRANCHE DISTANTE de référence : celle que suit la branche courante,
        # sinon origin/<branche courante>. Sans ce repli, un dépôt sans suivi
        # configuré passait pour « ni en avance ni en retard » et `sync`
        # commitait sur une base périmée. Rien (code 1) si aucune n'existe.
        upRef() {
          local b
          git -C "$store" rev-parse -q --verify '@{u}' 2> /dev/null && return 0
          b="$(git -C "$store" branch --show-current)"
          [ -n "$b" ] && git -C "$store" rev-parse -q --verify "origin/$b" 2> /dev/null
        }

        # LES ÉTAGES d'un changement de secret : commit, push, lock. Sans le
        # dernier, le lock du dépôt public continue de pointer sur l'ancienne
        # révision et les machines déploient l'ancienne valeur, sans un message.
        #
        # Chaque étage ne tourne que s'il a du travail, et on reprend où on
        # s'était arrêté : un push qui avait échoué, ou un commit fait à la main
        # dans le dépôt privé, se rattrapent par un simple `secrets sync`.
        sync() {
          local did="" head locked up stray n

          if [ ! -f "$flake/flake.lock" ]; then
            echo "secrets : $flake/flake.lock introuvable, lock non mis à jour." >&2
            return 1
          fi

          # PAS DE COMMIT SUR UNE BASE PÉRIMÉE : si le lock pointe sur une
          # révision que ce clone n'a pas, l'autre machine a poussé depuis. Un
          # commit ici divergerait, le push serait refusé, et la fusion porterait
          # sur des fichiers chiffrés — c'est-à-dire sur rien d'exploitable.
          locked="$(lockedRev < "$flake/flake.lock")"
          if [ -n "$locked" ] && ! git -C "$store" merge-base --is-ancestor "$locked" HEAD 2> /dev/null; then
            echo "secrets : $store est en retard sur le lock (''${locked:0:7})." >&2
            echo "  D'abord : git -C $store pull --ff-only (modifications mises de côté si besoin)" >&2
            return 1
          fi
          # Même raison face à ORIGIN : l'autre machine a pu pousser sans que le
          # lock ait encore bougé (son `sync` laisse flake.lock à commiter).
          if ! git -C "$store" symbolic-ref -q HEAD > /dev/null; then
            echo "secrets : HEAD détaché dans $store, rien synchronisé (git -C $store status)." >&2
            return 1
          fi
          if git -C "$store" remote get-url origin > /dev/null 2>&1; then
            git -C "$store" fetch -q origin 2> /dev/null || true
            if up="$(upRef)" && [ "$(git -C "$store" rev-list --count "HEAD..$up")" != 0 ]; then
              echo "secrets : $store est en retard sur origin." >&2
              echo "  D'abord : git -C $store pull --ff-only (modifications mises de côté si besoin)" >&2
              return 1
            fi
          fi

          # CE QUI SE COMMITE : les fichiers déjà suivis, et les NOUVEAUX
          # fichiers .yaml qui sont bien des fichiers sops (un secret qu'on vient
          # de créer). Rien d'autre : `git add -A` embarquait et poussait tout
          # ce qui traînait dans le dépôt, un fichier en clair compris.
          git -C "$store" add -u
          while IFS= read -r n; do
            if grep -q '^sops:' "$store/$n" 2> /dev/null; then git -C "$store" add -- "$n"; fi
          done < <(git -C "$store" ls-files -o --exclude-standard -- '*.yaml')
          stray="$(git -C "$store" ls-files -o --exclude-standard)"
          if [ -n "$stray" ]; then
            echo "secrets : fichiers non suivis laissés de côté (pas des secrets chiffrés) :" >&2
            printf '%s\n' "$stray" | sed 's/^/  /' >&2
          fi
          if ! git -C "$store" diff --cached --quiet; then
            git -C "$store" commit -q -m "''${1:-chore: update secrets}"
            echo "secrets : commit dans $store"
            did=1
          fi

          # PUSH AVANT LE LOCK : nix récupère l'entrée sur GitHub, où un commit
          # resté local n'existe pas.
          if ! git -C "$store" remote get-url origin > /dev/null 2>&1; then
            echo "secrets : aucun remote sur $store, pousse-le à la main." >&2
          elif ! git -C "$store" rev-parse -q --verify '@{u}' > /dev/null; then
            git -C "$store" push -q -u origin HEAD
            echo "secrets : poussé (branche suivie créée)"
            did=1
          elif [ "$(aheadCount)" != 0 ]; then
            git -C "$store" push -q
            echo "secrets : poussé"
            did=1
          fi

          head="$(git -C "$store" rev-parse HEAD)"
          if [ "$locked" = "$head" ]; then
            [ -n "$did" ] || echo "secrets : rien à synchroniser."
            return 0
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
          # NIX_CONFIG : ce même jeton, sur une machine neuve dont
          # /etc/nix/nix.conf ne l'inclut pas encore (cf. « La boucle
          # d'amorçage » dans docs/secrets.md). Le passer en double ailleurs
          # est sans effet.
          #
          # `safe.directory` posé au passage : git refuse d'opérer sur un dépôt
          # appartenant à quelqu'un d'autre, et ici root travaille sur un dépôt
          # qui t'appartient. Inutile si nix passe par libgit2 sans validation de
          # propriétaire, sans effet de bord s'il ne s'en sert pas.
          # `|| true` : le contrôle qui suit tranche dans tous les cas, et doit
          # s'afficher même si la mise à jour a échoué.
          keepOwner "$flake/flake.lock" \
            sudo env \
              NIX_CONFIG='!include /var/lib/nix/access-tokens.conf' \
              GIT_CONFIG_COUNT=1 \
              GIT_CONFIG_KEY_0=safe.directory \
              GIT_CONFIG_VALUE_0="$flake" \
              "$nixBin" flake update secrets --refresh --flake "$flake" || true
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
          locked="$(lockedRev < "$flake/flake.lock")"
          if [ "$locked" != "$head" ]; then
            echo >&2
            echo "secrets : ATTENTION, le lock ne pointe PAS sur ton dernier commit." >&2
            echo "  dépôt : $head" >&2
            echo "  lock  : $locked" >&2
            echo "  Un rebuild déploierait l'ancienne valeur. Relance : secrets sync" >&2
            return 1
          fi

          echo
          echo "── lock à jour sur $head ──"
          git -C "$flake" --no-pager diff --stat flake.lock
          echo "   git -C $flake commit -m 'chore: bump secrets' -- flake.lock && git -C $flake push"
          # Le lock seul ne suffit pas si la config déclare un secret pas encore
          # commité : le .sops.yaml verrouillé aurait une règle que la config
          # poussée ne déclare pas, et le check sops-policy de la CI échouerait.
          n="$(git -C "$flake" status --porcelain --untracked-files=no | grep -vc ' flake.lock$' || true)"
          if [ "$n" != 0 ]; then
            echo "   ($n autre(s) fichier(s) modifié(s) dans la config : si l'un déclare ce secret,"
            echo "    commite-le avec le lock, sinon le check sops-policy de la CI échouera)"
          fi
        }

        # RESCELLE les fichiers donnés selon le .sops.yaml (sans synchroniser :
        # c'est à l'appelant de le faire, une seule fois). Appelée sur les
        # fichiers « here » de misSealed. Code 1 en cas d'échec.
        #
        # `--config` explicite : sops cherche .sops.yaml à partir du RÉPERTOIRE
        # COURANT, pas de celui du fichier qu'on lui donne. Sans ça, la commande
        # échoue sur « config file not found » dès qu'on la lance d'ailleurs que
        # du dépôt de secrets — c'est-à-dire presque toujours.
        #
        # EN BOUCLE, et SANS S'ARRÊTER au premier refus : un échec n'empêche
        # pas de resceller les autres. (Resceller exige de pouvoir déjà ouvrir
        # le fichier : ceux qu'aucune clé d'ici n'ouvre sont écartés en amont,
        # par misSealed, et signalés comme à faire depuis l'autre machine.)
        #
        # `--yes` OBLIGATOIRE, et son absence produit la panne la plus sournoise
        # possible ici : `sops updatekeys` DEMANDE CONFIRMATION. Sans lui, dans
        # une boucle, son invite lit le flux qui alimente la boucle, la commande
        # échoue, et si l'on masque sa sortie d'erreur elle annonce « rescellé »
        # en n'ayant rien fait. Constaté : un `updatekeys` vert, un commit qui ne
        # touchait aucun fichier chiffré, et un destinataire manquant découvert
        # au rebuild suivant.
        #
        # La liste est lue EN ENTIER avant la boucle, pour la même raison : tant
        # qu'un `while read` consomme un tube, tout ce qui tourne dedans hérite
        # de ce tube comme entrée standard.
        rescell() {
          local f err skipped=() failed=0 run

          for f in "$@"; do
            if forUser "$f"; then
              run=("$sopsBin")
            else
              run=(asRoot)
            fi

            # La sortie d'erreur est CAPTURÉE et non jetée : « aucune clé d'ici
            # n'ouvre ce fichier » est normal et se range dans les ignorés ; tout
            # le reste (sudo refusé, fichier abîmé) est une vraie panne et
            # s'affiche. Avant, tout tombait dans les ignorés.
            if err="$(keepOwner "$f" "''${run[@]}" --config "$sopsConfig" updatekeys --yes "$f" 2>&1)"; then
              echo "secrets : ''${f#"$store"/} rescellé"
            elif [[ "$err" == *"no matching creation rules"* ]]; then
              echo "secrets : ''${f#"$store"/} — AUCUNE règle dans .sops.yaml, regénère la politique (secrets policy)" >&2
              failed=1
            elif [[ "$err" == *"Failed to get the data key"* ]]; then
              skipped+=("''${f#"$store"/}")
            else
              echo "secrets : ''${f#"$store"/} — échec :" >&2
              printf '%s\n' "$err" | sed 's/^/    /' >&2
              failed=1
            fi
          done

          if [ ''${#skipped[@]} -gt 0 ]; then
            echo >&2
            echo "secrets : non déchiffrables sur cette machine, à resceller depuis celle qui les détient :" >&2
            printf '  %s\n' "''${skipped[@]}" >&2
          fi
          return "$failed"
        }

        # LA POLITIQUE APPLIQUÉE, sans étape manuelle : régénère le bloc de
        # règles du .sops.yaml depuis les configurations (`nix run
        # .#sops-policy`), le remplace, puis rescelle chaque fichier dont les
        # destinataires réels diffèrent de ceux qu'il attend (misSealed). Ne
        # synchronise pas. Lancée par `policy` et à chaque `edit` : 0,1 s une
        # fois l'évaluation en cache, et muette si rien n'a changé (`quiet`).
        #
        # Le copier-coller manuel qu'elle remplace avait dérivé : trois règles
        # ajoutées à la main en fin de fichier, le check `sops-policy` du flake
        # en échec permanent.
        #
        # Code : 0 bon, 1 un rescellement a échoué, 2 génération impossible,
        # 3 rescellement refusé à la confirmation.
        applyPolicy() {
          local quiet="''${1:-}" marker="# ATTENTION : bloc GÉNÉRÉ" generated new old kind f ch reply
          local -a here=() hereCh=() elsewhere=() norule=()
          requireFile "$sopsConfig"
          if ! grep -qF "$marker" "$sopsConfig"; then
            echo "secrets : marqueur « $marker » absent de $sopsConfig." >&2
            return 2
          fi

          # Évaluée sous ton compte : l'entrée `secrets` du lock courant est
          # déjà dans le store (le rebuild l'a récupérée). Sinon nix échoue en
          # 404, faute du jeton réservé à root : un `rebuild` d'abord.
          # Une sortie sans le marqueur (vide, tronquée) effacerait toutes les
          # règles : refusée comme un échec.
          #
          # L'erreur de nix est gardée et montrée : un host qui ne s'évalue plus
          # (fichier matériel d'un ISO plus récent, option inconnue) bloque la
          # politique de tout le parc, et la cause doit se lire ici.
          local nixErr
          nixErr="$(mktemp)"
          if ! generated="$("$nixBin" run "$flake#sops-policy" 2> "$nixErr")" \
            || ! grep -qF "$marker" <<< "$generated"; then
            echo "secrets : calcul de la politique impossible ($nixBin run $flake#sops-policy) :" >&2
            grep -v '^warning: Git tree' "$nixErr" | tail -15 | sed 's/^/    /' >&2
            rm -f "$nixErr"
            return 2
          fi
          rm -f "$nixErr"

          # CLONE À JOUR, ou rien : calculée sur des ancres périmées (dépôt sale
          # dont `pullFirst` a sauté la mise à jour), la politique pouvait citer
          # une ancre que ce clone ignore encore.
          local up
          if up="$(upRef)" && [ "$(git -C "$store" rev-list --count "HEAD..$up")" != 0 ]; then
            echo "secrets : $store est en retard sur origin : git -C $store pull --ff-only d'abord." >&2
            return 2
          fi

          # TOUTE ANCRE CITÉE DOIT EXISTER. Sinon le .sops.yaml ne se charge
          # plus (« unknown anchor »), pour aucune commande sops, sur toutes les
          # machines, une fois poussé — et le check du flake, qui compare le
          # bloc, n'y verrait rien. Cas typique : une machine dans deployments
          # dont l'inscription (ses ancres) n'est pas encore arrivée ici.
          local defined cited missing unused
          defined="$(sed -nE 's/^[[:space:]]*-[[:space:]]+&([A-Za-z0-9_-]+)[[:space:]]+age1.*/\1/p' "$sopsConfig" | sort -u)"
          cited="$(grep -oE '\*[A-Za-z0-9_-]+' <<< "$generated" | tr -d '*' | sort -u)"
          missing="$(comm -13 <(printf '%s\n' "$defined") <(printf '%s\n' "$cited") | tr '\n' ' ')"
          if [ -n "''${missing// /}" ]; then
            echo "secrets : la politique cite des ancres absentes du .sops.yaml : $missing" >&2
            echo "  Machine dans deployments pas encore inscrite ? (./init.sh sur elle, puis git -C $store pull)" >&2
            return 2
          fi
          # Machines dont AUCUNE ancre n'est utilisée : inscrites, mais que
          # deployments ne connaît pas encore ici — typiquement `secrets policy`
          # lancé avant le `git pull` de la config. Rien ne leur serait rescellé.
          # (Une machine sans secret système n'utilise pas son ancre -sys : ce
          # n'est pas une anomalie, d'où le regroupement par machine.)
          unused="$(comm -23 <(sed -E 's/-(sys|user)$//' <<< "$defined" | sort -u) \
            <(sed -E 's/-(sys|user)$//' <<< "$cited" | sort -u) | tr '\n' ' ')"
          if [ -n "''${unused// /}" ]; then
            echo "secrets : machine(s) inscrite(s) sans aucun secret ici : $unused— absente(s) de deployments ? (git -C $flake pull)" >&2
          fi

          # Ce qui précède le marqueur (les ancres de clés, éditées à la main)
          # est gardé tel quel ; tout ce qui suit est remplacé, exactement ce
          # que le check du flake compare.
          new="$(sed "/^$marker/,\$d" "$sopsConfig")"$'\n'"$generated"
          # Contenu d'origine gardé : un refus à la confirmation le remet tel
          # quel, au lieu de laisser des règles refusées prêtes à être commitées.
          old="$(cat "$sopsConfig")"
          if [ "$new" != "$old" ]; then
            printf '%s\n' "$new" > "$sopsConfig"
            echo "secrets : règles du .sops.yaml régénérées depuis les configurations."
          fi

          while IFS=$'\t' read -r kind f ch; do
            case "$kind" in
              here) here+=("$f") hereCh+=("$(printf '%-44s %s' "''${f#"$store"/}" "$ch")") ;;
              elsewhere) elsewhere+=("$(printf '%-44s %s' "''${f#"$store"/}" "$ch")") ;;
              norule) norule+=("''${f#"$store"/}") ;;
            esac
          done < <(misSealed)

          if [ ''${#norule[@]} -gt 0 ]; then
            echo "secrets : sans règle dans le .sops.yaml (secret plus déclaré nulle part ?) :" >&2
            printf '  %s\n' "''${norule[@]}" >&2
          fi
          if [ ''${#elsewhere[@]} -gt 0 ]; then
            echo "secrets : à resceller depuis une machine qui peut les ouvrir (secrets policy là-bas) :" >&2
            printf '  %s\n' "''${elsewhere[@]}" >&2
          fi
          if [ ''${#here[@]} -eq 0 ]; then
            [ -n "$quiet" ] || echo "secrets : fichiers ouvrables ici tous scellés selon la politique."
            return 0
          fi

          # LE MOMENT OÙ L'ACCÈS SE DONNE : qui gagne (+) ou perd (-) quel
          # fichier, en clair, avant de resceller. Une ancre poussée à ton insu
          # dans le dépôt privé se verrait ici, avant d'avoir rien ouvert.
          echo "secrets : accès à modifier (+ donné, - retiré) :"
          printf '  %s\n' "''${hereCh[@]}"
          # Sans terminal, PAS d'accord implicite : c'est précisément le moment
          # où un humain doit lire. `secrets policy --yes` pour un usage scripté.
          if [ -z "$assumeYes" ]; then
            if [ -t 0 ]; then
              read -rp "Appliquer ? [Y/n] " reply || reply=n
            else
              echo "secrets : pas de terminal pour confirmer (secrets policy --yes pour forcer)." >&2
              reply=n
            fi
            if [[ "$reply" =~ ^[nN]$ ]]; then
              if [ "$new" != "$old" ]; then printf '%s\n' "$old" > "$sopsConfig"; fi
              echo "secrets : rien rescellé, .sops.yaml laissé tel qu'il était." >&2
              return 3
            fi
          fi
          rescell "''${here[@]}"
        }

        case "''${1:-help}" in
          edit)
            # Plus de commande par défaut : il n'y a plus de « fichier des
            # secrets » à ouvrir, il faut dire lequel. `secrets` tout court
            # affiche donc l'aide plutôt que d'ouvrir quelque chose au hasard.
            if [ $# -lt 2 ]; then usage; exit 2; fi
            pullFirst || exit 1
            file="$(secretPath "$2")"

            # LA POLITIQUE D'ABORD, sans avoir à y penser : un secret qu'on
            # vient de déclarer reçoit sa règle (sans elle sops refuse de le
            # créer), et une dérive des règles est rattrapée au passage. Muette
            # quand rien n'a changé. Bloquante seulement pour une création : un
            # secret existant s'édite avec les destinataires inscrits dans son
            # fichier, la politique n'y est pas indispensable.
            policyRc=0
            applyPolicy quiet || policyRc=$?
            # Refus (3) ou politique incalculable (2) : une création s'arrête là,
            # faute de règle ; un secret existant s'édite quand même.
            if [ "$policyRc" -ge 2 ] && [ ! -f "$file" ]; then exit 1; fi

            if [ ! -f "$file" ] && ! grep -qF "path_regex: ^''${2//./\\.}\\.ya?ml\$" "$sopsConfig"; then
              echo "secrets : aucune règle pour « $2 » : ce secret n'est déclaré dans aucun module." >&2
              echo "  Déclare d'abord sops.secrets.\"$2\" dans le module qui l'utilise (git add si" >&2
              echo "  le fichier est nouveau : un flake ne voit que les fichiers suivis), puis relance." >&2
              # Ce que la politique vient de corriger (règles, rescellements)
              # n'est pas abandonné en plan dans le dépôt privé.
              if [ -n "$(git -C "$store" status --porcelain)" ]; then
                sync "chore: regenerate sops policy" || true
              fi
              exit 1
            fi

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
              # `--config` EXPLICITE, pour la même raison que dans `rescell` :
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
              # Un niveau YAML par segment du nom (a/b/c -> a: b: c:), comme
              # sops-nix le lit.
              ind="    "
              IFS=/ read -ra parts <<< "$2"
              for i in "''${!parts[@]}"; do
                if [ "$i" -eq $((''${#parts[@]} - 1)) ]; then
                  echo "$ind''${parts[$i]}: <valeur>" >&2
                else
                  echo "$ind''${parts[$i]}:" >&2
                fi
                ind="$ind    "
              done
              echo >&2
              mkdir -p "$(dirname "$file")"
              EDITOR="$editorBin" "$sopsBin" --config "$sopsConfig" "$file"
              sync "chore: add secret $2"
              exit 0
            fi

            editRc=0
            if forUser "$file"; then
              # Même éditeur figé que sous root : ici il n'y a pas d'élévation à
              # empêcher, mais deux chemins de code qui divergent finissent par
              # diverger sur ce qui compte.
              EDITOR="$editorBin" "$sopsBin" "$file" || editRc=$?
            else
              keepOwner "$file" asRoot "$file" || editRc=$?
            fi
            # Édition sans effet : 200 (éditeur quitté sans enregistrer) ou vrai
            # échec. Ce que la politique a corrigé juste avant (règles,
            # rescellements) est synchronisé quand même, au lieu de rester en
            # plan dans le dépôt privé.
            if [ "$editRc" != 0 ]; then
              if [ -n "$(git -C "$store" status --porcelain --untracked-files=no)" ]; then
                sync "chore: regenerate sops policy" || true
              elif [ "$editRc" = 200 ]; then
                echo "secrets : $2 inchangé."
              fi
              if [ "$editRc" = 200 ]; then exit 0; fi
              exit "$editRc"
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

          policy)
            if [ "''${2:-}" = --yes ]; then assumeYes=1; fi
            pullFirst || exit 1
            rc=0
            applyPolicy || rc=$?
            # 2 génération impossible, 3 refusé : rien à synchroniser.
            if [ "$rc" = 2 ] || [ "$rc" = 3 ]; then exit 1; fi
            sync "chore: regenerate sops policy"
            exit "$rc"
            ;;

          sync)
            sync "''${2:-chore: update secrets}"
            ;;

          status)
            # LA QUESTION « les deux dépôts sont-ils en phase ? », posée après
            # chaque `git status` dans la config (hook fish_postexec) et avant
            # chaque rebuild. Muette si tout va bien : elle s'affiche sous un
            # status, elle ne doit pas le noyer.
            #
            # Sans réseau : « en retard sur origin » s'entend au dernier fetch
            # (celui de `sync`, du pre-push, ou d'un pull du dépôt privé).
            #
            # CODE DE SORTIE, lu par rebuild.sh :
            #   0  rien que `sync` puisse faire (à jour, ou seulement en retard :
            #      c'est la révision du lock qui se déploie, la réponse est un pull)
            #   1  `sync` a du travail et peut le faire
            #   2  `sync` a du travail mais refuserait : dépôt en retard sur le
            #      lock ou sur origin, il faut tirer d'abord
            [ -d "$store/.git" ] || exit 0
            out=()
            rc=0
            # Dépôt en retard sur le lock ou sur origin : `sync` refuse alors de
            # commiter (cf. sync), la marche à suivre est un pull d'abord.
            stale=0 diverged=0

            dirty="$(git -C "$store" status --porcelain)"
            if [ -n "$dirty" ]; then
              out+=("modifications non commitées :")
              while IFS= read -r l; do out+=("  $l"); done <<< "$dirty"
              rc=1
            fi

            if ! up="$(upRef)"; then
              out+=("aucune branche distante (origin/<branche>) : sync en créera une")
            else
              ahead="$(aheadCount)"
              behind="$(git -C "$store" rev-list --count "HEAD..$up")"
              if [ "$ahead" != 0 ]; then
                out+=("$ahead commit(s) non poussé(s)")
                rc=1
              fi
              if [ "$behind" != 0 ]; then
                out+=("$behind commit(s) sur origin pas encore tirés")
                stale=1
                # En avance ET en retard : historiques divergents.
                if [ "$ahead" != 0 ]; then diverged=1; fi
              fi
            fi

            head="$(git -C "$store" rev-parse HEAD)"
            locked="$({ lockedRev < "$flake/flake.lock"; } 2> /dev/null || true)"
            if [ -n "$locked" ] && [ "$locked" != "$head" ]; then
              if git -C "$store" merge-base --is-ancestor "$locked" HEAD 2> /dev/null; then
                n="$(git -C "$store" rev-list --count "$locked..HEAD")"
                out+=("$n commit(s) pas encore dans le lock : un rebuild déploierait l'ancienne valeur")
                rc=1
              elif git -C "$store" merge-base --is-ancestor HEAD "$locked" 2> /dev/null; then
                out+=("en retard sur le lock (''${locked:0:7})")
                stale=1
              elif git -C "$store" cat-file -e "$locked^{commit}" 2> /dev/null; then
                out+=("HEAD et lock (''${locked:0:7}) ont divergé")
                stale=1 diverged=1
              else
                out+=("le lock pointe sur ''${locked:0:7}, absent d'ici")
                stale=1
              fi
            fi

            # Fichiers scellés autrement que le .sops.yaml : sans réseau ni
            # déchiffrement, une comparaison de clés. N'entre pas dans le code
            # de sortie, qui ne parle que de `sync` : c'est `policy` qui répare.
            nHere=0 nElsewhere=0 nNorule=0
            while IFS=$'\t' read -r kind _ _; do
              case "$kind" in
                here) nHere=$((nHere + 1)) ;;
                elsewhere) nElsewhere=$((nElsewhere + 1)) ;;
                norule) nNorule=$((nNorule + 1)) ;;
              esac
            done < <(misSealed)
            if [ "$nHere" != 0 ]; then
              out+=("$nHere fichier(s) scellé(s) autrement que le .sops.yaml : secrets policy")
            fi
            if [ "$nElsewhere" != 0 ]; then
              out+=("$nElsewhere fichier(s) à resceller depuis une machine qui peut les ouvrir")
            fi
            if [ "$nNorule" != 0 ]; then
              out+=("$nNorule fichier(s) sans règle dans le .sops.yaml (secrets policy pour le détail)")
            fi

            if [ ''${#out[@]} -gt 0 ]; then
              echo "── secrets ($store) ──"
              printf '  %s\n' "''${out[@]}"
              if [ "$diverged" = 1 ]; then
                echo "  → à régler à la main (un pull --ff-only n'y suffira pas) : git -C $store status"
              elif [ "$stale" = 1 ] && [ "$rc" = 1 ]; then
                echo "  → git -C $store pull --ff-only, puis secrets sync"
              elif [ "$stale" = 1 ]; then
                echo "  → git -C $store pull --ff-only"
              elif [ "$rc" = 1 ]; then
                echo "  → secrets sync"
              fi
            fi
            if [ "$rc" = 1 ] && [ "$stale" = 1 ]; then exit 2; fi
            exit "$rc"
            ;;

          git-hook)
            # Appelé par les hooks de .githooks dans le dépôt de config, pas à la
            # main. C'est ce qui permet de ne travailler QUE dans la config : les
            # hooks ne dépendent ni d'un alias (`git st`, `git p`…) ni du client
            # (lazygit, éditeur), contrairement à une fonction shell.
            #
            # Le lock lu est celui du dépôt OÙ TOURNE LE HOOK (git lance les hooks
            # à sa racine), pas forcément $MY_FLAKE : depuis un autre clone ou un
            # worktree, lire celui de ~/.dotfiles laissait passer un push dont le
            # lock pointe sur une révision jamais poussée. Résolu AVANT l'unset.
            repo="$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$flake")"

            # git exporte GIT_DIR et consorts aux hooks : laissés en place, chaque
            # `git -C "$store"` ci-dessous viserait le dépôt de config.
            mapfile -t gitVars < <(git rev-parse --local-env-vars)
            unset "''${gitVars[@]}"
            [ -d "$store/.git" ] || exit 0

            # La révision est-elle dans l'historique courant du dépôt privé ?
            has() { git -C "$store" merge-base --is-ancestor "$1" HEAD 2> /dev/null; }

            case "''${2:-}" in
              post-merge | post-rewrite)
                # Après un pull de la config : le lock a pu avancer sur une
                # révision faite depuis l'autre machine. On tire le dépôt privé
                # pour que `edit` et `list` voient ce qui se déploie.
                #
                # post-merge couvre le pull en fast-forward, rebase ou non ;
                # post-rewrite le pull qui rebase des commits locaux. Ce dernier
                # tourne aussi après un `commit --amend`, où il n'y a rien à tirer.
                if [ "$2" = post-rewrite ] && [ "''${3:-}" != rebase ]; then exit 0; fi
                locked="$({ lockedRev < "$repo/flake.lock"; } 2> /dev/null || true)"
                if [ -z "$locked" ] || has "$locked"; then exit 0; fi

                echo "secrets : le lock a avancé, mise à jour de $store…"
                pullFirst || true
                if ! has "$locked"; then
                  echo "secrets : $store ne contient toujours pas la révision du lock (''${locked:0:7}) — secrets status" >&2
                fi
                # Un hook post-* ne peut rien annuler : on signale, sans échouer.
                exit 0
                ;;

              pre-push)
                # LE garde-fou du serveur. Son auto-upgrade construit la config
                # depuis GitHub, donc avec le lock POUSSÉ : un lock qui pointe
                # sur un commit de secrets resté ici fait échouer le rebuild de la
                # nuit. On pousse donc le dépôt privé d'abord, et on bloque si
                # ce n'est pas possible.
                #
                # Entrée standard : « <réf locale> <sha local> <réf distante>
                # <sha distant> », une ligne par réf poussée. On lit le lock de
                # chaque commit POUSSÉ, pas celui du répertoire de travail.
                #
                # Un hook ne voit pas `--dry-run` : `git push --dry-run` pousse
                # donc réellement le dépôt privé s'il le faut. Sans conséquence
                # sur ce qui se déploie, que seul le lock décide.
                revs=()
                while read -r _ sha _ _; do
                  # sha nul : suppression d'une branche distante.
                  if [[ "$sha" =~ ^0+$ ]]; then continue; fi
                  rev="$(git -C "$repo" show "$sha:flake.lock" 2> /dev/null | lockedRev || true)"
                  if [ -n "$rev" ]; then revs+=("$rev"); fi
                done
                # Sur ORIGIN seulement : une autre remote ne prouve rien. Le
                # premier passage se fie au dernier fetch (une révision vue sur
                # origin y reste, l'historique n'y est pas réécrit) ; le second,
                # après un fetch --prune, tranche.
                onOrigin() { [ -n "$(git -C "$store" branch -r --list 'origin/*' --contains "$1" 2> /dev/null)" ]; }

                # Réseau seulement s'il le faut : un push qui ne touche pas au lock
                # (le cas courant) passe sans aller-retour SSH, et reste possible
                # hors ligne.
                pending=()
                for rev in "''${revs[@]}"; do
                  if ! onOrigin "$rev"; then pending+=("$rev"); fi
                done
                [ ''${#pending[@]} -gt 0 ] || exit 0

                if ! git -C "$store" fetch -q --prune origin; then
                  echo "secrets : fetch de $store impossible, push annulé (git push --no-verify pour passer outre)." >&2
                  exit 1
                fi

                for rev in "''${pending[@]}"; do
                  if onOrigin "$rev"; then continue; fi
                  if has "$rev"; then
                    echo "secrets : le lock poussé pointe sur ''${rev:0:7}, pas encore sur origin — push de $store d'abord."
                    # `|| true` : en cas de refus, c'est le contrôle suivant qui
                    # explique et bloque, avec la marche à suivre.
                    git -C "$store" push -q || true
                  fi
                  if ! onOrigin "$rev"; then
                    echo "secrets : le lock poussé pointe sur ''${rev:0:7}, introuvable sur l'origin de $store." >&2
                    echo "  Le serveur ne pourrait pas le récupérer. secrets status pour le détail," >&2
                    echo "  git push --no-verify pour passer outre." >&2
                    exit 1
                  fi
                done
                ;;

              *)
                echo "secrets : hook inconnu « ''${2:-} »" >&2
                exit 1
                ;;
            esac
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
