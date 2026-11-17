# Audit du design system actuel — Loop

Date : 2026-11-15. Lecture seule du code (`Loop/`, `LoopWidgets/`, `DESIGN.md`, `project.yml`). Aucun rendu simulateur : les constats visuels sont déduits du code. Les contrastes sont calculés (WCAG 2.x) sur fonds opaques ; sur du verre réel, la valeur dépend de ce qui est derrière (non mesuré).

---

## 1. Résumé (10 lignes)

1. La règle fondatrice est écrite : « Monochrome d'abord » et « une seule teinte accent par page » (`DESIGN.md:8`, `DESIGN.md:10`), avec des teintes d'alerte seulement en état critique (`DESIGN.md:13`).
2. Toutes les surfaces sont un `.glassEffect(.regular)` non teinté (`Loop/Shared/LoopGlass.swift:14`, `Loop/Features/Device/Components/DeviceSurface.swift:14`), soit 49 cartes. Aucune n'est teintée, aucune n'utilise `.clear`, une seule famille de rayon (26 pt).
3. Tous les textes sont en `.primary` / `.secondary` / `.tertiary`. La couleur n'apparaît que sur des icônes de 15 pt (`WidgetChrome.swift:18-19`), des barres de 6 pt (`SleepWidget.swift:58`, `StrainTargetWidget.swift:54`), des points de 7-8 pt (`FocusWidget.swift:15`, `DeviceHero.swift:69`) et les trois anneaux (`TodayView.swift:6-8` : « the rings are the page's single locus of colour »).
4. L'accent global est neutralisé : `.tint(.primary)` sur le `TabView` (`MainTabView.swift:42`) se propage à tous les onglets, donc le « seul accent » de la page Profil (`.foregroundStyle(.tint)`, `ProfileHeader.swift:35`) est rendu en encre noire ou blanche.
5. Le projet n'a pas de couleur d'accent dans ses assets (`Loop/Assets.xcassets` contient seulement `AppIcon` et `whoop_device`). `Color.accentColor` vaut donc le bleu système, et ce bleu n'apparaît que dans les deux sheets Bluetooth.
6. Le fond d'app est un dégradé bleu nuit qui rejoint `systemGroupedBackground` à 60 % de la hauteur (`AppBackground.swift:29-31`). Toute la zone des cartes est donc grise ou noire.
7. Il existe au moins 5 palettes concurrentes (Pop, couleurs système, RGB codés en dur des bands, HSB des anneaux, hex des widgets), et une même métrique change de couleur d'un écran à l'autre (section 5).
8. Le vrai Liquid Glass est présent mais limité au strict minimum : jamais de `GlassEffectContainer`, de `glassEffectID` ni de `.clear`. `.interactive()` apparaît 3 fois et le verre teinté 4 fois, uniquement dans les sheets Bluetooth.
9. La tab bar système (Liquid Glass) est surchargée par un `UITabBarAppearance` avec `UIBlurEffect(.systemUltraThinMaterial)` (`MainTabView.swift:44-49`), et les sheets forcent `.thinMaterial` (`NoSensorSheet.swift:39`, `SensorDetectedSheet.swift:46`).
10. Conséquence : un écran Today montre en pratique un fond gris, des cartes en verre incolore et du texte gris. La seule couleur visible en surface, ce sont les trois anneaux et quelques icônes de 15 pt. C'est ce qui produit l'effet « neutre ».

---

## 2. Tokens inventoriés

### 2.1 Couleurs

Aucun catalogue de couleurs (`*.colorset`) dans `Loop/` ou `LoopWidgets/`. Toutes les couleurs sont définies en code. Seul `AppBackgroundToken` est dynamique clair/sombre. Toutes les autres valeurs sont fixes et identiques dans les deux modes.

**Palette « Pop »** (`Loop/Shared/PopPalette.swift`). C'est la seule palette nommée partagée. Fixe, sans variante sombre.

| Token | sRGB | Hex | Fichier:ligne |
|---|---|---|---|
| `Pop.red` | 1.00 / 0.27 / 0.33 | #FF4554 | PopPalette.swift:6 |
| `Pop.orange` | 1.00 / 0.55 / 0.10 | #FF8C1A | PopPalette.swift:7 |
| `Pop.amber` | 1.00 / 0.72 / 0.12 | #FFB81F | PopPalette.swift:8 |
| `Pop.green` | 0.16 / 0.85 / 0.45 | #29D973 | PopPalette.swift:9 |
| `Pop.blue` | 0.24 / 0.56 / 1.00 | #3D8FFF | PopPalette.swift:10 |
| `Pop.indigo` | 0.48 / 0.42 / 1.00 | #7A6BFF | PopPalette.swift:11 |
| `Pop.cyan` | 0.18 / 0.80 / 0.96 | #2ECCF5 | PopPalette.swift:12 |

**Fond d'app** (`Loop/Shared/AppBackground.swift`)

