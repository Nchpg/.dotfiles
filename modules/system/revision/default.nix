{ inputs, dotfilesContent, ... }:

{
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
  environment.etc."dotfiles/content".text = dotfilesContent;
}
