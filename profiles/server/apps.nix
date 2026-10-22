{ ... }:

# Applications web servies depuis des images de conteneurs (cf. docs/apps.md).
# Les sites eux-mêmes sont dans apps.json, que le dashboard modifie ; ici, les réglages
# communs et ce que le format JSON ne couvre pas.
{
  systemSettings.appImages = {
    appsFile = ./apps.json;
    lockFile = ./apps.lock.json;
    registry = "ghcr.io/nchpg";

    # Packages privés (myetf, stage) ; un PAT `read:packages` sans expiration.
    login = {
      username = "Nchpg";
      passwordKey = "ghcr/token";
    };

    # think repère une nouvelle image en une minute et la fait épingler (jeton `github/dispatch_token`).
    watch.enable = true;

    # Puis déploie seul ce qui ne touche qu'apps.json et le lock : le reste attend un `rebuild`.
    deploy = {
      enable = true;
      # Avancé avec eux : le prochain `rebuild` à la main repart des sites à jour.
      checkout = "/home/nchpg/.dotfiles";
    };

    # Un message Discord par site mis à jour, modifié, ajouté ou supprimé.
    announce = true;
  };

  # Emplacement d'avant `data` (apps.json garde `"on": "/var/lib/stage"`). Créé avant le
  # conteneur et à son nom : sans CAP_CHOWN, il ne pourrait pas écrire dans un répertoire que
  # podman aurait créé en root. 0700 : le groupe `users` n'a rien à y lire.
  systemd.tmpfiles.rules = [
    "d /var/lib/stage 0700 1000 100 -"
    "d /var/lib/stage/pdfs 0700 1000 100 -"
    "d /var/lib/stage/logos 0700 1000 100 -"
  ];

  # 127.0.0.1 et pas localhost : le wget de busybox essaie ::1 d'abord et le serveur
  # n'écoute qu'en IPv4. À déplacer dans le Dockerfile de stage (HEALTHCHECK).
  systemSettings.apps.stage.containers.web.healthcheck.command =
    "wget -qO- http://127.0.0.1:3000/api/sante > /dev/null || exit 1";
}
