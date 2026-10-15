# Assertion sops répétée à l'identique dans les modules qui ont besoin de la
# clé age (git/gh/wakatime/calendar-tui...) : sans accès à la clé,
# l'activation échouerait au déchiffrement avec un message obscur. On
# l'attrape ici à l'éval avec un message clair.
{
  config,
  # Chemin de l'option qui déclenche le besoin (ex. "userSettings.gh").
  optionName,
  # Complément après "<optionName> " (ex. "a besoin du secret sops (token GitHub)").
  need ? "a besoin du secret sops",
}:
[
  {
    assertion = config.userSettings.sops.available;
    message = "${optionName} ${need}, mais le user « ${config.userSettings.user} » n'a pas accès à la clé (ni keyOwner ni root). Active-le pour le keyOwner, ou donne à ce user la clé age.";
  }
]
