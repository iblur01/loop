# Spec de design — Loop (référence avant refonte)

Date : 2026-11-15. Statut : **proposition décisionnelle**, à valider avant toute implémentation.
Sources : `docs/design/AUDIT-DESIGN-LOOP.md` (cité « audit §n »), `docs/design/ANALYSE-STYLE-CENTURY.md`
(cité « réf. §n »), `DESIGN.md`. Les renvois `fichier:ligne` sur l'existant viennent de l'audit, sauf
mention « vérifié hors audit ».

Conventions :
- **à valider** : valeur proposée, non testée en simulateur.
- **estimé** : valeur reprise de l'analyse de référence (lecture de captures compressées).
- Les contrastes de cette spec sont calculés (WCAG 2.x) sur fonds opaques. Le verre n'est pas mesuré.

---

## 1. Principes

1. **Une métrique, une teinte, partout** : chaque métrique a une seule définition de couleur, partagée par l'anneau, la tuile, la page détail, le widget WidgetKit et la Live Activity. Constat : Recovery a 4 définitions et le widget reste vert à 10 % (audit §5.2, §7.3).
2. **La couleur signale, l'encre porte le chiffre** : le chiffre reste en texte primaire, la teinte vit sur l'icône, l'unité, la barre et la courbe. Constat : aujourd'hui la couleur n'existe que sur des icônes de 15 pt et des barres de 6 pt (audit §1.3), ce qui produit l'effet neutre (audit §1.10).
3. **L'état a son propre vocabulaire** : bon / moyen / faible ne s'expriment que par trois couleurs d'état accompagnées d'un mot ou d'un symbole, jamais par la teinte d'une métrique (réf. §2.1, §10).
4. **Verre pour ce qui flotte, opaque pour ce qui se lit** : Liquid Glass natif sur la navigation, les actions et les sheets ; cartes de données opaques. Constat : 49 cartes en verre incolore (audit §1.2), 9 verres imbriqués (audit §3.3), flou UIKit sur la tab bar (audit §3.2).
5. **Un héros, puis des widgets utiles** : chaque écran ouvre sur un score unique, suivi de widgets classés par utilité, et un widget sans donnée disparaît.
6. **Tokens ou rien** : couleurs, styles de texte, rayons et espacements viennent d'un seul catalogue. Constat : 354 tailles fixes, aucun token de rayon ni d'espacement (audit §2.2-2.4, §6.2).

---

## 2. Tokens cibles

Un seul fichier source, `Loop/Shared/DesignTokens/` (nom à valider), partagé entre l'app et `LoopWidgets/`
(cible commune dans `project.yml`). Couleurs définies en `Color(light:dark:)` ou en colorsets d'un
catalogue partagé. Remplace : `PopPalette.swift`, `TodayRingModel` couleurs (:21-29),
`RecoveryBand.color`/`glowColor` (RecoveryCoachModel.swift:420-437), `StrainBand.color`/`glowColor`
(StrainCoachModel.swift:451-468), `SleepBand`, `StressBand`, `DeviceSnapshot.batteryColor`
(:126-133), hex des widgets (MainTabView.swift:98-131, LoopWidgetSnapshotStore.swift:19-21),
couleurs de la Live Activity (BraceletBatteryLiveActivityWidget.swift:176-186) — audit §2.1.

### 2.1 Surfaces et texte (à valider)

