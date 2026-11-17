# Prompt — Fin du refactoring P0 : nettoyage shells + deep-links + sync toast

> Prompt à donner à un agent IA pour terminer le refactoring P0. La plupart du travail est déjà fait (ProfileView, DeviceView, Onboarding, BackupView, SettingsView supprimé). Il reste : supprimer les composants morts + leurs glass shells privés, finir la traduction FR, implémenter les deep-links et le sync toast.

---

## PROMPT

Tu vas terminer le refactoring P0 de l'app iOS Loop (Swift/SwiftUI, iOS 17+, offline-first, WHOOP 4.0). La majorité du travail est déjà faite : `ProfileView`, `DeviceView` repensée + `DeviceAdvancedView`, `OnboardingView` 4 étapes, `BackupView`, `MainTabView` (Today/Appareil/Profil), `UserPreferences` enrichi, et le nouveau système de widgets Today (`TodayHeader`, `TodayRingsHero`, `TodayWidgetStack`, `TodayContext`). Il reste 4 tâches.

### Avant de commencer

Charge les skills suivants depuis `.agents/skills/` :
- `swift-ui` (patterns SwiftUI)
- `swiftui-expert-skill` (state management, `@Observable`, `@EnvironmentObject`, performance)
- `swiftui-ui-patterns` (navigation, TabView, NavigationStack)
- `swift-concurrency-expert` (`@MainActor`, `Sendable`, async/await)

### Contexte projet

- Repo : `/Users/theo/dev/whoop/loop`
- Architecture : `LoopApp` → onboarding gate → `MainTabView` (Today / Appareil / Profil)
- Glass shell partagé déjà existant : `View.loopGlass(cornerRadius:)` (`Loop/Shared/LoopGlass.swift`, utilise `.glassEffect(.regular)`) et `LoopGlassShell(accent:)` (`Loop/Shared/LoopGlassShell.swift`, ancien style avec material + gradient + shadow) et `LoopBadgeShell(accent:)` (capsule badge)
- Sync status : `SyncCoordinator.$status` (`@Published SyncStatus`) avec `SyncStatus` enum (`.offline`, `.connectedIdle`, `.syncing(SyncPhase)`, `.strapStuck`, `.error(String)`) — déjà injecté via `.environmentObject(connection.bleManager.syncCoordinator)`
- BLE : `BLEConnectionManager.send(_:payload:writeType:)` prend un `WhoopCommand`
- Conventions : 4 espaces, PascalCase types, lowerCamelCase fonctions, `// MARK: -` sections, `final class` + `@MainActor` pour UI, `@Published` sur propriétés publiques. **AUCUN commentaires évident.** Tout en français.
- XcodeGen : `project.yml` à la racine. Lance `xcodegen` après ajouts/suppressions de fichiers.

---

## Tâche 1 — Supprimer les composants Today morts + fusion glass shells

### Problème

L'ancien système de composants Today (`Loop/Features/Today/Components/`) a été remplacé par un nouveau système de widgets (`Loop/Features/Today/Widgets/` + `Loop/Features/Today/Home/` + `Loop/Features/Today/Model/`). Les anciens composants sont **dead code** — plus référencés par `TodayView.swift` ni `TodayWidgetStack.swift`. Ils portent chacun leur propre glass shell privé (7 copies quasi-identiques), ce qui empêche la fusion.

### Composants morts à SUPPRIMER (vérifier d'abord avec `grep` qu'aucun n'est référencé en dehors de `Components/`)

