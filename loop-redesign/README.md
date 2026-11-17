# Loop — Redesign App

Dossier de travail pour le retravail des pages de Loop. **Hors repo** (sibling de `loop/`).

## Sommaire

| # | Fichier | Objet |
|---|---|---|
| 00 | `00-audit-actuel.md` | Audit de l'existant : pages, données affichées, composants morts, incohérences |
| 01 | `01-nouvelle-hierarchie.md` | Nouvelle arborescence proposée (Today / Device / Profile → Settings → Advanced) |
| 02 | `02-champs-boutons-inutiles.md` | Boutons / champs / sections à supprimer ou rationaliser |
| 03 | `03-donnees-manquantes.md` | Données déjà disponibles côté store/moteur mais non affichées |
| 04 | `04-features-a-implementer.md` | Features à porter depuis Goose, my-whoop, openwhoop-gen4-debug, OpenStrap/edge |
| 05 | `05-inventaire-depots-externes.md` | Inventaire feature-par-feature des 4 dépôts externes |
| 06 | `06-features-wiring-vs-systeme.md` | Classification : wiring UI pur vs système à construire |
| prompt-smart-alarm.md | Prompt agent IA pour implémenter le smart alarm 2-couches |
| prompt-refactoring-p0.md | Prompt agent IA pour finir le refactoring P0 (shells + FR + deep-links + sync toast) |
| prompt-refonte-sleep.md | Prompt agent IA pour refondre profondément la page Sleep (UX/UI + progressive disclosure + micro-animations) |

## Sources externes explorées

- `/Users/theo/dev/whoop/goose` — GooseSwift (iOS, alpha très complète, WHOOP 5.0 + Gen4)
- `/Users/theo/dev/whoop/my-whoop` — OpenWhoop (iOS legacy, server-dependent) + cadrage redesign
- `/Users/theo/dev/whoop/openwhoop-gen4-debug` — Rust (codec + algos purs)
- `https://github.com/OpenStrap/edge` — Flutter (12+ écrans, déterministe, screenshoots dispo)

## Ordre de lecture recommandé

1. `00` pour comprendre l'existant
2. `01` pour valider la nouvelle hierarchie
3. `02` + `03` pour le nettoyage / enrichment par page
4. `04` pour le backlog feature
5. `05` pour le détail quand tu implémentes une feature donnée