| Token | Rôle | Clair | Sombre |
|---|---|---|---|
| `bg.base` | fond d'écran (uni, remplace `AppBackground`) | `#F2F2F7` | `#000000` |
| `bg.sheet` | fond de sheet si un fond opaque est requis | `#F7F7FA` | `#0E0E10` (estimé) |
| `surface.card` | carte de données | `#FFFFFF` | `#1A1A1D` |
| `surface.nested` | carte imbriquée, bloc de conseil, ligne de zone | `#F2F2F6` | `#2A2A2E` |
| `surface.highlight` | colonne du jour courant, option active | `#E4E4EA` | `#3A3A3E` |
| `stroke.card` | filet 1 px de carte | noir 6 % | blanc 8 % (estimé) |
| `track.empty` | piste et segments vides | `#E2E2E8` | `#2C2C2E` |
| `text.primary` | chiffres, titres | `#0B0B0C` | `#FFFFFF` |
| `text.secondary` | libellés, unités neutres, conseil | `#5E5E66` | `#A6A6AD` |
| `text.tertiary` | décoratif uniquement (bornes d'axe vides, séparateurs textuels) | `#8A8A90` | `#7C7C83` |

`text.secondary` remplace `.secondary` système en clair, qui fait ≈3,3:1 sur `#F2F2F7` (audit §6.1).

### 2.2 États (à valider)

| Token | Clair | Sombre | Symbole obligatoire associé |
|---|---|---|---|
| `state.good` | `#157A3F` | `#34D17A` | `checkmark.circle.fill` ou mot |
| `state.fair` | `#8F6000` | `#FFC233` | `minus.circle.fill` ou mot |
| `state.poor` | `#C92F2A` | `#FF5A4F` | `exclamationmark.triangle.fill` ou mot |
| `state.neutral` (calibrage, normal, inconnu) | `#5E5E66` | `#A6A6AD` | `circle.dashed` ou mot |

Seuils : un seul jeu par notion, défini à côté du token (voir §2.4). Corrige les seuils sommeil 55/60,
strain ±1 / ±12 %, batterie 5/15/20/35 (audit §5.2).

### 2.3 Teinte par métrique (une seule définition, à valider)

| Token | Métrique | Clair | Sombre | Remarque |
|---|---|---|---|---|
| `metric.recovery` | Récupération | = `state.*(score)` | = `state.*(score)` | métrique d'état : sa couleur **est** l'état. Sans score : `state.neutral` |
| `metric.strain` | Charge / effort | `#0070B8` | `#1FB6FF` | garde la famille cyan actuelle des anneaux (#00AAF2, TodayRingModel.swift:22) |
| `metric.sleep` | Sommeil | `#5A45D6` | `#8E7CFF` | proche de `Pop.indigo` (#7A6BFF, PopPalette.swift:11) |
| `metric.cardio` | FC repos/moy/max | `#C8155A` | `#FF3D7F` | rose (famille estimée réf. §1.2) |
| `metric.hrv` | VFC | `#007D6E` | `#2FD9C5` | turquoise, éloigné du vert d'état |
| `metric.stress` | Stress | `#8A3CCF` | `#C77DFF` | l'état stress (bas/élevé) passe par `state.*`, pas par cette teinte |
| `metric.energy` | Énergie active (kcal) | `#B4500A` | `#FF8A3D` | orange |
| `metric.steps` | Pas | `#4A7A0E` | `#A3E635` | lime |
| `metric.spo2` | SpO2 | `#2F5FD0` | `#7AA7FF` | bleu |
| `metric.temp` | Température | `#9E5200` | `#FFA347` | ambre-orangé |
| `metric.battery` | Batterie bracelet | = `state.*(niveau)` sous seuil, sinon `state.neutral` | idem | métrique d'état, conforme à DESIGN.md:35-36 |

Rampe des zones FC (Z0 → Z5, à valider) : gris `#8E8E93`, puis `metric.spo2`, `metric.hrv`,
`state.good` sombre `#34D17A`, `metric.energy`, `metric.cardio`. Elle remplace la rampe monochrome
`.primary` 0.15 → 0.82 + Z5 `Pop.red` (HeartRateZone.swift:22-30, audit §2.1). Point à vérifier :
Z4 et `state.poor` ne doivent jamais apparaître ensemble sans libellé.

Compromis assumé : 9 teintes de métrique + 3 états dépassent ce qu'un œil distingue sans aide.
Énergie/température (orange) et état faible/moyen (rouge/ambre) sont proches. La parade est la règle
§4 : un état est toujours accompagné d'un mot ou d'un symbole, une teinte de métrique toujours d'une
icône de métrique. On ne compte jamais sur la teinte seule pour dire « quelle métrique » ni « quel état ».

### 2.4 Source unique : forme de l'API (à valider)

```swift
enum Metric { case recovery, strain, sleep, cardio, hrv, stress, energy, steps, spo2, temp, battery }
enum HealthState { case good, fair, poor, neutral }

extension Metric {
    var tint: Color { … }                    // couleur de la métrique (§2.3)
    var symbol: String { … }                 // SF Symbol unique de la métrique
    func state(for value: Double) -> HealthState  // seuils uniques (ex. récup 67/34, audit §2.1)
    func color(for value: Double?) -> Color  // tint, ou state.color pour recovery/battery
}
```

`stressColor` (TodayWidgetStack.swift:138-143), `TodayRingModel.recoveryColor` (:25-29) et la
couleur de `FocusWidget` (:62) disparaissent au profit de cette API (audit §5.2). Le widget WidgetKit
reçoit la métrique et la valeur dans le snapshot, pas un hex (LoopWidgetSnapshotStore.swift:19-21).

### 2.5 Mesures (à valider)

| Token | Valeur |
|---|---|
| `radius.card` | 26 pt (valeur actuelle conservée, LoopGlass.swift:11) |
| `radius.nested` | 18 pt |
| `radius.tile` | 22 pt (WorkoutMetricTile.swift:31) |
| `space.screen` | 16 pt partout (aujourd'hui 16 ou 20, audit §2.4) |
| `space.cardPadding` | 16 pt |
| `space.betweenCards` | 12 pt dans une grille, 20 pt entre sections |
| `bar.segmented.height` / gap | 8 pt / 2 pt |
| `bar.range.height` | 14 pt |
| `cursor.triangle` | 12 pt |
| `target.min` | 44 × 44 pt |

---

## 3. Typographie

SF Pro, chiffres en `.monospacedDigit()`. `design: .rounded` réservé aux chiffres héros et de tuile
(il est déjà utilisé ponctuellement, ProfileHeader.swift:34, audit §2.2). Tout passe par un enum
`LoopType` ; aucun `.font(.system(size:))` hors de cet enum.

| Rôle | Style | Graisse | Couleur | Remarque |
|---|---|---|---|---|
| Hero (score) | `@ScaledMetric(relativeTo: .largeTitle)` base 72 pt, `.rounded` | semibold | `text.primary` | remplace 78 fixe (RecoveryHero.swift:39) |
| Unité du hero | `@ScaledMetric(relativeTo: .title)` base 30 pt | medium | teinte métrique | ≈ 0,4 × hero, ligne de base commune |
| Mot d'état du hero | `.title3` | semibold | `state.*` | toujours un mot, jamais la couleur seule |
| Valeur de carte | `.largeTitle` (34) | semibold | `text.primary` | remplace 30 fixe (WidgetChrome.swift:50) |
| Valeur de tuile | `.title` (28) | semibold | `text.primary` | remplace 26 fixe (CompactMetricTile.swift:33) |
| Unité | `.title3` (20) avec une valeur de carte, `.headline` (17) avec une tuile | medium | teinte métrique | voir règle de contraste §8 |
| Titre de carte | `.headline` | semibold | `text.primary` | remplace 14 semibold secondaire (WidgetChrome.swift:23) |
| Titre de section / page | `.title2` | bold | `text.primary` | |
| Libellé | `.subheadline` | regular | `text.secondary` | |
| Corps / conseil | `.body` | regular | `text.secondary` sur `surface.nested` | |
| Légende, bornes d'axe | `.footnote` | regular | `text.secondary` | `text.tertiary` interdit pour une information (audit §6.1) |
| Sur-titre | `.caption` | semibold, capitales, tracking 0,6 | `text.secondary` | un seul par carte au maximum |

Aux tailles d'accessibilité (`dynamicTypeSize.isAccessibilitySize`), les grilles passent à une colonne,
comme le fait déjà WorkoutMetricsGrid.swift:8-11 (audit §6.2), et l'unité passe sous la valeur.

---

## 4. Règle de couleur

### 4.1 Où la couleur est autorisée

| Élément | Teinte de métrique | Couleur d'état |
|---|---|---|
| Icône SF de la métrique | oui | non |
| Unité accolée au chiffre | oui (si ≥ `.headline`) | non |
| Chiffre | **non** (toujours `text.primary`) | non |
| Barre, anneau, arc, segment actif | oui | oui si la barre exprime un état (segments bon/moyen/faible) |
| Courbe et aire sous courbe (≤ 25 % → 0 %) | oui | non (les points peuvent prendre l'état) |
| Pastille de légende | oui | oui |
| Mot d'état, badge de variation | non | oui, avec mot ou flèche |
| Fond de carte de données | **non** | **non** |
| Fond de carte imbriquée | non | non |
| Bouton d'action en verre | oui, via `.glassEffect(.regular.tint(…))` à faible opacité, un seul par écran | `state.poor` pour un destructif uniquement |
| Texte courant, titres | non | non |

Fond de carte teinté : refusé. Il dégrade le contraste des textes secondaires, entre en conflit avec la
règle « cartes jamais colorées » (LoopGlass.swift:3, audit §5.1) et rendrait les écrans multi-métriques
illisibles. La teinte de carte est remplacée par l'icône, l'unité et la barre.

### 4.2 Résolution du conflit avec « une seule teinte accent par page » (DESIGN.md:10)

Nouvelle règle proposée, en remplacement de DESIGN.md:10-14 :

> **Une teinte par métrique, une métrique par carte, un accent d'action par écran.**
> - Une carte n'affiche qu'une teinte de métrique (sa métrique) plus, si besoin, une couleur d'état.
> - Une page détail est dominée par la teinte de sa métrique ; les autres métriques n'y apparaissent qu'en icône ou en unité, dans les cartes de contributeurs.
> - L'accueil peut montrer plusieurs teintes, une par carte, jamais deux dans la même carte.
> - Un seul élément d'action teinté par écran (bouton flottant ou action primaire).
> - Les couleurs d'état restent réservées à l'évaluation (bon / moyen / faible) et à l'alerte réelle.

Ce qui est gardé de DESIGN.md : pas de couleur décorative, pas d'arc-en-ciel par ligne, alertes
colorées seulement quand c'est réel (DESIGN.md:13), une seule surface pour les faits secondaires.
Ce qui change : l'unité de la règle passe de la page à la carte, et la teinte devient une identité de
métrique stable au lieu d'un accent choisi par page.

Compromis : on perd le calme monochrome actuel et on gagne la lecture instantanée « quelle métrique,
quel état ». Le risque est le patchwork sur l'accueil ; il est borné par trois limites : chiffre
toujours en encre, aucune carte teintée, une teinte par carte. L'accent `.tint(.primary)` global
(MainTabView.swift:42, audit §7.1) est retiré : les contrôles prennent la teinte de la métrique de la
page, la tab bar garde l'encre du système Liquid Glass.

### 4.3 Alertes

Bracelet bloqué (DeviceView.swift:125-130) et erreur de sync (SyncToast.swift:29) passent en
`state.poor` avec symbole, conformément à DESIGN.md:13, ce qui corrige l'écart relevé (audit §5.2).

---

## 5. Liquid Glass

Cible : `project.yml:5` déclare iOS 27.0, DESIGN.md:19 dit 26.0 (audit §3). Les API iOS 26 sont
disponibles partout, sans `#available`. DESIGN.md:19 est à corriger.

### 5.1 En verre

| Élément | API | Remplace |
|---|---|---|
| Barre d'onglets | `TabView` avec `Tab(...)`, verre système, `.tabBarMinimizeBehavior(.onScrollDown)` conservé | `.tabItem` (MainTabView.swift:13-33) et le `UITabBarAppearance` + `UIBlurEffect(.systemUltraThinMaterial)` (MainTabView.swift:44-49), à supprimer |
| Statut de sync | `.tabViewBottomAccessory { … }` (capsule verre native) | `SyncToast` en haut d'écran (MainTabView.swift:35-37, SyncToast.swift:32) |
| Toolbar | `ToolbarItem` natifs ; `DateNavigator` sans `glassEffect` propre, les flèches en `Button` de toolbar ; `ToolbarSpacer` entre groupes | verre capsule de DateNavigator.swift:39 dans `.principal` (double verre possible, audit §3.3) |
| Bord de défilement | `.scrollEdgeEffectStyle(.soft, for: .top)` | `.toolbarBackground(.hidden)` seul (TodayView.swift:59) |
| Boutons d'action | `.buttonStyle(.glass)` ; l'action primaire unique en `.buttonStyle(.glassProminent)` teinté par la métrique de la page | `.glassEffect(.regular.interactive())` + `.pressable` cumulés (DeviceActions.swift:62, RecalcCard.swift:42, DeviceEmptyState.swift:61) et `.borderedProminent` (WorkoutRPEView.swift:138, OnboardingView.swift:158) |
| Bouton flottant (ex. « saisir l'effort » sur Séance) | `Button` + `.glassEffect(.regular.tint(metric.tint.opacity(0.35)).interactive(), in: .capsule)` | — (nouveau) |
| Sheets | fond verre par défaut d'iOS 26 (ne rien forcer) | `.presentationBackground(.thinMaterial)` (NoSensorSheet.swift:39, SensorDetectedSheet.swift:46) et lavis `LinearGradient` (NoSensorSheet.swift:139-148) |
| Capsules d'en-tête (avatar, date, filtre) | `.glassEffect(.regular, in: .capsule)` regroupées dans un `GlassEffectContainer` | avatar isolé (ProfileHeader.swift:37) |
| Sélecteur de période | `Picker(.segmented)` natif dans la toolbar ou en en-tête de carte | — |
| Live Activity | fonds système de la Live Activity, pas de matériau forcé | `.ultraThinMaterial` (BraceletBatteryLiveActivityWidget.swift:78,117) |

### 5.2 Opaque

- Toutes les cartes de données, tuiles, cartes de tendance, blocs de conseil, graphiques : `surface.card` / `surface.nested` + `stroke.card`. Remplace `loopGlass()` et `deviceSurface()` (LoopGlass.swift:14, DeviceSurface.swift:14, 49 appelants, audit §3.1) par un seul modifier `.loopCard(level:)`.
- Le héros des pages : posé sur `bg.base`, sans carte.

### 5.3 Règles

1. **Groupes** : tout ensemble d'au moins deux éléments en verre voisins (capsules d'en-tête, paire de boutons, actions de toolbar custom) est enveloppé dans `GlassEffectContainer(spacing: 12)`. Les transitions entre états d'un même contrôle utilisent `glassEffectID(_:in:)` avec un `@Namespace` (ex. bouton flottant qui se replie en icône au défilement).
2. **Interdit : verre sur verre.** Aucun `glassEffect` dans un parent en verre, aucune carte en verre dans une sheet en verre. Les 9 `loopGlass(cornerRadius: 14)` imbriqués (StrainWhyDisclosure.swift:29, SleepInsightDisclosure.swift:30, SleepStagesCard.swift:432, StrainLoadCard.swift:29, RecoveryWhyDisclosure.swift:30, HeartRateZonesCard.swift:56, HeartRateRestingTrendCard.swift:28, StressBalanceCard.swift:34, StressWhyDisclosure.swift:35) deviennent `surface.nested`.
3. **Interdit** : `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`, `UIBlurEffect`, `LoopGlassShell` (code mort, LoopGlassShell.swift:17-94), lavis en dégradé imitant le verre.
4. **Un seul retour au toucher** : `.interactive()` ou `Button` natif, jamais combiné à `.pressable` (PressableScale.swift:15, audit §3.3).
5. **Teinte du verre** : au plus un élément en verre teinté par écran (l'action primaire ou le bouton flottant).
6. `Glass.clear` : non utilisé (le contenu derrière la navigation est dense, `.regular` garde la lisibilité).

---

## 6. Composants cibles

États communs, définis une fois dans un `enum MetricLoadState { loading, calibrating(day: Int, of: Int), absent, partial(reason), contradictory(reason), ready }`
(modèle déjà présent dans TrainingAdviceWidget.swift:144, audit §4).

| État | Règle d'affichage générale |
|---|---|
| chargement | gabarit final avec `.redacted(reason: .placeholder)`, pas de spinner, pas d'animation si Reduce Motion |
| calibration | valeur remplacée par « Calibrage j/n », couleur `state.neutral`, barre en `track.empty` |
| données absentes | dans une grille : widget masqué ; dans un héros ou une page détail : `ContentUnavailableView` court |
| partiel | valeur affichée + mention « partiel » en `.footnote` et symbole `circle.lefthalf.filled` ; pas de couleur d'état |
| contradictoire | valeur affichée en `state.neutral`, symbole `exclamationmark.circle`, une phrase qui nomme les deux signaux |

| # | Composant | Contenu | Règles propres |
|---|---|---|---|
| 1 | `ScoreHero` | anneau ou arc teinté, chiffre hero, unité, mot d'état, sous-ligne de contexte | un par écran ; posé sur le fond ; arc en `metric.color(for:)` ; zone cible en `track.empty` renforcé ; calibration = arc pointillé neutre |
| 2 | `MetricTile` | icône teintée, libellé, valeur de tuile + unité teintée, badge optionnel | demi-largeur, grille 2 colonnes ; tappable (`Button`, rôle bouton annoncé) ; absent = masquée |
| 3 | `MetricCard` | ligne 1 icône + titre + chevron ; ligne 2 valeur + unité + badge + mot d'état ; ligne 3 barre | une métrique par carte ; partiel = barre en pointillés |
| 4 | `TrendCard` | titre, `PeriodPicker`, barres ou courbe 7/14/30 j, colonne du jour en `surface.highlight` | jour sans donnée = tiret `track.empty`, jamais 0 ; moins de 3 jours = carte masquée |
| 5 | `SegmentedCursorBar` | 4 à 6 segments `track.empty`, segment actif coloré, curseur triangle `text.primary` | bornes en `.footnote` ; état contradictoire = curseur sans segment coloré ; VoiceOver lit « valeur, segment n sur m » |
| 6 | `DeltaBadge` | capsule, flèche diagonale + delta signé | fond = couleur d'état à 14 % (clair) / 20 % (sombre), texte en couleur d'état ; sens favorable défini par la métrique dans `Metric` ; delta nul = `state.neutral` ; jamais sans flèche |
| 7 | `AdviceBlock` | sur-titre, 1-2 phrases, action optionnelle | `surface.nested`, placé sous le héros ; texte `text.secondary` `.body` ; contradictoire = les deux phrases, aucune couleur d'état |
| 8 | `DynamicWidget` | conteneur de la grille d'un écran : `id`, `priority`, `isAvailable`, contenu (#2, #3, #4 ou #7) | `isAvailable == false` → non rendu ; ordre déterministe (§7.0) ; pas de réordonnancement animé pendant la lecture |
| 9 | `PeriodPicker` | 7 / 14 / 30 j | `Picker(.segmented)` natif ; persistance par écran |
| 10 | `PageHeader` | titre `.title2`, sous-titre de date, capsules d'action en verre | capsules dans un `GlassEffectContainer` ; titre sur `bg.base` uni (corrige ≈1,4:1, audit §6.1) |

Composants supprimés : `LoopGlassShell`, `TodayGreetingHeader`, `HealthDayWidget`, `glowColor`
(audit §7.6). `LoopGlass` et `DeviceSurface` fusionnent dans `.loopCard(level:)`.

---

## 7. Hiérarchie des écrans

### 7.0 Règle de classement des widgets

Ordre = rang de base fixe par écran, avec deux promotions seulement :
1. une **alerte réelle** (`state.poor` sur batterie, bracelet bloqué, surcharge) monte en tête de grille ;
2. une **action attendue** (effort ressenti non saisi, séance à confirmer) monte juste après les alertes.

Tout widget sans donnée est masqué. Pas de score d'utilité calculé en continu : l'ordre doit rester
stable d'un jour à l'autre pour que la mémoire visuelle fonctionne.

### 7.1 Strain (StrainDetailView)

Existant vérifié hors audit : `StrainHero`, `StrainTargetCard`, `StrainWhyDisclosure`,
`StrainFactsGroup`, `StrainLoadCard`, `StrainManageCard`, `StrainWorkoutsSection`
(StrainDetailView.swift:32-39), empilés à 22 pt.

Héros : score de strain du jour, arc `metric.strain`, zone cible marquée, mot de band.

| Rang | Widget candidat | Composant | Masqué si |
|---|---|---|---|
| 1 | Conseil de charge (aujourd'hui `StrainManageCard` / `TrainingInsightsCard`) | AdviceBlock | aucun conseil |
| 2 | Cible du jour : position dans la zone | SegmentedCursorBar | cible non calculée |
| 3 | Séances du jour | liste de MetricCard compactes | aucune séance |
| 4 | Charge aiguë / chronique | TrendCard | moins de 7 jours |
| 5 | Temps par zone FC cumulé du jour | MetricCard + barre de zones | pas de FC |
| 6 | Contributeurs (énergie, pas, FC moyenne) | 2-3 MetricTile | pas de mesure |
| 7 | Pourquoi ce score | disclosure sur `surface.nested` | — |
| 8 | Tendance 7/14/30 j | TrendCard | moins de 3 jours |

### 7.2 Séance (WorkoutDetailView)

Existant vérifié hors audit : `WorkoutDetailHeader`, `WorkoutMetricsGrid`, `WorkoutEffortCard`,
`WorkoutHeartRateZonesCard`, `WorkoutHeartRateCurve`, `WorkoutSourcesCard`
(WorkoutDetailView.swift:29-35) ; grille déjà masquée si vide (WorkoutMetricsGrid.swift:15).

Héros : strain de la séance (`metric.strain`), sous-ligne type de séance + durée. Si la séance n'a pas
de strain calculable : durée en héros, `state.neutral`.

| Rang | Widget candidat | Composant | Masqué si |
|---|---|---|---|
| 1 | Effort ressenti à saisir ou saisi | MetricCard + bouton flottant en verre teinté | séance rejetée |
| 2 | Mesures clés (durée, distance, allure, énergie) | grille de MetricTile | aucune mesure |
| 3 | FC moyenne / max | 2 MetricTile `metric.cardio` | pas de FC |
| 4 | Zones FC | barre de répartition + lignes sur `surface.nested` | pas de FC |
| 5 | Courbe FC | carte courbe `metric.cardio`, ligne de moyenne pointillée | moins de N points |
| 6 | Tracé | carte plein cadre | pas de tracé |
| 7 | Conseil de récupération après séance | AdviceBlock | aucun conseil |
| 8 | Sources | ligne repliée | — |

### 7.3 Accueil (TodayView)

Existant : trois anneaux comme seul foyer de couleur (TodayView.swift:6-8), puis la pile de widgets
`DeviceAlertWidget`, `AlarmWidget`, `FocusWidget`, `StrainTargetWidget`, `TimelineWidget`, tuiles
Cardio/Stress (TodayWidgetStack.swift:70-112, vérifié hors audit).

Héros proposé : **score de récupération** (`metric.recovery` = état), avec sommeil et strain en deux
indicateurs compacts sous le chiffre (ou les trois anneaux conservés : décision Q4).

| Rang | Widget candidat | Composant | Masqué si |
|---|---|---|---|
| promu | Alerte bracelet (batterie faible, bloqué) | MetricCard `state.poor` | aucune alerte |
| 1 | Conseil du jour (`FocusWidget`) | AdviceBlock | pas de données |
| 2 | Sommeil de la nuit | MetricCard `metric.sleep` + barre de phases légendée | pas de nuit |
| 3 | Strain et cible | MetricCard `metric.strain` + SegmentedCursorBar | pas de cible |
| 4 | Conseil d'entraînement (`TrainingAdviceWidget`) | AdviceBlock | état `absent` |
| 5 | VFC / FC repos | 2 MetricTile + DeltaBadge | pas de mesure |
| 6 | Stress | MetricTile `metric.stress`, état par `state.*` | pas de mesure |
| 7 | SpO2 / température | 2 MetricTile | pas de mesure |
| 8 | Chronologie du jour | carte liste | vide |
| 9 | Réveil | ligne compacte | réveil désactivé |

---

## 8. Accessibilité

### 8.1 Contrastes calculés (WCAG 2.x, fonds opaques)

| Texte | Fond | Clair | Sombre | Verdict |
|---|---|---|---|---|
| `text.primary` | `surface.card` | 19,7:1 | 17,4:1 | AA |
| `text.secondary` | `surface.card` | 6,4:1 | 7,2:1 | AA texte normal |
| `text.secondary` | `surface.nested` | 5,8:1 | 5,9:1 | AA texte normal |
| `text.secondary` | `bg.base` | 5,8:1 | 8,7:1 | AA |
| `text.tertiary` | `surface.card` | 3,4:1 | 4,2:1 | **insuffisant** : décoratif seulement |
| `state.good` | `surface.card` | 5,4:1 | 8,7:1 | AA |
| `state.fair` | `surface.card` | 5,5:1 | 10,8:1 | AA |
| `state.poor` | `surface.card` | 5,4:1 | 5,7:1 | AA |
| `state.poor` | `surface.nested` | 4,8:1 | 4,7:1 | AA |
| teintes de métrique (toutes) | `surface.card` | 5,1 à 6,5:1 | 5,2 à 11,5:1 | AA |
| `metric.cardio` / `metric.sleep` | `surface.nested` sombre | — | 4,2 / 4,4:1 | AA grand texte et graphique seulement |

Règles qui en découlent :
- Unité colorée autorisée en `.headline` et plus. En dessous, l'unité passe en `text.secondary`.
- `text.tertiary` n'est jamais porteur d'information. Les 6 usages relevés (CompactMetricTile.swift:45, WidgetChrome.swift:31, DeviceView.swift:104, SleepWidget.swift:21, RecoveryHero.swift:14, ProfileView.swift:59,83 ; audit §6.1) passent en `text.secondary`.
- Pas de texte blanc sur une couleur d'état claire (cas des jours d'Alarm, 1,86:1, AlarmView.swift:150,155) : texte `text.primary` inversé ou fond `state.*` à 20 %.
- Le fond uni `bg.base` supprime le cas noir sur `#0B1F6B` à ≈1,4:1 (AppBackground.swift:9, audit §6.1).
- Graphiques (barres, segments, courbes) : ≥ 3:1 contre leur fond, vérifié pour toutes les teintes du §2.3.

### 8.2 Reduce Transparency

Le verre natif gère le réglage (comportement Apple, à vérifier en simulateur). Comme aucune carte de
données n'est en verre (§5.2), le contenu n'en dépend pas. Les matériaux forcés qui échappaient au
réglage (sheets, tab bar, audit §6.3) sont supprimés. Aucun code custom ne lit
`accessibilityReduceTransparency`, sauf pour le bouton flottant teinté : en Reduce Transparency, teinte
remplacée par `surface.nested` + filet.

### 8.3 Reduce Motion

Lire `accessibilityReduceMotion` dans un modifier unique `.staggeredEntrance(index:)` qui remplace les
entrées décalées (TodayWidgetStack.swift:47, DeviceView.swift:89, RecoveryDetailView.swift:58-62) et
coupe les `symbolEffect(.pulse)` (DeviceAlertWidget.swift:15, RecoveryHero.swift:21,
DeviceBatteryCard.swift:24) ; audit §6.3.

### 8.4 Dynamic Type

Zéro `.font(.system(size:))` hors `LoopType` (§3). Test aux tailles `.xSmall`, `.large`, `.accessibility3`.
Cibles tactiles ≥ 44 pt : flèches de DateNavigator (34 pt, DateNavigator.swift:64), jours d'Alarm
(38 pt, AlarmView.swift:156), actions texte de Device (DeviceActions.swift:18-23). `.pressable`
(DragGesture, PressableScale.swift:18-31) remplacé par `Button` + `ButtonStyle` pour que VoiceOver
annonce le rôle (audit §6.4).

### 8.5 Clair / sombre

Les deux modes, suivis du système, tous les tokens en paire. Aucun `preferredColorScheme` forcé.

### 8.6 La couleur n'est jamais le seul indicateur

- Tout état = couleur + mot ou symbole (§2.2).
- Tout badge = couleur + flèche + signe.
- Toute barre multi-couleur (phases de sommeil, zones FC) = légende textuelle ou libellés dans les segments ; corrige la barre de phases sans légende (SleepWidget.swift:50-59, audit §6.3).
- Avec `accessibilityDifferentiateWithoutColor`, les segments de barre ajoutent un motif (hachure) et les points de courbe une forme par état.

---

## 9. Plan de migration

| Étape | Contenu | Vérification |
|---|---|---|
| 1. Tokens centralisés | Catalogue `Metric` / `HealthState` / `LoopType` / mesures (§2, §3) dans une cible partagée app + widgets. Toutes les couleurs actuelles redirigées vers les tokens sans changer les écrans. Suppression du code mort (§6). | `grep` : 0 hex ou `Color(red:` hors du catalogue, 0 `Pop.`, 0 `.font(.system(size:` hors `LoopType` ; tests unitaires des seuils (récup 67/34, sommeil, batterie) ; widget Recovery coloré selon le score |
| 2. Liquid Glass sur la navigation | Tab bar `Tab(...)` sans `UITabBarAppearance` ; `tabViewBottomAccessory` pour la sync ; toolbar native et DateNavigator sans verre propre ; sheets sans `presentationBackground` ; boutons en `.glass` / `.glassProminent` ; `GlassEffectContainer` sur les groupes. | `grep` : 0 `UIBlurEffect`, 0 `Material`, 0 `.pressable` combiné à `.interactive()` ; captures simulateur clair/sombre de chaque onglet et des deux sheets Bluetooth ; Reduce Transparency activé |
| 3. Composants | `.loopCard(level:)` opaque remplace `loopGlass`/`deviceSurface` ; les 10 composants du §6 avec leurs 6 états, chacun avec `#Preview` par état. | `grep` : 0 `glassEffect` dans une carte de données ; previews des 6 états × 2 modes × 2 tailles de texte ; audit VoiceOver des rôles bouton |
| 4. Écrans | Strain, Séance, Accueil recomposés selon §7 (héros + `DynamicWidget`) ; puis les autres détails (Récup, Sommeil, Stress, Cardio), Device, Profil. DESIGN.md réécrit avec la règle §4.2. | captures avant/après par écran ; scénarios de données : complet, calibrage, aucune donnée, partiel, contradictoire ; contrôle des contrastes sur captures |

---

## 10. Décisions à trancher

**Q1. Remplacer « une seule teinte accent par page » (DESIGN.md:10) par « une teinte par métrique, une métrique par carte, un accent d'action par écran » ? (oui / non)**
Recommandation : **oui**. Sans cela, la demande de couleurs qui soulignent l'information est impossible à satisfaire sur l'accueil, et la règle actuelle n'a de toute façon pas d'effet visible (tint neutralisé, MainTabView.swift:42, audit §7.1).

**Q2. Cartes de données opaques, verre réservé à la navigation, aux actions et aux sheets ? (oui / non)**
Recommandation : **oui**. Le verre sur 49 cartes ne laisse rien voir derrière (fond gris uni) et produit l'effet neutre (audit §1.10) ; des cartes opaques donnent un contraste maîtrisé et suppriment les 9 cas de verre sur verre. Le « Liquid Glass maximisé » se joue sur les vrais composants iOS 26 (tab bar, accessoire, toolbar, boutons, sheets), pas sur les cartes.

**Q3. Abandonner le dégradé bleu nuit `AppBackground` au profit d'un fond uni `bg.base` ? (oui / non)**
Recommandation : **oui**. Il produit un contraste de ≈1,4:1 sous le titre en mode clair (AppBackground.swift:9, audit §6.1) et entre en concurrence avec les teintes de métriques. Un fond uni rend la couleur aux données.

**Q4. Accueil : un héros unique (récupération) avec sommeil et strain en indicateurs compacts, plutôt que les trois anneaux actuels ? (héros unique / trois anneaux)**
Recommandation : **héros unique**. C'est la hiérarchie demandée (« un gros score en haut ») ; sommeil et strain gardent leur place en rangs 2 et 3 de la grille. Coût : on perd la signature visuelle des trois anneaux (TodayView.swift:6-8).

**Q5. Récupération colorée par son état (vert / ambre / rouge) plutôt que par une teinte fixe ? (état / teinte fixe)**
Recommandation : **état**. Le score de récupération est une évaluation ; une teinte fixe recréerait le bug du widget vert à 10 % (MainTabView.swift:109, audit §5.2). Même logique pour la batterie. Les autres métriques gardent une teinte fixe et expriment leur état par mot, badge ou segment.