| Fichier | Struct | Shell privé | Vérification |
|---|---|---|---|
| `Loop/Features/Today/Components/MetricsCard.swift` | `MetricsCard`, `MetricsGlassShell` | `MetricsGlassShell` | Plus utilisé (remplacé par `TodayRingsHero`) |
| `Loop/Features/Today/Components/CoachCard.swift` | `CoachCard`, `CoachGlassShell`, `CoachBadgeShell` | `CoachGlassShell` | Plus utilisé (remplacé par `FocusWidget`) — la logique coach a été portée dans `FocusWidget` |
| `Loop/Features/Today/Components/StressCard.swift` | `StressCard`, `StressGlassShell` | `StressGlassShell` | Plus utilisé (remplacé par `CompactMetricTile` + `StressDetailView`) |
| `Loop/Features/Today/Components/ExpressMetricsCard.swift` | `ExpressMetricsCard`, `ExpressGlassShell` | `ExpressGlassShell` | Plus utilisé |
| `Loop/Features/Today/Components/BraceletSyncStatusCard.swift` | `BraceletSyncStatusCard`, `BraceletSyncGlassShell`, `StatusBadgeShell` | `BraceletSyncGlassShell` | Plus utilisé |
| `Loop/Features/Today/Components/DeviceBatteryCards.swift` | `DeviceChargingCard`, `DeviceBatteryCriticalCard`, `DeviceCardGlassShell`, `DeviceCardBadgeShell` | `DeviceCardGlassShell` | Plus utilisé (remplacé par `DeviceAlertWidget`) |
| `Loop/Features/Today/Components/DeviceSectionHeader.swift` | `DeviceSectionHeader` | — | Plus utilisé |
| `Loop/Features/Today/Components/ActivityTimeline.swift` | `ActivityTimeline`, `ActivityTimelineHeader`, `ActivityTimelineCountBadge`, `ActivityTimelineDisclosureButton`, `ActivityTimelineDisclosureShell`, `ActivityTimelineDisclosureCountBadge`, `WorkoutSportPresentation` | — | Plus utilisé (remplacé par `TimelineWidget` + `TimelineBuilder` + `TimelineRow`) — vérifier que `WorkoutSportPresentation` n'est pas référencé ailleurs |
| `Loop/Features/Today/Components/ActivityTimelineCard.swift` | `ActivityTimelineCard`, `ActivityTimelineItem`, `ActivityTimelineKind`, `ActivityDurationTile`, `ActivityGlassShell` | `ActivityGlassShell` | Plus utilisé (remplacé par `TimelineRow`) |

### Étapes

1. Pour chaque fichier ci-dessus, lance `grep -rln "StructName" Loop/ --include="*.swift"` en excluant le fichier lui-même pour confirmer qu'il n'est plus référencé
2. Si non référencé → **supprimer le fichier**
3. Si une struct est encore référencée (ex: `WorkoutSportPresentation` utilisé par `TimelineRow`) → **extraire la struct** vers le fichier qui l'utilise ou vers un shared helper, puis supprimer le reste
4. Après suppressions, lance `xcodegen` pour régénérer le projet
5. Compile pour vérifier qu'aucune référence cassée ne subsiste

### SleepShells — remplacer par `.loopGlass()`

`Loop/Features/Today/Detail/Sleep/Components/SleepShells.swift` est **toujours utilisé** par `SleepRibbonCard.swift`, `SleepTonightPlanSection.swift`, `SleepInsightSection.swift`. Il contient :
- `SleepSection` (wrapper avec header + content) — **garder**
- `SleepSectionHeader` — **garder**
- `sleepCard(padding:)` modifier — **modifier pour utiliser `.loopGlass()` au lieu de `SleepGlassShell`**
- `SleepGlassShell` (private struct) — **supprimer**, remplacer par `.loopGlass()` ou `LoopGlassShell(accent:)`
- `SleepInsetShell` — **supprimer**, remplacer par `.loopGlass(cornerRadius: 14)`

Vérifie que les cards Sleep rendent correctement après le remplacement (les previews dans chaque fichier).

### Résultat attendu tâche 1

- 9 fichiers supprimés de `Loop/Features/Today/Components/`
- `SleepShells.swift` nettoyé (plus de `SleepGlassShell` / `SleepInsetShell`, utilise `.loopGlass()`)
- Plus aucun glass shell privé dans le codebase (vérifier avec `grep -rn "struct.*GlassShell" Loop/ --include="*.swift"` → doit retourner uniquement `LoopGlassShell` dans `Loop/Shared/`)
- Build OK, previews OK

---

## Tâche 2 — Finir la traduction FR

### Strings EN restantes

Après suppression des composants morts (tâche 1), la plupart des strings EN disparaissent avec eux. Vérifier néanmoins dans tout `Loop/Features/` et `Loop/Core/` s'il reste des chaînes user-facing en anglais :

