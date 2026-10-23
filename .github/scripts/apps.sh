#!/usr/bin/env bash
# Usage: apps.sh pin|edit  (depuis la racine du dépôt ; entrées par l'environnement)
#   pin  : IMAGES='[{"ref":…,"digest":…,"revision":…,"port":…}]' — nouveaux digests d'images déjà suivies.
#   edit : APP, ENTRY (JSON, ou `null` pour supprimer), BASE (empreinte de l'entrée lue, `new` si absente),
#          IMAGES (digests des références que l'entrée ajoute), MESSAGE (facultatif), REGISTRY.
#   peer : APP (nom de l'appareil VPN), ENTRY ({"publicKey", "address", "trusted"}, ou `null` pour le
#          retirer). Écrit vpn-peers.json ; l'appareil n'est autorisé qu'avec sa clé pré-partagée dans
#          les secrets (exigé par le module wireguard), donc jamais par ce seul commit.
# Écrit apps.json et/ou le lock, et sur stdout `subject=<message de commit>` (vide si rien ne change).
# Les entrées viennent d'un appel externe : tout est vérifié avant d'écrire, et le lock reste cohérent
# avec apps.json (chaque image suivie y a son digest, aucune entrée orpheline).
set -euo pipefail

apps=profiles/server/apps.json
lock=profiles/server/apps.lock.json
peers=profiles/server/vpn-peers.json

die() {
    echo "::error::$*" >&2
    exit 1
}

# Écriture d'un coup, droits du fichier d'origine gardés.
replace() {
    local file=$1 tmp
    tmp=$(mktemp "$file.XXXXXX")
    cat >"$tmp"
    chmod --reference="$file" "$tmp"
    mv "$tmp" "$file"
}

# Filtre jq : les images fournies entrent dans le lock (le port connu reste si l'image n'en donne pas).
# shellcheck disable=SC2016  # $images, $i : variables jq
put_images='reduce $images[] as $i (.; .[$i.ref] = {digest: $i.digest, port: ($i.port // .[$i.ref].port), revision: $i.revision})'

