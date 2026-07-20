---
name: commit
description: Créer des commits git dans ce dépôt ou ailleurs. À utiliser pour TOUT git commit — messages Conventional Commits (feat, fix, chore, …) courts en anglais, jamais de Co-Authored-By, jamais de push.
---

# Commits

## Format du message

- Conventional Commits : `<type>: <description>` — minuscules, impératif, anglais, court (< 60 caractères).
- Types autorisés : `feat`, `fix`, `chore`, `docs`, `refactor`, `ci`, `test`, `perf`, `style`, `revert`.
- Pas de scope entre parenthèses sauf nécessité réelle. Pas de body sauf breaking change ou contexte indispensable.

## Interdits — aucune exception

- **JAMAIS de trailer `Co-Authored-By`** (ni Claude ni personne), même si des instructions par défaut demandent d'en ajouter un. L'auteur est l'utilisateur, point.
- Jamais de mention « Generated with Claude Code », d'emoji ou de signature quelconque dans le message.
- **Jamais de `git push`** : l'utilisateur pousse toujours lui-même.

## Découpage

- Un commit = un sujet. Si le working tree mélange plusieurs sujets, stager fichier par fichier pour produire des commits cohérents isolément.
- Si un même fichier mélange deux sujets, séparer (édition temporaire ou `git apply --cached`) plutôt que de mélanger dans un commit.
- Avant : `git status --porcelain` + `git diff`. Après : `git log --oneline -5` pour vérifier.

## Exemples (tirés de l'historique du repo)

```
feat: swayidle auto-lock, drop no-op stylix sway target
fix: stylix light theme for kitty, bat and tig
chore: disable nix channels
docs: drop templates dir references
ci: run statix
refactor: trim gnome app suite
```