```bash
grep -rn '"[A-Z][a-z]* [A-Z][a-z]*"' Loop/Features Loop/Core --include="*.swift" | grep -v '//\|///\|case\|let\|var\|func\|enum\|struct\|import\|Preview\|preview'
```

Cas connus à vérifier :
- `ActivityTimeline.swift:182` `Text("Timeline")` — doit disparaître avec la suppression du fichier
- `CoachCard.swift` #Preview (lignes 236-243) "Optimal Health" / "Prioritise Sleep" — doit disparaître avec la suppression du fichier
- Labels uppercase style WHOOP ("SLEEP", "RECOVERY", "STRAIN", "DAY STRAIN", "RECOVERY") dans les Hero cards des pages détail — **garder en EN** (style WHOOP intentionnel, ce sont des labels courts uppercase, pas des phrases)
- Noms de commands BLE ("Set Alarm Time", etc.) dans `BLECommands.swift` — **garder en EN** (ce sont des labels techniques pour debug)

### Règle

- Traduire en FR : phrases complètes, headlines, captions, messages coach, boutons, labels de sections
- Garder en EN : labels uppercase courts style WHOOP (SLEEP, RECOVERY, STRAIN, STRESS, TIMELINE si < 1 mot), labels techniques debug, noms de commands BLE

---

## Tâche 3 — Deep-links (`loop://` URL scheme)

### Objectif

Permettre d'ouvrir l'app directement sur une page spécifique via une URL `loop://today`, `loop://device`, `loop://profile`, `loop://device/alarm`, `loop://device/advanced`, `loop://profile/backup`, `loop://profile/advanced`. Utile pour les futures notifications locales qui peuvent deep-linker vers la bonne page.

### Étapes

1. **Déclarer le URL scheme dans `project.yml`** (XcodeGen) :
   - Ajouter `CFBundleURLTypes` dans la config Info.plist de la target Loop
   - URL scheme : `loop`
   - Voir la structure `project.yml` existante pour le format (ou ajouter via `info.properties.CFBundleURLTypes`)

2. **Créer `Loop/App/AppRouter.swift`** :

```swift
import SwiftUI

/// Centralised deep-link router. Parses `loop://` URLs into `AppRoute` values
/// and drives the tab + navigation stack selection.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .today
    @Published var todayRoute: TodayRoute?
    @Published var deviceRoute: DeviceRoute?
    @Published var profileRoute: ProfileRoute?

    enum AppTab: String, CaseIterable {
        case today, device, profile
    }

    enum TodayRoute: Hashable {
        case sleep, recovery, strain, stress, heartRate
    }

    enum DeviceRoute: Hashable {
        case advanced, alarm
    }

    enum ProfileRoute: Hashable {
        case backup, advanced
    }

    /// Parse `loop://device/alarm` → tab=.device, deviceRoute=.alarm
    func handle(_ url: URL) {
        guard url.scheme == "loop" else { return }
        let host = url.host ?? ""
        let path = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "today":
            tab = .today
            if let first = path.first {
                switch first {
                case "sleep":      todayRoute = .sleep
                case "recovery":   todayRoute = .recovery
                case "strain":     todayRoute = .strain
                case "stress":     todayRoute = .stress
                case "heartrate":  todayRoute = .heartRate
                default: break
                }
            }
        case "device":
            tab = .device
            if let first = path.first {
                switch first {
                case "advanced": deviceRoute = .advanced
                case "alarm":    deviceRoute = .alarm
                default: break
                }
            }
        case "profile":
            tab = .profile
            if let first = path.first {
                switch first {
                case "backup":   profileRoute = .backup
                case "advanced": profileRoute = .advanced
                default: break
                }
            }
        default: break
        }
    }
}
```

**Note** : vérifier les enums `TodayRoute`, `DeviceRoute`, `ProfileRoute` **existants** dans le codebase. Si `TodayRoute` existe déjà (`Loop/Features/Today/TodayView.swift`), **étendre** l'existant plutôt que de redéfinir. Si `DeviceRoute` existe déjà (`Loop/Features/Device/DeviceView.swift`), idem. Si `ProfileRoute` existe déjà (`Loop/Features/Profile/ProfileView.swift`), idem. L'`AppRouter` doit référencer les mêmes types que les vues existantes pour que le binding `navigationDestination(item:)` fonctionne.

3. **Wire dans `LoopApp`** :
   - Ajouter `@StateObject private var router = AppRouter()`
   - Injecter `.environmentObject(router)` sur `MainTabView`
   - Ajouter `.onOpenURL { router.handle($0) }` sur le `WindowGroup`

4. **Wire dans `MainTabView`** :
   - Binder `router.tab` au `TabView(selection:)` :
     ```swift
     TabView(selection: $router.tab) {
         TodayView(...).tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(AppRouter.AppTab.today)
         DeviceView(...).tabItem { Label("Appareil", systemImage: "applewatch") }.tag(AppRouter.AppTab.device)
         ProfileView(...).tabItem { Label("Profil", systemImage: "person.crop.circle.fill") }.tag(AppRouter.AppTab.profile)
     }
     ```

5. **Wire les `navigationDestination` vers les routes du router** :
   - `TodayView` : binder `$router.todayRoute` au `navigationDestination` existant (au lieu du `@State selectedDay` local si pertinent — mais attention à ne pas casser la navigation par jour existante, il faut juste que le router puisse PUSH une destination)
   - `DeviceView` : binder `$router.deviceRoute` au `navigationDestination(item:)` existant
   - `ProfileView` : binder `$router.profileRoute` au `navigationDestination(item:)` existant

   **Approche recommandée** : ne pas casser les `@State` locaux existants. À la place, observer `router.*Route` dans un `onChange` qui push la valeur dans le binding local existant :
   ```swift
   .onChange(of: router.deviceRoute) { _, newRoute in
       advancedRoute = newRoute  // advancedRoute est le @State existant
   }
   ```

6. **Test** : `xcodebuild` + test manuel (ouvrir `loop://device/alarm` depuis Safari ou `xcrun simctl openurl booted loop://device/alarm`)