| Token | Clair | Sombre | Fichier:ligne |
|---|---|---|---|
| `AppBackgroundToken.top` (stop 0) | #0B1F6B | #0A1A4A | AppBackground.swift:9-10, 29 |
| `AppBackgroundToken.mid` (stop 0.22) | #6F86C9 | #07102B | AppBackground.swift:12-13, 30 |
| `AppBackgroundToken.bottom` (stop 0.6) | `systemGroupedBackground` (#F2F2F7) | `systemGroupedBackground` (#000000) | AppBackground.swift:15, 31 |

**Anneaux Today** (`Loop/Features/Today/Home/TodayRingModel.swift`)

| Token | Définition | Hex | Ligne |
|---|---|---|---|
| `sleepColor` | HSB 0.58/0.55/0.80 | #5C96CC | :21 |
| `strainColor` | HSB 0.55/1.00/0.95 | #00AAF2 | :22 |
| `pendingColor` | HSB 0.58/0.10/0.60 | #8A9299 | :23 |
| `recoveryColor(score:)` | `.green` / `.yellow` / `.red` système (seuils 67/34) | système | :25-29 |

**Bands des pages détail**

| Token | Valeurs | Fichier:ligne |
|---|---|---|
| `RecoveryBand.color` | vert #29C773, jaune #F5BD2E, rouge #F25752, calibrage #8C8C8C | RecoveryCoachModel.swift:420-426 |
| `RecoveryBand.glowColor` | #2EDB85, #FFCC4D, #FF6B61, gris 0.70. **Jamais utilisé** (aucun appel hors définition) | RecoveryCoachModel.swift:431-437 |
| Delta better/worse/neutral (Recovery) | #29C773 / #F25752 / gris 0.55 | RecoveryCoachModel.swift:502-504 |
| `StrainBand.color` | easy #66B8EB, moderate #4794F0, high #00AAF2, veryHigh #7A47EB, calibrage gris 0.55 | StrainCoachModel.swift:451-458 |
| `StrainBand.glowColor` | 5 valeurs. **Jamais utilisé** | StrainCoachModel.swift:461-468 |
| Delta (Strain) | #29C773 / #F25752 / gris 0.55 | StrainCoachModel.swift:555-557 |
| `SleepBand.color` | `Pop.green` / `Pop.amber` / `Pop.red` / gris 0.55 (seuils 55/70) | Sleep/SleepBand.swift:12-13, 19-22 |
| `SleepStage.color` | `.primary` aux opacités 0.35 / 0.55 / 0.78 / 1.0 (monochrome) | Sleep/SleepCoachModel.swift:493-499 |
| `StressBand.color` | `Pop.green` / `Pop.amber` / `Pop.red` / `.secondary` | Stress/StressBand.swift:25-31 |
| `HeartRateZone.color` | `.primary` aux opacités 0.15 → 0.82, Z5 = `Pop.red` | HeartRate/HeartRateZone.swift:22-30 |
| `HeartRateCoachModel.accent` | `Pop.red` | HeartRate/HeartRateCoachModel.swift:37 |
| Zones séance | même rampe, Z5 `Pop.red` | Workout/WorkoutHeartRateZonesCard.swift:27 |

**Device**

| Token | Valeurs | Fichier:ligne |
|---|---|---|
| `statusDot` | `.green`, `.orange` (stuck/erreur), `.yellow` (connexion), `.secondary` | Device/DeviceSnapshot.swift:85-93 |
| `batteryColor` | charge/sain #4CBD75, <35 #E68F33, <15 #DB474C | Device/DeviceSnapshot.swift:126-133 |
| `batteryEmphasis` | `batteryColor` si <20, sinon `.primary` | Device/DeviceSnapshot.swift:117-122 |
| Timeline | sommeil `Pop.indigo`, séance `Pop.orange` | Today/Model/TimelineBuilder.swift:6-7 |

**Widgets WidgetKit et Live Activity**

| Token | Valeurs | Fichier:ligne |
|---|---|---|
| Sleep | #4D8FEA | Main/MainTabView.swift:98 ; Shared/LoopWidgetSnapshotStore.swift:19 |
| Recovery | #36B56A, **fixe quel que soit le score** | MainTabView.swift:109 ; LoopWidgetSnapshotStore.swift:20 |
| Strain | #10A7D9 | MainTabView.swift:120 ; LoopWidgetSnapshotStore.swift:21 |
| Battery | ≤5 → #E5484D, en charge → #36B56A, sinon #8A8F98 | MainTabView.swift:124-131 |
| Live Activity | charge `.green`, batterie faible `.red`, sync HSB 0.56/0.72/0.92 (#42AEEB) | LoopWidgets/BraceletBatteryLiveActivityWidget.swift:176-186 |

**Accent et divers**

| Token | Valeur | Fichier:ligne |
|---|---|---|
| Tint global | `.tint(.primary)` | MainTabView.swift:42 |
| Tint du DatePicker | `.tint(.primary)` | Today/Components/DateNavigator.swift:118 |
| `Color.accentColor` | bleu système (pas d'asset AccentColor). Utilisé uniquement dans les sheets Bluetooth | NoSensorSheet.swift:75,129,141,143,152,155,161,164 ; SensorDetectedSheet.swift:57,67,70,109,148 |
| Toggles et réveil | `Pop.green` | Device/Components/AlarmView.swift:90,155,194 |
| `LoopGlassShell` accent par défaut | HSB 0.57/0.40/0.92 (#8DC3EB), trait #9EB2BD, ombre #66808F. **Composant non utilisé** | Shared/LoopGlassShell.swift:22,80,88 |
| Code mort | `TodayGreetingHeader` (#42AEEB, #3FD179) et `HealthDayWidget` (Pop.blue/cyan) ne sont instanciés que dans des `#Preview` | TodayGreetingHeader.swift:58-59 ; HealthDayWidget.swift:249-253 |

### 2.2 Typographie

- **Police** : SF système uniquement. Aucune police custom (`Font.custom` non trouvé). `design: .rounded` apparaît 3 fois (`ProfileHeader.swift:34`, `HealthDayWidget.swift:83` qui est du code mort, `BraceletBatteryLiveActivityWidget.swift:121`). `.monospaced` apparaît 1 fois (`DeviceAdvancedView.swift:89`).
- **Tailles fixes** : environ 354 occurrences de `.font(.system(size:))`. Répartition des tailles : 12 pt (59), 13 pt (69), 14 pt (55), 15 pt (67), 11 pt (20), 16 pt (16), 10 pt (13), puis 17-30 pt, 34, 56 et 78 pt.
- **Styles sémantiques** : environ 105 occurrences (`.footnote` 35, `.subheadline` 27, `.caption` 19, `.body` 8, `.headline` 7, etc.). Ils sont concentrés dans `TrainingAdviceWidget.swift`, la Live Activity et les écrans Backup/Health.
- **Graisses** : semibold 162, medium 94, regular 23, bold 12.
- **Échelle de fait** (non tokenisée) :

| Rôle | Taille / graisse | Exemple fichier:ligne |
|---|---|---|
| Héros détail (score) | 78 semibold + unité 34 | Recovery/Components/RecoveryHero.swift:39,43 ; Strain/Components/StrainHero.swift:17 |
| Titre Today | 28 bold | Today/Home/TodayHeader.swift:18 |
| Titre Device/Profil | 26 semibold | Device/Components/DeviceHero.swift:20 ; Profile/Components/ProfileHeader.swift:53 |
| Valeur widget | 30 semibold + unité 15 | Today/Widgets/WidgetChrome.swift:50,55 |
| Valeur tuile compacte | 26 semibold | Today/Widgets/CompactMetricTile.swift:33 |
| Valeur anneau | 23 semibold + unité 11 | Today/Home/TodayRing.swift:24,29 |
| Titre Focus | 20 semibold | Today/Widgets/FocusWidget.swift:25 |
| Mot de band (héros) | 18 semibold | RecoveryHero.swift:19 |
| Libellé widget | icône 15 + titre 14 semibold `.secondary` | WidgetChrome.swift:18,23 |
| Corps et légende | 13-14 regular | FocusWidget.swift:30 ; ExpandableCard.swift:86 |
| Overline | 10-12 semibold, tracking 0.6-1.4, majuscules | TodayRing.swift:37-38 ; RecoveryHero.swift:12-13 ; FocusWidget.swift:18-21 ; ProfileView.swift:81-84 |

### 2.3 Rayons

| Valeur | Usage | Fichier:ligne |
|---|---|---|
| 26 (défaut) | `loopGlass()` ×6, `deviceSurface()` ×43 | LoopGlass.swift:11 ; DeviceSurface.swift:11 |
| 30 | héros des anneaux | TodayRingsHero.swift:19 |
| 28 | `LoopGlassShell` (non utilisé) | LoopGlassShell.swift:27 |
| 22 | tuile séance | Workout/WorkoutMetricTile.swift:31 |
| 20 | SyncToast | SyncToast.swift:32 |
| 18 | lignes Device et Alarm | DeviceView.swift:134 ; AlarmView.swift:74,92,107,143,177,197 |
| 16 | badge séance | Workout/WorkoutDetailHeader.swift:19 |
| 14 | verre imbriqué dans les disclosures (×9) | voir 3.3 |
| capsule / cercle | DateNavigator, boutons primaires, avatar | DateNavigator.swift:39 ; DeviceActions.swift:62 ; ProfileHeader.swift:37 |

Il n'existe pas de token de rayon : les valeurs sont passées en littéral.

### 2.4 Espacements

Il n'existe pas de token d'espacement. `CLAUDE.md:82` cite `WH.Spacing.md`, mais aucun enum `WH`, `Spacing` ou `Radius` n'existe dans le code (non trouvé).

| Rôle | Valeurs observées | Fichier:ligne |
|---|---|---|
| Gouttière d'écran | 16 (Today, détails) / 20 (Device, Profil) | TodayView.swift:51 ; RecoveryDetailView.swift:37 ; DeviceView.swift:35 ; ProfileView.swift:62 |
| Padding interne de carte | 16 (widgets Today) / 18 (cartes détail, Device) | WidgetChrome.swift:66 ; CompactMetricTile.swift:50 ; RecoveryWhyDisclosure.swift:36 ; DeviceBatteryCard.swift:36 |
| Pas entre cartes | 14 (stack Today), 16 (Today), 22 (détails, Profil), 24 (Device) | TodayWidgetStack.swift:42 ; TodayView.swift:22 ; RecoveryDetailView.swift:29 ; ProfileView.swift:29 ; DeviceView.swift:55 |
| Fréquences | padding 16 (×44), 18 (×36), 24 (×30) ; spacing 10 (×42), 12 (×41), 8 (×39), 14 (×31) | grep global |

### 2.5 Ombres

| Fichier:ligne | Valeur |
|---|---|
| Today/Components/RingView.swift:106 | halo d'anneau `color.opacity(0.25)`, r 8 |
| Device/Components/DeviceHero.swift:40 | photo du bracelet, blanc 0.10 (sombre) / noir 0.22 (clair), r 18, y 10 |
| Device/Components/DeviceEmptyState.swift:18 | noir 0.5 / 0.1, r 24, y 12 |
| Device/NoSensorSheet.swift:220 | LED pulsée `color.opacity(0.7)`, r 4→10 |
| Shared/LoopGlassShell.swift:37-38 | double ombre (non utilisé) |

Les cartes en verre n'ont pas d'ombre custom (c'est le comportement natif de `glassEffect`).

### 2.6 Opacités récurrentes

| Valeur | Rôle | Fichier:ligne |
|---|---|---|
| `.primary` 0.06 | séparateur | ExpandableCard.swift:61 |
| `.primary` 0.08 | rail de barre ou d'anneau | RingView.swift:73 ; StrainTargetWidget.swift:42 ; SleepStagesCard.swift:130 |
| `.primary` 0.20 | zone cible d'anneau | RingView.swift:80 |
| `.primary` 0.22 | barres d'historique hors jour courant | RecoveryTrendCard.swift:74 ; StrainLoadCard.swift:110 ; HeartRateRestingTrendCard.swift:79 |
| `.primary` 0.30 | ticks de zone | StrainTargetWidget.swift:59 |
| tint 0.14 | pastille d'icône de timeline | TimelineRow.swift:12 |
| tint 0.14-0.18 | verre teinté (sheets) | SensorDetectedSheet.swift:133 ; NoSensorSheet.swift:155,164 |
| 0.25→0.02 / 0.22→0.02 | aire sous courbe | HeartRateRangeChart.swift:86 ; StressTimelineCard.swift:65 |
| 0.6 | état désactivé | DeviceActions.swift:63 ; RecalcCard.swift:43 ; DeviceEmptyState.swift:62 |

---

## 3. Liquid Glass

Cible de déploiement : `project.yml:5` déclare iOS **27.0** alors que `DESIGN.md:19` dit « cible 26.0 ». Aucun `#available` : les API iOS 26 sont utilisables partout.

### 3.1 Vrai Liquid Glass (API iOS 26)

| API | Où | Variante |
|---|---|---|
| `.glassEffect(.regular, in: .rect(26))` via `LoopGlass` | LoopGlass.swift:14. Appelants : TodayRingsHero.swift:19, WidgetChrome.swift:68, CompactMetricTile.swift:52, ExpandableCard.swift:69, TimelineWidget.swift:42, SyncToast.swift:32, plus 9 imbrications à 14 pt | regular, non teinté, non interactif |
| `.glassEffect(.regular, in: .rect(26))` via `DeviceSurface` (**copie identique** de `LoopGlass`) | DeviceSurface.swift:14. 43 appelants (toutes les cartes détail, Device, Profil) | regular, non teinté, non interactif |
| `.glassEffect(.regular, in: .capsule)` | DateNavigator.swift:39 | regular |
| `.glassEffect(.regular, in: .circle)` | ProfileHeader.swift:37 (avatar) | regular |
| `.glassEffect(.regular.interactive(), in: .capsule)` | DeviceActions.swift:62 ; RecalcCard.swift:42 ; DeviceEmptyState.swift:61 | interactive (3 occurrences) |
| `.glassEffect(.regular.tint(...))` | NoSensorSheet.swift:154,163 ; SensorDetectedSheet.swift:69,133 | teinté (4 occurrences, sheets Bluetooth uniquement) |
| `.buttonStyle(.glass)` | NoSensorSheet.swift:83,100 ; SensorDetectedSheet.swift:156 ; AlarmView.swift:213 | 4 |
| `.buttonStyle(.glassProminent)` | NoSensorSheet.swift:74,128 ; SensorDetectedSheet.swift:147 | 3 |
| `.tabBarMinimizeBehavior(.onScrollDown)` | MainTabView.swift:40 | 1 |
| `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`, `glassEffectTransition`, `Glass.clear`, `scrollEdgeEffectStyle`, `backgroundExtensionEffect`, `ToolbarSpacer`, `tabViewBottomAccessory` | non trouvé | — |

### 3.2 Matériaux classiques et imitations (pas du Liquid Glass)

| Élément | Fichier:ligne | Nature |
|---|---|---|
| `LoopGlassShell` | Shared/LoopGlassShell.swift:17-94 | Imitation : `.ultraThinMaterial` ou `.regularMaterial`, dégradés de lavis et de bordure, double ombre. **0 appelant** (code mort) |
| `LoopBadgeShell` | Shared/LoopGlassShell.swift:98-111 | Remplissage à opacité 0.12-0.16 et trait. Utilisé seulement dans OnboardingView.swift:138 |
| Tab bar UIKit | MainTabView.swift:44-49 | `UITabBarAppearance.configureWithDefaultBackground()` et `backgroundEffect = UIBlurEffect(.systemUltraThinMaterial)`, appliqués à `standardAppearance` et `scrollEdgeAppearance`. C'est un flou legacy posé sur une tab bar qui est nativement en Liquid Glass sous iOS 26. Le rendu effectif est à vérifier en simulateur |
| Fonds de sheets | NoSensorSheet.swift:39 ; SensorDetectedSheet.swift:46 | `.presentationBackground(.thinMaterial)` remplace le fond verre par défaut des sheets iOS 26 |
| Live Activity | BraceletBatteryLiveActivityWidget.swift:78,117 | `.ultraThinMaterial` en cercle et en capsule |
| Lavis de fond des sheets | NoSensorSheet.swift:139-148 | `LinearGradient` accentColor 0.18 / 0.10 |
| Boutons non-verre | WorkoutRPEView.swift:138 ; DeviceSheetModifier.swift:58,79 ; OnboardingView.swift:158,294,379 ; HealthDayWidget.swift:226 | `.borderedProminent` / `.bordered` |

### 3.3 Verre imbriqué sans conteneur

`loopGlass(cornerRadius: 14)` est posé à l'intérieur d'une carte `deviceSurface()`, donc du verre sur du verre sans `GlassEffectContainer`, à 9 endroits :
StrainWhyDisclosure.swift:29, SleepInsightDisclosure.swift:30, SleepStagesCard.swift:432, StrainLoadCard.swift:29, RecoveryWhyDisclosure.swift:30, HeartRateZonesCard.swift:56, HeartRateRestingTrendCard.swift:28, StressBalanceCard.swift:34, StressWhyDisclosure.swift:35.

`DateNavigator` (verre capsule, DateNavigator.swift:39) est placé dans `ToolbarItem(placement: .principal)` (TodayView.swift:61 ; RecoveryDetailView.swift:50 ; SleepDetailView.swift:64 ; StrainDetailView.swift:55). Sous iOS 26, la barre applique déjà son propre traitement aux items : un double verre est possible, à vérifier en simulateur.

Les boutons primaires (`DeviceActions.swift:62`, `RecalcCard.swift:42`, `DeviceEmptyState.swift:61`) combinent `.interactive()`, qui produit la réaction native au toucher, avec `.pressable` (PressableScale.swift:15, scale 0.97). Ces deux retours au toucher se cumulent.

### 3.4 Composants Apple pouvant porter le verre : état actuel

| Composant | État | Source |
|---|---|---|
| Tab bar | `TabView` + `.tabItem` (API historique, pas `Tab(...)`). Minimisation au scroll active. Tint `.primary`. Flou UIKit superposé | MainTabView.swift:13-33, 40, 42, 44-49 |
| Accessoire de tab bar (`tabViewBottomAccessory`) | Non utilisé. Le statut de sync passe par un toast custom en haut d'écran | MainTabView.swift:35-37 |
| Barre de navigation | `.toolbarBackground(.hidden)` sur Today et les 7 détails. Grand titre système sur Device et Profil | TodayView.swift:59 ; StressDetailView.swift:34 ; DeviceView.swift:39 ; ProfileView.swift:66 |
| Boutons de toolbar | Aucun bouton (seul Onboarding en a un) | OnboardingView.swift:51 |
| Item principal de toolbar | `DateNavigator` avec son propre verre | DateNavigator.swift:39 |
| Boutons | Verre natif dans les sheets et dans Alarm. Ailleurs : `Text` ou `HStack` + `.pressable` (geste custom, pas `Button`) | DeviceActions.swift:81-84 ; ProfileNavRow ; DeviceDetailsRow |
| Sheets | Detents `.medium`, fond forcé `.thinMaterial` | DeviceSheetModifier.swift:61,87 ; NoSensorSheet.swift:37-39 |
| Sheet RPE | Detents medium/large, fond par défaut | WorkoutRPEView.swift:51-56 |
| Popover | DatePicker graphique, fond par défaut | DateNavigator.swift:109-122 |
| Dialogues | `confirmationDialog` système | DeviceActions.swift:26 ; AdvancedView.swift:48,66 ; BackupView.swift:81 ; NoopImportView.swift:97 |
| Menus contextuels | Système | TimelineRow.swift:36 |
| Contrôles (Slider, Stepper, Picker, Toggle) | Système. Ils héritent du tint `.primary`, sauf les Toggle d'Alarm en `Pop.green` | BodyProfileCard.swift:33,63,86 ; StrainDifficultyCard.swift:38 ; MaxHeartRateCard.swift:65 ; AlarmView.swift:90,194 |
| Recherche | Non trouvé | — |
| Cartes de contenu | Verre regular non teinté partout | voir 3.1 |
| Widgets WidgetKit | `containerBackground(.background)`. `widgetAccentable` seulement sur l'accessoire rectangulaire, pas sur `MetricCircle`. Aucun `widgetRenderingMode` | LoopMetricsWidget.swift:10, 148-186, 237 |

---

## 4. Inventaire des composants

| Composant | Fichier | Rôle | États gérés | Couleur |
|---|---|---|---|---|
| `LoopGlass` / `.loopGlass()` | Shared/LoopGlass.swift:10 | Surface de carte Today | aucun (rayon seulement) | aucune |
| `DeviceSurface` / `.deviceSurface()` | Device/Components/DeviceSurface.swift:10 | Surface des détails, de Device et de Profil (doublon de LoopGlass) | aucun | aucune |
| `LoopGlassShell` | Shared/LoopGlassShell.swift:17 | Ancienne carte en matériau | clair/sombre | accent en paramètre. **Non utilisé** |
| `LoopBadgeShell` | Shared/LoopGlassShell.swift:98 | Pastille | clair/sombre | accent 0.12-0.22 |
| `AppBackground` | Shared/AppBackground.swift:25 | Fond dégradé | clair/sombre | bleu nuit → gris système |
| `SyncToast` | Shared/SyncToast.swift:9 | Statut de sync global | syncing, strapStuck, error, à jour | monochrome, y compris pour l'erreur (SyncToast.swift:29,43-45) |
| `TodayHeader` | Today/Home/TodayHeader.swift:5 | Salutation et statut | calcul (avec %), sync, erreur, à jour, attente | erreur `.red` système (:27), sinon `.secondary` |
| `TodayRingsHero` | Today/Home/TodayRingsHero.swift:5 | Trois anneaux cliquables | — | portée par les anneaux |
| `TodayRing` / `RingView` | Today/Home/TodayRing.swift:5 ; Components/RingView.swift:3 | Anneau, valeur, zone cible | pending/express, placeholder, animation d'entrée | couleur de l'anneau, texte en encre |
| `DateNavigator` | Today/Components/DateNavigator.swift:5 | Navigation par jour | flèches activées ou non, popover | encre, `.quaternary` si désactivé |
| `WidgetLabel` / `WidgetMetric` / `.widgetSurface()` | Today/Widgets/WidgetChrome.swift:6,43,64 | En-tête et valeur de widget | trailing, chevron | `tint` optionnel sur l'icône seulement |
| `ExpandableCard` | Today/Widgets/ExpandableCard.swift:15 | Carte repliable | replié/déplié, haptique | `symbolColor` optionnel (défaut `.secondary`) |
| `CompactMetricTile` | Today/Widgets/CompactMetricTile.swift:6 | Demi-tuile Cardio/Stress | valeur ou « — », légende | icône seulement |
| `FocusWidget` | Today/Widgets/FocusWidget.swift:5 | Conseil du jour | sans données, express, surcharge, récup haute/modérée/basse, sommeil court | point de 8 pt (Pop) |
| `StrainTargetWidget` | Today/Widgets/StrainTargetWidget.swift:7 | Cible de strain atteinte | caché, atteint, dépassé | Pop.green ou Pop.orange (icône, mot, barre) |
| `SleepWidget` | Today/Widgets/SleepWidget.swift:5 | Résumé du sommeil | replié/déplié, phases absentes | barre de phases indigo/bleu/cyan |
| `TimelineWidget` / `TimelineRow` | Today/Widgets/TimelineWidget.swift:5 ; TimelineRow.swift:5 | Chronologie du jour | vide, ≤3, >3 (repliable), rejet de séance | pastille teintée 0.14 et icône |
| `AlarmWidget` | Today/Widgets/AlarmWidget.swift:5 | Réveil actif | smart, regular, off | aucune |
| `DeviceAlertWidget` | Today/Widgets/DeviceAlertWidget.swift:5 | Batterie faible ou en charge | charge, faible | icône Pop.green ou Pop.red |
| `TrainingAdviceWidget` | Today/Widgets/TrainingAdviceWidget.swift:144 | Conseil d'entraînement | loading, absent, calibration, insufficient, partial, contradictory, ready | icône Pop.blue (ready) ou Pop.orange (contradictory) |
| Héros détail (Recovery/Strain/Sleep/Stress/HeartRate) | Today/Detail/*/Components/*Hero.swift | Score géant et mot de band | band, calibrage, pulse si bas | mot de band coloré, score en encre |
| Cartes détail (Gauge, Why, Facts, Trend, Improve/Manage, Load, Stages, Zones…) | Today/Detail/*/Components/ | Explication progressive | replié/déplié (Why, Trend), calibrage | une couleur de band par page (icône, mot, barre, barre du jour) |
| `DeviceHero` | Device/Components/DeviceHero.swift:9 | Photo et nom du bracelet | connecté, connexion, scan, déconnecté | point de 7 pt |
| `DeviceBatteryCard` | Device/Components/DeviceBatteryCard.swift:5 | Batterie | inconnu, charge, faible | barre vert/ambre/rouge, chiffre coloré si <20 |
| `DeviceActions` | Device/Components/DeviceActions.swift:5 | Action primaire et actions texte | busy, linked, confirmation | aucune |
| `DeviceEmptyState` | Device/Components/DeviceEmptyState.swift:5 | Pas de bracelet | scan / repos | aucune |
| `DeviceInfoGroup` / `DeviceDetailsRow` | Device/Components/ | Faits groupés, accès avancé | firmware présent ou non | aucune |
| `AlarmView` | Device/Components/AlarmView.swift | Réglage du réveil | jours on/off, mode | Pop.green (toggles, jours actifs avec texte blanc) |
| `NoSensorSheet` / `SensorDetectedSheet` | Device/*.swift | Appairage | pas de capteur, détecté | bleu système (accentColor), seule page bleue |
| `PressableScale` / `.pressable` | Device/Components/PressableScale.swift:7 | Retour au toucher (scale et haptique) | pressé | — |
| `ProfileHeader` | Profile/Components/ProfileHeader.swift:6 | Avatar et prénom éditable | édition | `.tint`, donc encre (voir 5.2) |
| `BodyProfileCard`, `StrainDifficultyCard`, `MaxHeartRateCard`, `ProfileDataGroup`, `RecalcCard`, `ProfileNavRow` | Profile/Components/ | Réglages et données | focus, erreur (`.red` ou `.orange`), progression | icône en `.tint`, donc encre |
| `LoopMetricsWidget` | LoopWidgets/LoopMetricsWidget.swift:100 | Widget écran d'accueil et accessoires | small, medium, accessoires | hex fixes par métrique |
| `BraceletBatteryLiveActivityWidget` | LoopWidgets/BraceletBatteryLiveActivityWidget.swift | Live Activity | charging, lowBattery, syncing | `.green`, `.red`, #42AEEB |
| `TodayGreetingHeader`, `HealthDayWidget` | Today/Components ; Today/Widgets | — | — | **Code mort** (instanciés seulement dans des previews) |

---

## 5. Règles de couleur actuelles

### 5.1 Règles déclarées dans le code

- **Pop** = petites touches (points, icônes de tuile, phases, timeline) (`PopPalette.swift:3-4`).
- **Anneaux** = seul foyer de couleur de Today (`TodayView.swift:6-8`, `TodayRingModel.swift:3-5`).
- **Band** = l'unique accent d'une page détail, dérivé du score (`SleepBand.swift:3-6`, `StressBand.swift:3-5`, `SleepCoachModel.swift:40`).
- **Device** = un seul point de statut. La barre de batterie est colorée par niveau seulement (`DESIGN.md:35-36`, `DeviceView.swift:8`).
- **Profil** = `.tint` pour l'avatar et les icônes (`DESIGN.md:11-12`, `ProfileView.swift:17-18`).
- **Cartes** = jamais de couleur de fond (`LoopGlass.swift:3`, `DeviceSurface.swift:3`).
- **Une seule couleur par carte** (`ExpandableCard.swift:18-19`, `WidgetChrome.swift:11-12`).

### 5.2 Incohérences constatées

**Une même métrique, des couleurs différentes selon l'écran**

| Métrique | Today | Widget Today | Détail | WidgetKit |
|---|---|---|---|---|
| Recovery | anneau `.green/.yellow/.red` **système** (TodayRingModel.swift:26-28) | point Focus `Pop.green/amber/red` (FocusWidget.swift:62) | `RecoveryBand` #29C773 / #F25752 (RecoveryCoachModel.swift:422-424) | #36B56A **fixe**, même à 10 % (MainTabView.swift:109) |
| Sleep | anneau bleu #5C96CC, indépendant du score (TodayRingModel.swift:21) | phases indigo/bleu/cyan (SleepWidget.swift:46-48) ; timeline Pop.indigo (TimelineBuilder.swift:6) | band vert/ambre/rouge (SleepBand.swift:19-21) et phases **monochromes** (SleepCoachModel.swift:493-499) | #4D8FEA (MainTabView.swift:98) |
| Strain | anneau #00AAF2 (TodayRingModel.swift:22) | cible Pop.green ou Pop.orange (StrainTargetWidget.swift:113) | 4 bands bleu → violet (StrainCoachModel.swift:453-456), dépassement Pop.orange (StrainTargetCard.swift:20,29) | #10A7D9 (MainTabView.swift:120) |
| Batterie | alerte Pop.red si ≤15, charge Pop.green (TodayContext.swift:41 ; DeviceAlertWidget.swift:37) | — | #DB474C si <15, #E68F33 si <35, #4CBD75 sinon (DeviceSnapshot.swift:128-132) | #E5484D si ≤5, #36B56A en charge, #8A8F98 sinon (MainTabView.swift:126-131) ; Live Activity `.green` / `.red` (BraceletBatteryLiveActivityWidget.swift:181-183) |
| « En charge » (vert) | Pop.green #29D973 | — | #4CBD75 | #36B56A ; `.green` (Live Activity) |

**Seuils divergents pour une même notion**
- Sommeil « bas » : <55 dans le détail (SleepBand.swift:12), <60 dans Focus (FocusWidget.swift:76).
- Zone cible de strain : ±1 sur l'anneau (TodayRingModel.swift:64), ±max(1.5, 12 %) dans le widget (StrainTargetWidget.swift:97).
- Batterie critique : ≤15 (TodayContext.swift:41), <15 (DeviceSnapshot.swift:130), <20 pour colorer le chiffre (DeviceSnapshot.swift:117-122), ≤5 (MainTabView.swift:126).

**Accent neutralisé ou désaligné**
- `.tint(.primary)` sur le TabView (MainTabView.swift:42) fait que tous les `.foregroundStyle(.tint)` de Profil (ProfileHeader.swift:35, RecalcCard.swift:36, ProfileDataGroup.swift:30, BodyProfileCard.swift:107, MaxHeartRateCard.swift:175, ProfileNavRow.swift:16, StrainDifficultyCard.swift:27) sont rendus en encre. La règle « accent unique = `.tint` » (DESIGN.md:11-12) n'a donc aucun effet visible.
- Les sheets Bluetooth utilisent `Color.accentColor` (le bleu système, faute d'asset) : c'est la seule zone bleue de l'app (NoSensorSheet.swift:75-164 ; SensorDetectedSheet.swift:57-148).

**Couleurs système codées en dur dans les vues** (hors palette Pop)
TodayHeader.swift:27 (`.red`) ; WorkoutRPEView.swift:125 (`.red`) ; DeviceSnapshot.swift:88-91 (`.orange`, `.green`, `.yellow`) ; RecalcCard.swift:23,73 (`.orange`) ; MaxHeartRateCard.swift:102 (`.red`) ; BackupView.swift:47,53 ; AdvancedView.swift:17,64 ; HealthImportView.swift:41,121,133,151 ; NoopImportView.swift:44,172,181 ; BraceletBatteryLiveActivityWidget.swift:181,183.

**Erreurs et alertes traitées sans couleur, contrairement à DESIGN.md:13**
- Bracelet bloqué : icône et texte en `.secondary` (DeviceView.swift:125-130).
- SyncToast en erreur : `exclamationmark.triangle.fill` en `.primary` (SyncToast.swift:29,43-45).

**Logique de couleur dupliquée**
`stressColor` (TodayWidgetStack.swift:138-143) réimplémente `StressBand.color` (StressBand.swift:25-31). `TodayRingModel.recoveryColor` (:25-29) et `FocusWidget` (:62) réimplémentent `RecoveryBand`.

---

## 6. Accessibilité

### 6.1 Contrastes (calculés, fonds opaques)

| Texte | Fond | Ratio |
|---|---|---|
| `.secondary` clair (#3C3C43 à 60 %) | #F2F2F7 | ≈3,3:1, sous 4,5:1 pour du texte <18 pt |
| `.tertiary` clair (30 %) | #F2F2F7 | ≈1,7:1 |
| `.secondary` sombre | #000000 / #1C1C1E | ≈6,4:1 / 6,0:1 |
| `.tertiary` sombre | #1C1C1E | ≈2,5:1 |
| `.primary` clair (noir) | haut du dégradé clair #0B1F6B (AppBackground.swift:9) | **≈1,4:1** |
| `.secondary` clair | milieu du dégradé clair #6F86C9 | ≈1,9:1 |
| Pop.amber / Pop.green / Pop.orange en texte | #F2F2F7 | 1,55 / 1,67 / 2,09:1 |
| RecoveryBand jaune #F5BD2E (mot du héros, 18 pt) | #F2F2F7 | 1,54:1 (9,9:1 en sombre) |
| Texte blanc sur Pop.green (jours actifs d'Alarm) | #29D973 | 1,86:1 (AlarmView.swift:150,155) |

Usages porteurs d'information en `.tertiary` : légende de tuile 11 pt (CompactMetricTile.swift:45), trailing de widget (WidgetChrome.swift:31), statut du réveil 12 pt (DeviceView.swift:104), objectif sommeil (SleepWidget.swift:21), overline du héros (RecoveryHero.swift:14), labels de section et avertissement médical (ProfileView.swift:59,83).

En mode clair, le texte `.primary` placé en haut d'écran (TodayHeader dans TodayView.swift:23, grands titres de Device et Profil, héros des détails avec padding top 24) se trouve sur la zone #0B1F6B → #6F86C9. L'app ne force pas de schéma de couleur (`preferredColorScheme` n'apparaît que dans des previews : DeviceHero.swift:86, DeviceEmptyState.swift:75).

### 6.2 Dynamic Type

- Environ 354 `.font(.system(size:))` fixes contre environ 105 styles sémantiques. Les tailles fixes ne suivent pas Dynamic Type.
- `@ScaledMetric` : 1 occurrence (WorkoutDetailHeader.swift:8). Adaptation de la grille selon `dynamicTypeSize` : 1 occurrence (WorkoutMetricsGrid.swift:8-11).
- Tous les écrans principaux (Today, widgets, héros, Device, Profil) sont en tailles fixes.

### 6.3 Reduce Transparency, Reduce Motion, couleur seule

- `accessibilityReduceTransparency` : non trouvé. Le `glassEffect` natif est censé gérer ce réglage côté système (comportement Apple, non vérifié ici). Les matériaux forcés (`.thinMaterial` des sheets, flou de la tab bar) ne sont pas adaptés explicitement.
- `accessibilityReduceMotion` : non trouvé. Pourtant on trouve des entrées décalées (TodayWidgetStack.swift:47, DeviceView.swift:89, RecoveryDetailView.swift:58-62), des `symbolEffect(.pulse)` (DeviceAlertWidget.swift:15, RecoveryHero.swift:21, DeviceBatteryCard.swift:24) et une LED pulsée (NoSensorSheet.swift:220).
- `accessibilityDifferentiateWithoutColor` : non trouvé. La barre de phases du widget sommeil n'a pas de légende : la couleur seule distingue les phases (SleepWidget.swift:50-59).

### 6.4 Cibles tactiles et rôles

- Flèches du DateNavigator : 34×34 pt (DateNavigator.swift:64). Déclencheur : hauteur 34 pt (DateNavigator.swift:145).
- Jours d'Alarm : 38×38 pt (AlarmView.swift:156).
- Actions texte de Device (« HR en direct », « Déconnecter ») : texte 14 pt sans padding, avec `.pressable` (DeviceActions.swift:18-23, 81-84).
- `WidgetDetailLink` : texte 13 pt (ExpandableCard.swift:102-110).
- `.pressable` est un `DragGesture` et non un `Button` (PressableScale.swift:18-31). Il est utilisé environ 19 fois. `accessibilityAddTraits(.isButton)` : non trouvé dans tout le code. Ces rangées et boutons ne sont donc pas annoncés comme boutons par VoiceOver.

---

## 7. Dette prioritaire (10 points)

1. **Accent global neutralisé** : `MainTabView.swift:42` `.tint(.primary)` éteint tout `.tint` de l'app, dont le seul accent de Profil (ProfileHeader.swift:35 et 6 autres appels). Le projet n'a pas d'asset AccentColor (`Loop/Assets.xcassets`).
2. **Tab bar** : `MainTabView.swift:44-49` superpose un `UIBlurEffect(.systemUltraThinMaterial)` UIKit au Liquid Glass natif, sur `standardAppearance` et `scrollEdgeAppearance`.
3. **Pas de source unique de couleur par métrique** : Recovery a 4 définitions (TodayRingModel.swift:25-29, FocusWidget.swift:62, RecoveryCoachModel.swift:420-426, MainTabView.swift:109). Le widget Recovery reste vert quel que soit le score.
4. **Sommeil contradictoire** : bleu fixe (TodayRingModel.swift:21), phases colorées (SleepWidget.swift:46-48), phases monochromes (SleepCoachModel.swift:493-499), band vert/rouge (SleepBand.swift:19-21), avec des seuils 55 et 60 (SleepBand.swift:12, FocusWidget.swift:76).
5. **Batterie** : 4 seuils et 4 verts différents (DeviceSnapshot.swift:117-133, TodayContext.swift:41, MainTabView.swift:124-131, BraceletBatteryLiveActivityWidget.swift:179-183).
6. **Surfaces en double et code mort** : `LoopGlass` (LoopGlass.swift:10-22) et `DeviceSurface` (DeviceSurface.swift:10-22) sont identiques. `LoopGlassShell` (LoopGlassShell.swift:17-94), `glowColor` (RecoveryCoachModel.swift:431, StrainCoachModel.swift:461), `TodayGreetingHeader` et `HealthDayWidget` ne sont pas utilisés.
7. **Verre imbriqué sans `GlassEffectContainer`** : 9 `loopGlass(cornerRadius: 14)` dans des `deviceSurface()` (ex. RecoveryWhyDisclosure.swift:30, SleepStagesCard.swift:432). `DateNavigator` a son propre verre dans la toolbar (DateNavigator.swift:39). Aucun verre teinté ni interactif sur les cartes cliquables (TodayRingsHero.swift:19, CompactMetricTile.swift:52).
8. **Sheets** : `.presentationBackground(.thinMaterial)` (NoSensorSheet.swift:39, SensorDetectedSheet.swift:46) remplace le verre natif, et ces sheets sont les seules en bleu système (`Color.accentColor`, NoSensorSheet.swift:141-164).
9. **Typographie fixe non tokenisée** : environ 354 `.font(.system(size:))`, par ex. WidgetChrome.swift:18-55, TodayRing.swift:24-37, RecoveryHero.swift:12-43. Pas de Dynamic Type et pas d'échelle partagée. Les tokens d'espacement et de rayon n'existent pas non plus (gouttière 16 vs 20 : TodayView.swift:51 vs DeviceView.swift:35).
10. **Accessibilité** : en clair, texte noir sur #0B1F6B à ≈1,4:1 (AppBackground.swift:9 ; TodayHeader.swift:18-19). `.pressable` sans rôle bouton (PressableScale.swift:18). Cibles de 34 pt (DateNavigator.swift:64). Aucun respect de Reduce Motion.

Points annexes :
- Incohérence de cible iOS : `project.yml:5` (27.0) vs `DESIGN.md:19` (26.0).
- `MetricCircle` du widget n'a pas `widgetAccentable` (LoopMetricsWidget.swift:148-186) : en mode d'écran d'accueil teinté, les anneaux ne distinguent pas l'accent du reste.
- Les alertes bracelet bloqué et erreur de sync sont monochromes (DeviceView.swift:125-130 ; SyncToast.swift:29).

---

## 8. Questions ouvertes

1. **Mode d'usage** : clair, sombre ou les deux ? Le dégradé de fond et plusieurs contrastes ne posent problème qu'en clair (section 6.1).
2. **Règle « une seule teinte accent par page »** (DESIGN.md:10) : faut-il la garder, ou passer à une couleur identitaire par métrique (Sommeil, Récup, Strain, Stress, Cardio) appliquée partout (anneau, carte, détail, widget) ?
3. **Couleur d'une métrique** : faut-il une teinte fixe (ex. sommeil bleu, strain cyan) ou une teinte d'état (vert/ambre/rouge selon le score) ? Aujourd'hui les deux coexistent pour Sommeil et Strain.
4. **Accent d'app** : faut-il un tint global coloré (tab bar, contrôles, avatar Profil) à la place de `.primary` ? Si oui, lequel ?
5. **Verre teinté** : les cartes peuvent-elles prendre la teinte de leur métrique (`.glassEffect(.regular.tint(...))`, `.clear` sur le héros), ou faut-il garder le verre neutre et mettre la couleur seulement dans le contenu ?
