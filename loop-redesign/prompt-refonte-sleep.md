# Prompt — Refonte profonde de la page Sleep

> Prompt à donner à un agent IA pour refondre la page Sleep de Loop. Pas une conversion cosmétique : une refonte UX/UI complète alignée sur `DESIGN.md`, avec progressive disclosure, micro-animations premium, barres à la WHOOP, et une hiérarchie reposant sur un héros + une métrique mise en avant + faits secondaires regroupés.

---

## PROMPT

Tu vas **refondre profondément** la page Sleep de l'app iOS Loop (Swift/SwiftUI, iOS 26+, Liquid Glass natif, offline-first, WHOOP 4.0). Ce n'est pas une conversion de l'existant vers le nouveau design system — c'est une **refonte UX/UI** qui re-pense la hiérarchie de l'information, le mouvement, et la densité.

### Avant de commencer

Charge **tous** les skills SwiftUI disponibles dans `.agents/skills/` :
- `swift-ui` — patterns SwiftUI
- `swiftui-expert-skill` — state management, `@Observable`, performance, Instruments
- `swiftui-ui-patterns` — navigation, custom modifiers, layouts
- `swiftui-microinteractions` — spring physics, CoreHaptics, glass morphism, SF Symbols 7 draw animations
- `swiftui-liquid-glass` — Liquid Glass API iOS 26+
- `swift-concurrency-expert` — `@MainActor`, `Sendable`, async/await
- `impeccable` — UX review, visual hierarchy, cognitive load, motion
- `motion-choreography` — animation sequences, loading states, motion-sensitive users

### Lecture obligatoire avant tout code