# Entrées d'images : forme commune à pin et edit. $1 : `known` (déjà dans le lock) ou `free`.
check_images() {
    local bad
    jq -e 'type == "array" and length <= 20' <<<"$IMAGES" >/dev/null \
        || die "IMAGES doit être une liste JSON de 20 entrées au plus"
    bad=$(jq -r --slurpfile lock "$lock" --arg mode "$1" '
        .[] | . as $i | select(
            ($i | type) != "object"
            or ($i.ref | type) != "string"
            or ($i.ref | test("^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]{1,128}$") | not)
            or ($mode == "known" and ($lock[0] | has($i.ref) | not))
            or (($i.digest | type) != "string" or ($i.digest | test("^sha256:[0-9a-f]{64}$") | not))
            or ($i.revision != null and (($i.revision | type) != "string" or ($i.revision | test("^[0-9a-f]{7,40}$") | not)))
            or ($i.port != null and (($i.port | type) != "number" or $i.port < 1 or $i.port > 65535 or ($i.port | floor) != $i.port))
        ) | ($i.ref? // $i | tostring)' <<<"$IMAGES")
    [ -z "$bad" ] || die "image(s) refusée(s) (référence, digest, révision ou port mal formés$([ "$1" = known ] && echo ", ou absente du lock")) : $bad"
}

# Référence complète de chaque image d'apps.json, environnements compris : un environnement
# prend les conteneurs de sa section (les siens ou ceux d'un parent) avec le tag de sa branche
# (`feat/charts` -> `feat-charts`) ou son `pin`. Mêmes règles que apps-file.nix.
refs_of_apps() {
    jq -r --arg reg "$REGISTRY" '
        def tagof: gsub("[^A-Za-z0-9._-]"; "-");
        def untag: split("/") | (.[:-1] + [.[-1] | split(":")[0]]) | join("/");
        def ctrs($s; $id; $n): if $id == null then $s.containers
            elif $n > 16 then {}
            else $s.environments[$id] as $v | if $v.containers then $v.containers else ctrs($s; $v.from; $n + 1) end end;
        [.[] as $s
         | ($s.containers[] | .image),
           (($s.environments // {}) | to_entries[] | .key as $id | .value as $v
            | ctrs($s; $id; 0)[] | "\(.image | untag):\($v.pin // ($v.branch | tagof))")
         | if test("/") then . else "\($reg)/\(.)" end] | unique[]' "$apps"
}

pin() {
    local changed names rev
    jq -e 'length > 0' <<<"$IMAGES" >/dev/null 2>&1 || die "IMAGES ne doit pas être vide"
    check_images known

    changed=$(jq -r --slurpfile lock "$lock" '.[] | . as $i | select($lock[0][$i.ref].digest != $i.digest or ($i.port != null and $lock[0][$i.ref].port != $i.port)) | $i.ref' <<<"$IMAGES")
    if [ -z "$changed" ]; then
        echo "rien à changer : les digests sont déjà dans le lock" >&2
        return 0
    fi

    jq --sort-keys --indent 2 --argjson images "$IMAGES" "$put_images" "$lock" | replace "$lock"

    # `ghcr.io/nchpg/rlkart-frontend:main` -> `rlkart-frontend`.
    names=$(sed -E 's#.*/##; s#:[^:]*$##' <<<"$changed" | sort -u | paste -sd, - | sed 's/,/, /g')
    rev=$(jq -r '[.[].revision | select(. != null)] | unique | if length == 1 then " (\(.[0][0:7]))" else "" end' <<<"$IMAGES")
    echo "subject=chore(apps): bump ${names}${rev}"
}

# Liste des problèmes d'une entrée, vide si elle est valide (même contrat que apps-file.nix).
validate_entry() {
    jq -r --arg app "$APP" '
        def strs($re): type == "array" and all(.[]; type == "string" and test($re));
        def path: "^/[A-Za-z0-9._~/-]*$";
        def keys_in($ok; $w): (keys - $ok) as $x | if $x == [] then empty else "\($w)clé(s) inconnue(s) \($x | join(", "))" end;
        def named($w): if has("name") and ((.name | type) != "string" or (.name | length) == 0 or (.name | length) > 32 or (.name | explode | any(. < 32))) then "\($w)name : 32 caractères au plus" else empty end;
        def access($w):
            (if has("expose") and (.expose | IN("public", "vpn") | not) then "\($w)expose : public ou vpn" else empty end),
            (if .expose == "vpn" and ((.devices | type) != "array" or (.devices | length) == 0) then "\($w)vpn : au moins un appareil dans devices" else empty end),
            (if has("devices") and .expose != "vpn" then "\($w)devices : seulement avec expose = vpn" else empty end),
            (if has("devices") and (.devices | strs("^[A-Za-z0-9_-]{1,32}$") | not) then "\($w)devices : noms invalides" else empty end),
            (if has("sso") and (.sso | type) != "boolean" then "\($w)sso : booléen" else empty end);
        def options($w):
            (if has("internetAccess") and (.internetAccess | type) != "boolean" then "\($w)internetAccess : booléen" else empty end),
            (if has("probe") and ((.probe | type) != "string" or (.probe | test(path) | not)) then "\($w)probe : chemin invalide" else empty end),
            (if has("rateLimit") and ((.rateLimit | strs(path) | not) or (.rateLimit | length) > 20) then "\($w)rateLimit : chemins invalides" else empty end);
        def subdomain($w): if has("subdomain") and ((.subdomain | type) != "string" or (.subdomain | test("^(@|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)$") | not)) then "\($w)subdomain invalide" else empty end;
        # $child : image sans tag (il vient de la branche), pas de data.on.
        def containers($w; $child):
            if (.containers | type) != "object" or (.containers | length) == 0 or (.containers | length) > 5 then "\($w)containers : de 1 à 5 conteneurs" else
                (.containers | keys) as $names
                | (if all($names[]; test("^[a-z][a-z0-9-]{0,15}$")) then empty else "\($w)noms de conteneurs invalides" end),
                  (if ($names | length) > 1 and (has("entrypoint") | not) then "\($w)entrypoint requis avec plusieurs conteneurs" else empty end),
                  (if has("entrypoint") and (.entrypoint | IN($names[]) | not) then "\($w)entrypoint : conteneur inconnu" else empty end),
                  (.containers | to_entries[] | .key as $c | .value
                    | if type != "object" then "\($w)\($c) : objet attendu" else
                      keys_in(["image", "memory", "dependsOn", "data", "secrets"]; "\($w)\($c) : "),
                      (if $child then
                          (if (.image | type) != "string" or (.image | test("^[a-z0-9][a-z0-9._/-]*$") | not) then "\($w)\($c) : image invalide (nom sans tag)" else empty end)
                       else
                          (if (.image | type) != "string" or (.image | test("^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]{1,128}$") | not) then "\($w)\($c) : image invalide (nom:tag)" else empty end)
                       end),
                      (if has("memory") and ((.memory | type) != "string" or (.memory | test("^[1-9][0-9]{0,4}[mg]$") | not)) then "\($w)\($c) : memory invalide" else empty end),
                      (if has("dependsOn") and ((.dependsOn | strs("^[a-z][a-z0-9-]{0,15}$") | not) or any(.dependsOn[]; . == $c or (IN($names[]) | not))) then "\($w)\($c) : dependsOn invalide" else empty end),
                      (if has("secrets") and (.secrets | strs("^\($app)/[A-Za-z0-9._-]+$") | not) then "\($w)\($c) : secrets hors de \($app)/" else empty end),
                      (if has("data") and ((.data | type) != "array" or any(.data[];
                          type != "object" or (keys - ["path", "on"]) != []
                          or (.path | type) != "string" or (.path | test("^/[A-Za-z0-9._/-]+$") | not) or (.path | test("\\.\\."))
                          or (has("on") and ($child or (.on | type) != "string" or (.on | test("^(/var/lib/\($app)(/[A-Za-z0-9._-]+)*|\($app)-[A-Za-z0-9._-]+)$") | not) or (.on | test("\\.\\."))))))
                        then "\($w)\($c) : data invalide (chemin absolu ; on = /var/lib/\($app)/… ou volume \($app)-…, à la racine seulement)" else empty end)
                      end)
            end;
        # Un environnement remonte ses parents sans boucle (16 niveaux au plus).
        def rooted($envs; $id; $n): if $id == null then true elif $n > 16 or ($id | type) != "string" or ($envs[$id] | type) != "object" then false else rooted($envs; $envs[$id].from; $n + 1) end;
        if type != "object" then "entrée : objet attendu" else
        keys_in(["name", "subdomain", "expose", "devices", "sso", "internetAccess", "probe", "entrypoint", "rateLimit", "containers", "environments"]; ""),
        named(""), subdomain(""), access(""), options(""), containers(""; false),
        (if has("environments") then
            if (.environments | type) != "object" or (.environments | length) > 8 then "environments : 8 environnements au plus" else
            .environments as $envs
            | ($envs | to_entries[] | .key as $id | "\($id) : " as $w | .value
                | if ($id | test("^[a-z][a-z0-9-]{0,15}$") | not) then "environnement « \($id) » : identifiant invalide"
                  elif type != "object" then "\($w)objet attendu" else
                  keys_in(["name", "branch", "from", "data", "pin", "subdomain", "expose", "devices", "sso", "containers", "entrypoint", "internetAccess", "probe", "rateLimit"]; $w),
                  named($w), subdomain($w),
                  (if (.branch | type) != "string" or (.branch | test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$") | not) then "\($w)branch manquante ou invalide" else empty end),
                  (if has("from") and ((.from | type) != "string" or .from == $id or (.from as $f | $envs | has($f) | not)) then "\($w)from : un autre environnement du site" else empty end),
                  (if rooted($envs; $id; 0) | not then "\($w)boucle d'\''héritage (from)" else empty end),
                  (if has("data") and (.data | IN("separate", "copy", "shared") | not) then "\($w)data : separate, copy ou shared" else empty end),
                  (if has("pin") and ((.pin | type) != "string" or (.pin | test("^sha-[0-9a-f]{7,40}$") | not)) then "\($w)pin : un tag sha-<commit>" else empty end),
                  (if has("expose") then access($w) elif has("devices") or has("sso") then "\($w)devices et sso vont avec expose" else empty end),
                  (if has("internetAccess") then options($w) elif has("probe") or has("rateLimit") then "\($w)probe et rateLimit vont avec internetAccess" else empty end),
                  (if has("containers") then containers($w; true) elif has("entrypoint") then "\($w)entrypoint va avec containers" else empty end)
                  end)
            end
         else empty end)
        end' <<<"$ENTRY"
}

edit() {
    local current problems refs missing subject bad
    [[ "$APP" =~ ^[a-z0-9][a-z0-9-]{0,11}$ ]] || die "nom de site invalide : $APP"
    [[ "$BASE" =~ ^(new|[0-9a-f]{64})$ ]] || die "empreinte invalide"
    [ "${#ENTRY}" -le 20000 ] || die "entrée trop grande"
    [[ "$REGISTRY" =~ ^[a-z0-9.-]+/[a-z0-9_.-]+$ ]] || die "REGISTRY invalide"

    # L'entrée a-t-elle bougé depuis que la page l'a lue ? Alors on n'écrase rien.
    if jq -e --arg a "$APP" 'has($a)' "$apps" >/dev/null; then
        current=$(printf '%s' "$(jq -cS --arg a "$APP" '.[$a]' "$apps")" | sha256sum | cut -c1-64)
    else
        current=new
    fi
    [ "$current" = "$BASE" ] || die "conflit : $APP a changé sur main depuis la lecture de la page (attendu $BASE, trouvé $current). Recharge la page."

    if [ "$ENTRY" = null ]; then
        [ "$current" != new ] || die "$APP n'existe pas"
        subject="feat($APP): remove site"
        jq -S --indent 2 --arg a "$APP" 'del(.[$a])' "$apps" | replace "$apps"
    else
        jq -e . <<<"$ENTRY" >/dev/null 2>&1 || die "ENTRY n'est pas du JSON"
        problems=$(validate_entry) || die "validation de l'entrée impossible"
        [ -z "$problems" ] || die "entrée refusée : $(paste -sd';' - <<<"$problems")"
        if [ "$current" = new ]; then subject="feat($APP): add site"; else subject="feat($APP): update site"; fi
        jq -S --indent 2 --arg a "$APP" --argjson e "$ENTRY" '.[$a] = $e' "$apps" | replace "$apps"
        # Un environnement est servi comme l'app `<site>-<id>` : ce nom ne doit être celui de personne.
        bad=$(jq -r '[to_entries[] | .key as $s | $s, ((.value.environments // {}) | keys[] | "\($s)-\(.)")]
            | group_by(.) | map(select(length > 1) | .[0])[]' "$apps")
        [ -z "$bad" ] || die "nom déjà pris : $bad (un environnement est servi sous le nom <site>-<id>)"
    fi

    # Lock : digests fournis pour les nouvelles références, puis ni manque ni orpheline.
    check_images free
    refs=$(refs_of_apps)
    bad=$(jq -r --arg refs "$refs" '.[].ref | select(IN($refs | split("\n")[]) | not)' <<<"$IMAGES")
    [ -z "$bad" ] || die "image(s) fournie(s) mais pas utilisées par apps.json : $bad"
    jq --sort-keys --indent 2 --argjson images "$IMAGES" --arg refs "$refs" \
        "$put_images"' | with_entries(select(.key | IN($refs | split("\n")[])))' "$lock" | replace "$lock"
    missing=$(jq -r --arg refs "$refs" '($refs | split("\n")) - keys | .[]' "$lock")
    [ -z "$missing" ] || die "image(s) sans digest dans le lock : $missing (à fournir dans IMAGES)"

    if [ -n "${MESSAGE:-}" ]; then
        # Accents compris (${#} compte les caractères en UTF-8) ; pas de retour ni de caractère de contrôle.
        [[ ${#MESSAGE} -le 100 && "$MESSAGE" != *[[:cntrl:]]* ]] || die "MESSAGE : une ligne de 100 caractères au plus"
        subject=$MESSAGE
    fi
    if git diff --quiet -- "$apps" "$lock"; then
        echo "rien à changer" >&2
        return 0
    fi
    echo "subject=$subject"
}

# Appareil VPN : ajout ou retrait dans vpn-peers.json (les appareils de vpn.nix n'y sont pas : leur
# unicité est vérifiée par le dashboard et par l'évaluation Nix).
peer() {
    local subject
    [[ "${APP:-}" =~ ^[a-z0-9_]{1,24}$ ]] || die "APP : nom d'appareil en [a-z0-9_], 24 caractères au plus"
    [ -f "$peers" ] || echo '{}' >"$peers"
    if [ "${ENTRY:-}" = null ]; then
        jq -e --arg n "$APP" 'has($n)' "$peers" >/dev/null || die "$APP n'est pas dans $peers"
        jq -S --indent 2 --arg n "$APP" 'del(.[$n])' "$peers" | replace "$peers"
        subject="feat(vpn): remove $APP"
    else
        jq -e . <<<"${ENTRY:-}" >/dev/null 2>&1 || die "ENTRY n'est pas du JSON"
        jq -e 'type == "object" and (keys - ["publicKey", "address", "trusted"] | length == 0)
            and (.publicKey | type == "string" and test("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$"))
            and (.address | type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))
            and ((.trusted // false) | type == "boolean")' <<<"$ENTRY" >/dev/null \
            || die "ENTRY : {publicKey (clé WireGuard), address (IPv4), trusted (booléen)} attendu"
        jq -e --arg n "$APP" 'has($n) | not' "$peers" >/dev/null || die "$APP existe déjà dans $peers"
        jq -e --arg n "$APP" --argjson e "$ENTRY" '[to_entries[] | select(.value.address == $e.address or .value.publicKey == $e.publicKey)] | length == 0' "$peers" >/dev/null \
            || die "adresse ou clé publique déjà prise dans $peers"
        jq -S --indent 2 --arg n "$APP" --argjson e "$ENTRY" '.[$n] = $e' "$peers" | replace "$peers"
        subject="feat(vpn): add $APP"
    fi
    echo "subject=$subject"
}

case "${1:-}" in
    pin) pin ;;
    edit) edit ;;
    peer) peer ;;
    *) die "usage : apps.sh pin|edit|peer" ;;
esac
