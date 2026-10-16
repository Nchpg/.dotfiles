{
  config,
  optionName,
  need ? "a besoin du secret sops",
}:
[
  {
    assertion = config.userSettings.sops.available;
    message = "${optionName} ${need}, mais le user « ${config.userSettings.user} » n'a pas accès à la clé (ni keyOwner ni root). Active-le pour le keyOwner, ou donne à ce user la clé age.";
  }
]