---

## Tâche 4 — Sync toast (root overlay)

### Objectif

Un overlay global en haut de l'écran qui apparaît pendant la sync bracelet, montrant l'état en cours, puis disparaît avec un état "synchronisé" ou "erreur". Remplace le pill textuel actuel dans `TodayHeader` par un signal plus visible disponible sur tous les tabs.

### Inspiration

Goose `RootView.swift` `SyncToastHost` : syncing/synced/failed phases avec icône rotative + message. Mais Loop utilise son propre design language (monochrome glass, pas de couleur). 

### Étapes

1. **Créer `Loop/Shared/SyncToast.swift`** :

```swift
import SwiftUI

/// Root-level sync status overlay. Appears briefly when sync status changes,
/// shows the current state, auto-dismisses on success/idle.
struct SyncToast: View {
    let status: SyncStatus
    let isPresented: Bool

    private var display: SyncToastDisplay {
        switch status {
        case .syncing(.fromStrap):
            return SyncToastDisplay(
                symbol: "arrow.triangle.2.circlepath",
                text: "Synchronisation du bracelet…",
                isActive: true
            )
        case .strapStuck:
            return SyncToastDisplay(
                symbol: "exclamationmark.triangle.fill",
                text: "Bracelet bloqué — redémarre-le",
                isActive: false
            )
        case .error(let msg):
            return SyncToastDisplay(
                symbol: "exclamationmark.triangle.fill",
                text: msg,
                isActive: false
            )
        case .offline, .connectedIdle:
            return SyncToastDisplay(
                symbol: "checkmark.circle.fill",
                text: "À jour",
                isActive: false
            )
        }
    }

    var body: some View {
        if isPresented {
            HStack(spacing: 10) {
                if display.isActive {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: display.symbol)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(display.text)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .loopGlass(cornerRadius: 20)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct SyncToastDisplay {
    let symbol: String
    let text: String
    let isActive: Bool
}
```

2. **Créer un controller pour la logique de présentation** `SyncToastCoordinator` (ou intégrer dans `AppRouter` / un nouveau `@StateObject`) :