1. **`/Users/theo/dev/whoop/loop/DESIGN.md`** — le langage visuel de Loop. La page Device (`Loop/Features/Device/`) en est l'implémentation de référence ; la page Sleep actuelle **ne le suit pas** (gradient backdrop coloré, 4 palettes par score, hero sans glass, multi-cards répétitives, couleurs par état). C'est ce que tu vas corriger.
2. **`/Users/theo/dev/whoop/loop/Loop/Features/Device/`** en entier — la page de référence. Étudie :
   - `DeviceSurface.swift` (`.deviceSurface(cornerRadius:)` = `glassEffect(.regular)`, un seul modifier, pas de fallback)
   - `PressableScale.swift` (`.pressable { ... }` = shrink + haptic léger à la down-edge, lift-inside-to-fire)
   - `DeviceHero.swift` (hero sans card : image flottante sur backlight radial + grand titre + une ligne de statut avec un seul point accent)
   - `DeviceBatteryCard.swift` (l'UNE métrique mise en avant : label + grand chiffre + barre fine monochrome, couleur uniquement si bas)
   - `DeviceInfoGroup.swift` (faits secondaires regroupés dans UNE seule surface, pas N cards)
   - `DeviceDetailsRow.swift` (disclosure progressive : une ligne sobre qui pousse vers la couche technique)
   - `DeviceView.swift` (composition globale : hero → métrique mise en avant → note conditionnelle → faits groupés → action → disclosure → footer)

### Diagnostic de l'existant (à corriger)

`Loop/Features/Today/Detail/SleepDetailView.swift` + `Sleep/Components/*` + `SleepCoachModel.swift` :

| Problème | Détail | Conflit avec DESIGN.md |
|---|---|---|
| **Backdrop dégradé coloré** | `SleepGradientBackdrop` avec 4 palettes par score (vert/cyan/purple/orange/red), `RadialGradient` glow, shadow gradient | "Monochrome d'abord", "profondeur vient de la réfraction du verre, pas de la peinture" |
| **Hero sans glass, hors langage** | `SleepCoachHeroCard` flottant sans surface, label "Sommeil" avec gradient violet, 4 tuiles `SleepHeroMetric` avec points colorés vert/orange par état | "Une seule teinte accent par page", "Teintes warning uniquement quand réellement bas" |
| **5 cards empilées** | Hero / Ribbon / StageBalance / Insight / TonightPlan — cards répétitives identiques en rythme | "Hiérarchie forte : un héros, une métrique mise en avant, faits secondaires regroupés dans une seule surface", "Cards répétitives identiques" = anti-pattern |
| **Pas de progressive disclosure** | Tout est déplié d'un coup. Ribbon chart 232pt = la moitié de l'écran dès le premier scroll | "Détail technique replié derrière une ligne (disclosure progressive)" |
| **Pas de micro-interactions** | Aucun haptic, aucun press, entrée sans stagger, pas de symbol effect | "Micro-interactions premium (haptique au press, entrée staggered, symbol effects)" |
| **Couleurs par état partout** | `accent` violet/cyan/vert/orange/rouge selon score, drivers colorés individuellement, stages avec 4 couleurs distinctes (orange/bleu/teal/violet) | "Une seule teinte accent par page", "Pas d'arc-en-ciel" |
| **Plan de ce soir avec heure hardcodée** | `wakeText = "07:00"` fixe, `bedtimeText` calculé contre 07:00 | Utilise `UserPreferences.wakeDateToday` à la place |
| **Pas d'in-sleep signals** | `SleepSession.efficiency` / `restingHr` / `avgHrv` disponibles, jamais rendus | Voir `03-donnees-manquantes.md` A1-1/2/3 |
| **Pas de sleep debt / needed** | Données en cache, pas rendues | Voir `03-donnees-manquantes.md` A2-7 |

### Vision produit — la nouvelle page Sleep

**Rôle de la page** : répondre à 3 questions dans l'ordre, avec la densité la plus faible possible :
1. **Comment s'est passée ma nuit ?** (en 2 secondes)
2. **Pourquoi ce score ?** (au scroll, progressivement)
3. **Qu'est-ce que je fais ce soir ?** (en bas, prescriptif)

**Hierarchie visuelle cible** (de haut en bas) :

```
┌─────────────────────────────────────────────────────────┐
│ HERO (sans card, sur fond verre natif full-bleed)        │
│  • label "SOMMEIL" (overline monochrome, pas de gradient)│
│  • score en très grand (78pt), encre, monospacedDigit    │
│  • qualityLabel "Bon" en sous-titre                      │
│  • headline une ligne ("Bonne base, un levier à corriger")│
│  • un seul point accent = couleur du band (green/yellow/ │
│    red) — porté par le score, jamais par le décor        │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ MÉTRIQUE MISE EN AVANT (1 surface verre)                 │
│  • "Durée" label + grand chiffre "7h 30m" + unité        │
│  • BARRE À LA WHOOP : track fin monochrome + fill encre, │
│    marqueur "objectif 8h 00m" (tick vertical), animation  │
│    spring à l'apparition, contentTransition numericText  │
│  • caption "−30m vs objectif" (teinte warning SEULEMENT  │
│    si gap > 45min, sinon secondaire)                     │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ CARTE DE LA NUIT (1 surface verre, PProgressiveDisclosure)│
│  • Header tappable : "Carte de la nuit" + range + chevron│
│  • COLLAPSED : mini-hypnogramme compact (60pt de haut),  │
│    4 lanes Éveil/REM/Léger/Profond, barres monochromes   │
│    (différenciées par POSITION de ligne, pas par couleur)│
│  • EXPANDED (au tap, haptic light + spring) : hypnogramme│
│    complet 232pt avec cursor draggable, axis horaire,    │
│    détail du segment sous le doigt (cf. ribbon actuel)   │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ FAITS SECONDAIRES (UNE SEULE surface verre, groupés)     │
│  • rows : Profond / REM / Léger / Éveil / Efficacité /   │
│    FC repos / HRV / Réveils                              │
│  • chaque row = label à gauche + valeur monospaced à     │
│    droite + mini-barre horizontale OPTIONNELLE (seulement│
│    pour Profond/REM/Léger = % du total)                  │
│  • PAS de couleur par row — monochrome, valeur en encre  │
│  • hr/restingHr/avgHrv depuis SleepSession (nouveau,     │
│    A1-1/2/3 du doc 03)                                   │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ POURQUOI CE SCORE (disclosure progressive, fermé par def)│
│  • Header tappable : "Pourquoi ce score" + chevron       │
│  • COLLAPSED : une ligne driver dominante ("Durée: −30m  │
│    vs objectif") + count badge "+2"                      │
│  • EXPANDED : les 3 drivers (durée/efficacité/continuité)│
│    en rows, chacun avec mini-barre fill (monochrome),    │
│    message secondaire, plus un encart "ce que ça veut     │
│    dire" en prose                                        │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ PLAN DE CE SOIR (1 surface verre, prescriptif)           │
│  • 2 tuiles : "Au lit à" / "Réveil à" (heure réelle      │
│    depuis sleepStart/sleepEnd si dispo, fallback UserPref)│
│  • sleep debt cumulé (7j) en caption                     │
│  • sleep needed ce soir en caption                       │
│  • message coach en prose, accent = band color           │
└─────────────────────────────────────────────────────────┘
```

### Spécification détaillée par section

#### 0. Backdrop — passer au langage Device

**Supprimer** `SleepGradientBackdrop` + `SleepGradientPalette` + les 4 palettes par score.

**Remplacer par** : `Color(.systemGroupedBackground).ignoresSafeArea()` (comme la page Device). La profondeur vient des surfaces `glassEffect` par-dessus, pas d'un gradient peint.

L'**accent unique** de la page = `SleepBand` (green/yellow/red selon score, réutilise `RecoveryBand` existant dans `RecoveryCoachModel.swift` ou crée un `SleepBand` similaire). Porté par :
- un fin anneau ou point à côté du score dans le hero
- la barre "Durée" si gap > 45min (warning)
- le message coach en bas

Pas d'accent sur les rows, les drivers, les stages. **Monochrome.**

#### 1. Hero — `SleepHero` (sans card)

Remplace `SleepCoachHeroCard`. Flottant, pas de surface glass.

- Label overline "SOMMEIL" en `Font.system(size: 12, weight: .semibold)` + tracking 1.4 + `.tertiary` (comme `SleepSectionHeader` mais sans icône ni gradient)
- **Score** en très grand : `Font.system(size: 78, weight: .semibold)` + `.monospacedDigit()` + `.contentTransition(.numericText())` + encre `.primary`. Animation spring 0.6 au changement.
- **QualityLabel** ("Bon" / "Excellent" / "Correct" / "À améliorer") en `Font.system(size: 17, weight: .medium)` + `.secondary`
- **Headline** une ligne, `Font.system(size: 15, weight: .regular)` + `.secondary`, `lineLimit(2)` + `fixedSize(vertical)`
- **Un seul point accent** : `Circle().fill(band.color).frame(width: 8, height: 8)` à gauche du score, avec `symbolEffect(.pulse, isActive: score < 55)` pour un pulse subtil quand le score est bas (warning)
- Pas de grille 4 tuiles (supprimée — la durée devient la métrique mise en avant ci-dessous, les autres vont dans les faits secondaires)
- Entrée staggered : opacity 0→1 + offset y 14→0, cascade 0.06s par élément, spring 0.5/0.85

#### 2. Métrique mise en avant — `SleepDurationCard` (1 surface verre)

Remplace la 1ère tuile du hero + le gap de la grille. La durée est la métrique dominante car c'est le levier #1 du score.

- `WidgetLabel(symbol: "clock.fill", title: "Durée", trailing: sleepNeedText)` (style Today widget, ou recréer local)
- `WidgetMetric(value: "7h 30m", unit: nil)` — `Font.system(size: 30, weight: .semibold)` + `.contentTransition(.numericText())`
- **BARRE À LA WHOOP** :
  - Track : `Capsule().fill(.primary.opacity(0.08))` hauteur 6pt
  - Fill : `Capsule().fill(band.color)` largeur = `totalSleep / sleepTarget` clamped 0…1.5 (peut dépasser 1 si sur-sommeil). Si `gap > 45min` → fill en `Color.orange` (warning). Sinon encre `.primary.opacity(0.8)`.
  - **Marqueur objectif** : `Rectangle().fill(.primary.opacity(0.3))` largeur 1.5pt positionnée à `sleepTarget / max(sleepTarget, totalSleep)` — tick vertical qui marque "100% objectif"
  - Animation à l'apparition : `width: 0 → target` spring 0.6/0.85, démarrée au `onAppear` avec `appeared` state
  - `contentTransition(.numericText())` sur le chiffre quand le jour change
- Caption sous la barre : `"−30m vs objectif"` en `.secondary`, ou `"+15m vs objectif"` en `.tertiary` si positif. Teinte `.orange` uniquement si gap > 45min.
- Surface : `.deviceSurface(cornerRadius: 26)` (réutilise le modifier Device — c'est le même langage)

#### 3. Carte de la nuit — `SleepStagesCard` (progressive disclosure)

Remplace `SleepRibbonCard` + `SleepStageBalanceCard` (fusion).

**Comportement expand/collapse** :
- `@State private var isExpanded = false`
- Header tappable avec `.pressable { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { isExpanded.toggle() }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }`
- Header : `WidgetLabel(symbol: "waveform.path.ecg", title: "Carte de la nuit", trailing: model.ribbonTimeRange)` + `Image(systemName: "chevron.down").rotationEffect(.degrees(isExpanded ? 180 : 0))`
- **COLLAPSED** : mini-hypnogramme compact 60pt de haut, 4 lanes, barres monochromes (remplir avec `.primary.opacity(0.7)` — les stages se différencient par leur **position verticale**, pas par couleur). Légende en row compact sous le mini.
- **EXPANDED** : hypnogramme complet 232pt (reprend la logique du `SleepStageRibbonChart` actuel mais en **monochrome** — `SleepStage.color` devient des nuances de `.primary` : awake = `.primary.opacity(0.4)`, rem = `.primary.opacity(0.6)`, light = `.primary.opacity(0.8)`, deep = `.primary`). Cursor draggable conservé. Détail segment dans une mini-card `.loopGlass(cornerRadius: 14)` (déjà fait).
- Transition : `.transition(.opacity.combined(with: .move(edge: .top)))` sur l'expansion

**Sous l'hypnogramme (expanded only)** : 3 mini-barres horizontales Profond/REM/Léger (% du total) — reprend `SleepStageProgressRow` mais en monochrome (`.primary` fill au lieu de `row.stage.color`).

#### 4. Faits secondaires — `SleepFactsGroup` (UNE surface, groupés)

Remplace la grille 4 tuiles du hero + `SleepStageBalanceCard` (partie balance).

**UNE seule surface** `.deviceSurface()` contenant des rows séparées par `Divider().padding(.leading, 16)` :

| Row | Label | Valeur | Source |
|---|---|---|---|
| Profond | "Profond" | "1h 30m" + mini-barre % | `metric.deepMin` |
| REM | "REM" | "2h 00m" + mini-barre % | `metric.remMin` |
| Léger | "Léger" | "4h 00m" + mini-barre % | `metric.lightMin` |
| Éveil | "Éveil" | "12 min" | `disturbances` ou calcul depuis hypnogramme |
| Efficacité | "Efficacité" | "92%" | `metric.efficiency` |
| FC repos | "FC repos" | "52 bpm" | `session.restingHr` (NOUVEAU — A1-2) |
| HRV | "HRV" | "68 ms" | `session.avgHrv` (NOUVEAU — A1-3) |
| Latence | "Latence" | "8 min" | calcul depuis sleepStart vs premier segment deep (si dispo) |

Format row : `HStack { Text(label).font(14, .medium).secondary ; Spacer ; Text(value).font(15, .semibold).primary.monospacedDigit }` + mini-barre optionnelle (6pt hauteur) sous la row pour les stages.

**Pas de couleur par row.** Tout monochrome. Si une valeur est `nil` → afficher "—" en `.tertiary`.

#### 5. Pourquoi ce score — `SleepInsightDisclosure` (fermé par défaut)

Remplace `SleepInsightSection`.

- Header tappable avec `.pressable` + haptic
- **COLLAPSED** : une ligne "Pourquoi ce score" + driver dominant en trailing ("Durée: −30m" ou "Fragmentation: 7 réveils") + `chevron.down`
- **EXPANDED** : les 3 drivers en rows :
  - Row driver : `HStack { Image(systemName:).font(15).secondary ; VStack(title + message).secondary ; Spacer }` (reprend `SleepDriverRow` mais **sans cercle coloré** — icône en `.secondary` sans badge)
  - Mini-barre de contribution : sous chaque driver, une barre 4pt qui représente le poids du driver dans le score (estimation : duration = 50%, efficiency = 30%, disturbances = 20%). Fill en `.primary.opacity(0.6)`, track en `.primary.opacity(0.08)`.
  - Encart final "Ce que ça veut dire" en prose `.secondary` dans une inset `.loopGlass(cornerRadius: 14)`
- Transition spring + opacity

#### 6. Plan de ce soir — `SleepTonightPlan` (1 surface, prescriptif)

Remplace `SleepTonightPlanSection`.

- Header : `WidgetLabel(symbol: "moon.zzz.fill", title: "Plan de ce soir")`
- 2 tuiles : "Au lit à" / "Réveil à" — **heures réelles** depuis `metric.sleepStart` / `metric.sleepEnd` si dispo, sinon fallback `UserPreferences.wakeDateToday` (remplace le "07:00" hardcodé — cf. `SleepCoachModel.bedtimeText`/`wakeText`)
- **Sleep debt cumulé** (7j) en caption : calcul `Σ(sleepTargetMin - totalSleepMin)` sur les 7 derniers jours de `cache.daily`. Afficher "Dette : −1h 20" en `.tertiary`, ou "À jour" en `.tertiary` si debt ≤ 0
- **Sleep needed ce soir** en caption : `sleepTargetMin + max(0, debt/4)` (formule WHOOP-like). Afficher "Besoin : 8h 45"
- Message coach en prose, accent = `band.color` (le seul endroit avec l'accent couleur, pour signaler l'action prescriptive)
- Surface `.deviceSurface(cornerRadius: 26)`

### Modèle — `SleepCoachModel` (à étendre, pas recréer)

Étendre l'existant dans `Loop/Features/Today/Detail/Sleep/SleepCoachModel.swift` :

- Remplacer `accent: Color` (purple/cyan/...) par `band: SleepBand` (green/yellow/red/calibrating) — réutiliser `RecoveryBand` de `RecoveryCoachModel.swift` ou créer un `SleepBand(score:)` similaire
- `sleepStartText` / `sleepEndText` : déjà basés sur `ribbonSegments` — OK
- Ajouter `sleepDebt7d: Double` (calcul depuis `cache.daily` 7j glissants — nécessite passer l'historique au modèle, comme `RecoveryCoachModel(metric:history:)`)
- Ajouter `sleepNeededTonight: Double` = `sleepTargetMin + max(0, sleepDebt7d/4)`
- Ajouter `restingHrText: String?` depuis `session?.restingHr`
- Ajouter `avgHrvText: String?` depuis `session?.avgHrv`
- Ajouter `efficiencyText: String?` depuis `session?.efficiency` ou `metric.efficiency`
- Supprimer `estimatedHypnogram`/`estimatedRibbonSegments` si `realSegments` est nil → afficher un état "Hypnogramme non disponible" au lieu d'un fabricat. C'est plus honnête que le fabricat qui peut induire en erreur. (Si tu gardes le fabricat, le marquer visuellement "estimation" dans l'UI.)
- `bedtimeText` / `wakeText` : utiliser `UserPreferences.shared.wakeDateToday` au lieu de `Calendar.current.date(bySettingHour: 7, ...)` hardcodé

Signature init : `SleepCoachModel(metric: DailySnapshot, session: SleepSession?, history: [DailySnapshot] = [])` — pour le debt.

### SleepShells — nettoyer

`SleepShells.swift` :
- `SleepSection` + `SleepSectionHeader` → **supprimer** (remplacé par `WidgetLabel` style Today + `.pressable` sur les disclosures)
- `sleepCard()` modifier → **supprimer** (remplacé par `.deviceSurface(cornerRadius:)`)
- `SleepGlassShell` (si encore là) → **supprimer** (déjà fait par le prompt refactoring-p0 normalement)

### Fichiers à créer

- `Loop/Features/Today/Detail/Sleep/Components/SleepHero.swift` — hero sans card
- `Loop/Features/Today/Detail/Sleep/Components/SleepDurationCard.swift` — métrique mise en avant avec barre WHOOP
- `Loop/Features/Today/Detail/Sleep/Components/SleepStagesCard.swift` — hypnogramme progressive disclosure (fusion Ribbon + Balance)
- `Loop/Features/Today/Detail/Sleep/Components/SleepFactsGroup.swift` — faits secondaires groupés
- `Loop/Features/Today/Detail/Sleep/Components/SleepInsightDisclosure.swift` — drivers en disclosure
- `Loop/Features/Today/Detail/Sleep/Components/SleepTonightPlan.swift` — plan prescriptif (remplace l'ancien)
- `Loop/Features/Today/Detail/Sleep/SleepBand.swift` — enum band (green/yellow/red/calibrating) — ou réutiliser `RecoveryBand` si la sémantique match

### Fichiers à supprimer

- `Loop/Features/Today/Detail/Sleep/Components/SleepCoachHeroCard.swift`
- `Loop/Features/Today/Detail/Sleep/Components/SleepRibbonCard.swift` (la logique chart est reprise dans `SleepStagesCard`)
- `Loop/Features/Today/Detail/Sleep/Components/SleepStageBalanceCard.swift` (fusionnée dans `SleepStagesCard`)
- `Loop/Features/Today/Detail/Sleep/Components/SleepInsightSection.swift`
- `Loop/Features/Today/Detail/Sleep/Components/SleepTonightPlanSection.swift`
- `Loop/Features/Today/Detail/Sleep/Components/SleepShells.swift`

### Fichiers à modifier

- `Loop/Features/Today/Detail/SleepDetailView.swift` — remplacer le body par la nouvelle composition (hero → duration card → stages card → facts group → insight disclosure → tonight plan), supprimer `SleepGradientBackdrop` + `SleepGradientPalette`, fond `Color(.systemGroupedBackground)`, entrée staggered globale
- `Loop/Features/Today/Detail/Sleep/SleepCoachModel.swift` — étendre (band, debt, needed, restingHr, avgHrv, efficiency, real bedtime/wake), supprimer `accent` color, supprimer `estimatedHypnogram` (ou marquer estimation)
- `SleepStage` enum : rendre les couleurs monochromes (nuances de `.primary`), garder `title`/`rowIndex`

### Micro-animations exigées

| Endroit | Animation |
|---|---|
| Hero score au changement de jour | `.contentTransition(.numericText())` + spring 0.6/0.85 |
| Hero pulse accent si score < 55 | `symbolEffect(.pulse, isActive: score < 55)` sur le dot |
| Durée barre à l'apparition | `width: 0 → target` spring 0.6/0.85 avec `appeared` state |
| Durée chiffre au changement | `.contentTransition(.numericText())` |
| Stages card expand/collapse | `.pressable` (shrink 0.97 + haptic light) + `withAnimation(.spring(response: 0.4, dampingFraction: 0.85))` + chevron `rotationEffect` |
| Insight disclosure expand/collapse | idem |
| Entrée globale de la page | staggered cascade 0.05s par section, opacity + offset y, spring 0.5/0.85 |
| Tap sur n'importe quelle card tappable | `.pressable` (haptic + shrink) |
| Cursor hypnogramme (expanded) | `DragGesture` existant + `transition(.opacity)` sur la mini-card détail |

### Anti-patterns à bannir (rappel DESIGN.md)

- ❌ Couleur partout, pills/badges partout
- ❌ Teintes accent arc-en-ciel par état
- ❌ Sur-information (tout déplié d'un coup)
- ❌ Cards répétitives identiques (5 cards même rythme)
- ❌ Contrôles morts (labels non-interactifs qui imitent un réglage)
- ❌ `.ultraThinMaterial` simulé / shell gradient custom / fallback `#available`
- ❌ Décoration au lieu de micro-interactions
- ❌ Gradient backdrop peint (la profondeur vient du verre, pas de la peinture)

### Vérifications finales

```bash
# 1. Plus de gradient backdrop coloré
grep -n "SleepGradientBackdrop\|SleepGradientPalette" Loop/Features/Today/Detail/Sleep/
# Doit retourner 0 résultats

# 2. Plus de shells privés
grep -rn "struct.*GlassShell\|struct.*Shell.*View" Loop/Features/Today/Detail/Sleep/
# Doit retourner 0 résultats

# 3. Band = une seule teinte accent
grep -n "band\." Loop/Features/Today/Detail/Sleep/Components/*.swift | wc -l
# Doit montrer l'accent utilisé uniquement sur : dot hero, barre duration si warning, message coach

# 4. deviceSurface utilisé (pas de sleepCard)
grep -rn "deviceSurface\|loopGlass" Loop/Features/Today/Detail/Sleep/Components/*.swift
# Doit être présent sur les 4 surfaces (duration, stages, facts, tonight)

# 5. Progressive disclosure
grep -n "isExpanded" Loop/Features/Today/Detail/Sleep/Components/*.swift
# Doit être présent dans SleepStagesCard + SleepInsightDisclosure

# 6. Pressable
grep -n ".pressable" Loop/Features/Today/Detail/Sleep/Components/*.swift
# Doit être présent sur les headers tappable

# 7. Build
xcodegen generate
xcodebuild -scheme Loop -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Critères d'acceptation

- [ ] Backdrop = `Color(.systemGroupedBackground)` (plus de gradient coloré)
- [ ] Hero sans card, score 78pt en encre, un seul point accent (band.color), pulse si score < 55
- [ ] Durée = métrique mise en avant avec barre WHOOP (track + fill + marqueur objectif), animation spring à l'apparition
- [ ] Carte de la nuit = progressive disclosure (mini-hypnogramme 60pt collapsed → 232pt expanded avec cursor)
- [ ] Hypnogramme monochrome (nuances de `.primary`, pas de couleurs par stage)
- [ ] Faits secondaires groupés dans UNE surface (8 rows max, séparateurs Divider)
- [ ] FC repos / HRV / Efficacité affichés (depuis SleepSession — A1-1/2/3)
- [ ] Pourquoi ce score = disclosure fermé par défaut, driver dominant en header, 3 drivers détaillés à l'expansion
- [ ] Plan de ce soir = heures réelles (sleepStart/sleepEnd ou UserPreferences), sleep debt 7j, sleep needed, message coach accent band
- [ ] Plus de "07:00" hardcodé (utilise `UserPreferences.wakeDateToday`)
- [ ] Plus de `accent` purple/cyan/vert/orange (remplacé par `band` green/yellow/red)
- [ ] `.pressable` sur tous les headers tappable (haptic + shrink)
- [ ] Entrée staggered cascade 0.05s par section
- [ ] `.contentTransition(.numericText())` sur les chiffres qui changent
- [ ] `.deviceSurface(cornerRadius:)` sur les 4 surfaces (pas de shell custom)
- [ ] Build OK sans warnings iOS 26+
- [ ] `#Preview` pour chaque nouveau composant (au moins 2 états : score bon / score bas, real stages / no stages)
- [ ] Aucun commentaire évident, conventions Loop respectées
- [ ] `DESIGN.md` respecté : monochrome, une teinte accent, progressive disclosure, micro-interactions premium, Liquid Glass natif

### Inspiration externe (à adapter, ne pas copier)

- **Page Device de Loop** (`Loop/Features/Device/`) — implémentation de référence du design language. Étudie la composition, pas juste les composants.
- **WHOOP app** — barres de durée avec marqueur objectif, hypnogramme 4 lanes, progressive disclosure sur les insights
- **Apple Health** — hypnogramme 4 lanes (déjà porté dans le ribbon actuel), dense mais lisible
- **Goose `SleepV2OverviewPage`** — hero + sleep window card + insights sheet (progressive disclosure) + trend rows
- Voir `loop/loop-redesign/05-inventaire-depots-externes.md` §4 pour le détail

### Ordre d'implémentation recommandé

1. **Étendre `SleepCoachModel`** — band, debt, needed, restingHr, avgHrv, efficiency, real bedtime/wake, supprimer `accent` color, marquer/cleaner l'estimation
2. **`SleepBand`** (ou réutiliser `RecoveryBand`) — sémantique green/yellow/red/calibrating
3. **`SleepHero`** — hero sans card, score + dot accent + pulse
4. **`SleepDurationCard`** — métrique mise en avant + barre WHOOP + marqueur objectif + animation
5. **`SleepStagesCard`** — progressive disclosure hypnogramme (mini collapsed → full expanded + cursor)
6. **`SleepFactsGroup`** — 8 rows groupés dans une surface (incluant FC repos / HRV / Efficacité nouveaux)
7. **`SleepInsightDisclosure`** — drivers en disclosure fermé par défaut
8. **`SleepTonightPlan`** — heures réelles + debt + needed + message coach
9. **`SleepDetailView`** — composer les 6 sections, backdrop uni, entrée staggered, supprimer gradient backdrop
10. **Supprimer** les 6 anciens fichiers + `SleepShells`
11. **`SleepStage`** enum — couleurs monochromes
12. `xcodegen` + compile + previews

---

Fin du prompt.
