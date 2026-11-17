# Design — Loop

Le langage visuel de Loop. À lire avant toute UI. La page **Device** (`Loop/Features/Device/`)
en est l'implémentation de référence ; la page **Profil** (`Loop/Features/Profile/`) la suit.

## Principes

- **Monochrome d'abord** — encre + matière (Liquid Glass) + type. La profondeur vient de la
  réfraction du verre, pas de la peinture.
- **Une seule teinte accent par page**, utilisée avec sens — jamais une couleur différente par
  ligne/état. Sur Profil : l'accent unique est celui de l'app (`.tint`), porté par l'avatar et les
  icônes SF. Pas d'arc-en-ciel.
- **Teintes warning (orange/rouge) uniquement quand c'est réellement bas/critique** (erreur,
  batterie faible, action destructrice). Pas de teinte décorative par statut.
- **Hiérarchie forte** : un héros, une métrique mise en avant, les faits secondaires regroupés dans
  **une seule surface** (pas N cards), le détail technique replié derrière une ligne (disclosure
  progressive).
- **Liquid Glass natif** (`glassEffect`), iOS 26+, pas de `.ultraThinMaterial` simulé ni de shell
  gradient custom. Pas de fallback legacy (`#available`) — cible 26.0.
- **Micro-interactions premium** (haptique au press, entrée staggered, symbol effects) plutôt que
  de la décoration.

## Anti-patterns ("AI slop") à bannir

- Couleur partout, pills/badges partout.
- Teintes accent arc-en-ciel par état.
- Sur-information.
- Cards répétitives identiques.
- Contrôles morts (labels non-interactifs qui imitent un réglage).

## Patterns de référence (page Device)

- `DeviceSurface` — un seul modifier verre natif, sans fallback (`.deviceSurface()`).
- `PressableScale` — press haptique sur la down-edge, lift-inside-to-fire (`.pressable()`).
- Un point de statut unique pour l'accent ; barre batterie monochrome, vert→ambre→rouge **par
  niveau** seulement.
- Photo sur backlight adaptatif (pas de card) ; `confirmationDialog` pour le destructif.