Logique :
- Observe `SyncCoordinator.$status`
- Quand le statut passe à `.syncing` → `isPresented = true`
- Quand le statut passe à `.connectedIdle` ou `.offline` (après un syncing) → `isPresented = true` pendant 2 secondes puis `isPresented = false`
- Quand le statut passe à `.error` ou `.strapStuck` → `isPresented = true` pendant 4 secondes puis `isPresented = false`

```swift
@MainActor
final class SyncToastCoordinator: ObservableObject {
    @Published var isPresented = false
    private var dismissTask: Task<Void, Never>?
    private var lastStatus: SyncStatus = .offline

    func observe(_ coordinator: SyncCoordinator) {
        // utiliser Combine ou onChange
    }
}
```

3. **Wire dans `MainTabView`** (ou `LoopApp`) :

Placer le toast en overlay au-dessus du `TabView`, aligné en haut :

```swift
ZStack(alignment: .top) {
    TabView(selection: $router.tab) { ... }
    
    SyncToast(status: coordinator.status, isPresented: toastCoordinator.isPresented)
        .padding(.top, 8)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastCoordinator.isPresented)
}
```

4. **Ne PAS supprimer le pill dans `TodayHeader`** — le toast est complémentaire (le pill reste sur Today pour la fraîcheur, le toast apparaît sur tous les tabs pendant les transitions de sync).

### Résultat attendu tâche 4

- Le toast apparaît en haut de n'importe quel tab quand la sync démarre
- Il montre "Synchronisation du bracelet…" avec un spinner pendant la sync
- Il montre "À jour" brièvement (2s) après la sync
- Il montre les erreurs pendant 4s
- Animation smooth (move from top + opacity)
- Build OK, preview OK

---

## Ordre d'implémentation

1. **Tâche 1** (suppression + fusion shells) — c'est le prérequis pour la tâche 2 (les strings EN disparaissent avec les fichiers)
2. **Tâche 2** (traduction FR) — vérifier ce qu'il reste après la tâche 1
3. **Tâche 3** (deep-links) — indépendant
4. **Tâche 4** (sync toast) — indépendant
5. `xcodegen` + compile + tests

## Vérification finale

```bash
# 1. Plus aucun glass shell privé
grep -rn "struct.*GlassShell" Loop/ --include="*.swift" | grep -v "LoopGlassShell"
# Doit retourner 0 résultats

# 2. Plus de composants morts
ls Loop/Features/Today/Components/ 2>/dev/null
# Doit retourner "No such file or directory" ou être vide

# 3. Pas de strings EN user-facing (hors labels uppercase style WHOOP et debug)
grep -rn '"[A-Z][a-z]* [A-Z][a-z]*"' Loop/Features --include="*.swift" | grep -v '//\|///\|case\|let\|var\|func\|enum\|struct\|import\|Preview\|preview\|SLEEP\|RECOVERY\|STRAIN\|STRESS\|DAY'

# 4. URL scheme déclaré
grep -n "loop" project.yml | grep -i url
# ou vérifier dans Info.plist généré

# 5. Build
xcodegen generate
xcodebuild -scheme Loop -destination 'platform=iOS Simulator,name=iPhone 16' build

# 6. Deep-link test
xcrun simctl openurl booted loop://device/alarm
```

## Critères d'acceptation

- [ ] 9 fichiers supprimés de `Loop/Features/Today/Components/` (ou vérifié que chaque struct est truly dead)
- [ ] `SleepShells.swift` utilise `.loopGlass()` au lieu de `SleepGlassShell`/`SleepInsetShell`
- [ ] `grep "struct.*GlassShell" Loop/` ne retourne que `LoopGlassShell` dans `Loop/Shared/`
- [ ] Aucune string EN user-facing dans les vues (hors labels uppercase style WHOOP + debug technique)
- [ ] `loop://today`, `loop://device`, `loop://profile`, `loop://device/alarm`, `loop://device/advanced`, `loop://profile/backup`, `loop://profile/advanced` ouvrent la bonne page
- [ ] Le sync toast apparaît pendant la sync sur n'importe quel tab
- [ ] Build OK sans warnings SwiftUI iOS 17+
- [ ] `xcodegen` régénère le projet correctement
- [ ] Aucun commentaire évident, conventions Loop respectées
