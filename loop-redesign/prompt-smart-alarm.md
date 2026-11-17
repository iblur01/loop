# Prompt — Implémentation Smart Alarm 2-couches

> Prompt à donner à un agent IA (Claude Code, Cursor, etc.) pour implémenter la feature "Smart alarm 2-couches" dans Loop. L'agent doit charger les skills SwiftUI avant de commencer.

---

## PROMPT

Tu vas implémenter la feature **Smart Alarm 2-couches** dans l'app iOS Loop (Swift/SwiftUI, iOS 17+, offline-first, WHOOP 4.0).

### Avant de commencer

Charge les skills suivants depuis `.agents/skills/` pour t'assurer de suivre les bonnes pratiques SwiftUI :
- `swift-ui` (patterns SwiftUI)
- `swiftui-expert-skill` (state management, `@Observable`, `@EnvironmentObject`, performance)
- `swiftui-ui-patterns` (navigation, custom view modifiers, list/tab architecture)
- `swift-concurrency-expert` (`@MainActor`, `Sendable`, async/await, `Task`)

### Contexte projet

- Repo : `/Users/theo/dev/whoop/loop`
- Architecture : `LoopApp` → `MainTabView` (3 tabs : Today / Device / Profile)
- Source de données : `LoopDataRepository.cache` (`LoopCache`) + `DeviceConnectionViewModel.state` (`BLEDeviceState`)
- BLE : `BLEConnectionManager.send(_:payload:writeType:)` prend un `WhoopCommand` (déjà défini dans `Loop/Core/BLE/BLECommands.swift`)
- Préférences : `UserPreferences.shared` (`@MainActor ObservableObject`, UserDefaults, déjà existant — `Loop/Core/Preferences/UserPreferences.swift`)
- Glass shell partagé : `View.loopGlass(cornerRadius:)` (`Loop/Shared/LoopGlass.swift`)
- Conventions de code : 4 espaces, PascalCase pour types, lowerCamelCase pour functions, `// MARK: -` pour sections, commentaires pourquoi avant comment, `final class` pour classes, `@MainActor` pour UI, `@Published` sur les propriétés publiques d'`ObservableObject`. **AUCUN commentaire sur du code évident.**

### Spécification fonctionnelle

**Alarme répétitive multi-jours** : l'utilisateur règle une heure de réveil + quels jours de la semaine répéter (lun/mar/mer/jeu/ven/sam/dim), un mode (Off / Régulier / Intelligent), et un pattern haptic. L'alarme se ré-arme automatiquement pour le prochain jour actif.

**2 couches** :
1. **Firmware RTC alarm** (garantie) : commande `SET_ALARM_TIME=66` — le bracelet vibre même si l'app est tuée / téléphone verrouillé. Toujours envoyée en plus du smart-wake.
2. **Smart-wake overlay** (best-effort) : fenêtre `leadMinutes` (5-30 min, défaut 15) avant l'heure cible. L'app entre `ENTER_HIGH_FREQ_SYNC=96` pour récupérer un flux HR dense, détecte un "near-wake" (HR rise ≥5 bpm sur la fenêtre), déclenche l'alarme tôt. **Invariant critique** : `EXIT_HIGH_FREQ_SYNC=97` doit être envoyé sur TOUS les chemins de sortie (success, cancel, error, app background) — sinon le bracelet reste en mode high-freq et draine la batterie.

**Modes** :
- `off` : alarme désactivée, rien n'est envoyé au bracelet
- `regular` : firmware RTC uniquement, pas de smart-wake
- `smart` : firmware RTC + smart-wake overlay (les 2)

**Pattern haptic** : 4 patterns (Progressive / Doux / Moyen / Intense) mappés sur les patternId du bracelet (0-7). Par défaut id=2 (medium, le même que l'app officielle WHOOP). Bouton "Tester" envoie `RUN_ALARM=68` + `runHapticsPattern(patternId=2, loops=3)`.

**Persistance** :
- Config alarme dans `UserPreferences` (UserDefaults) : `alarmEnabled: Bool`, `alarmHour: Int`, `alarmMinute: Int`, `alarmWeekdays: Set<Int>` (1=dim...7=sam selon `Calendar`), `alarmMode: AlarmMode`, `alarmLeadMinutes: Int`, `alarmHapticPattern: Int`
- L'alarme armée courante (prochain déclenchement) est calculée depuis la config + `Calendar.current`

**Pages à créer/modifier** :

#### 1. Nouvelle sous-page Device : `AlarmView` (configuration)

Lieu : `Loop/Features/Device/Components/AlarmView.swift` (nouveau fichier)
Accès : nouvelle `DeviceRoute.alarm` → `NavigationLink` depuis `DeviceView` (ajoute un `DeviceDetailsRow` "Réveil" après la row battery, ou dans `DeviceInfoGroup`)

Contenu :
- **Header** : "Réveil" + icône `alarm.fill` + statut court ("Active · 07:00 · lun–ven" / "Désactivé")
- **Toggle enabled** : active/désactive l'alarme
- **Time picker** : `DatePicker` wheel mode, `.hourAndMinute` uniquement
- **Répétition** : 7 chips pour les jours de la semaine (L M M J V S D). Tap pour toggle. Si aucun jour sélectionné → alarme one-shot (prochaine occurrence seulement)
- **Mode picker** : segmented control "Régulier" / "Intelligent" (si smart désactivé, griser l'option + footer "Le mode intelligent utilise un flux HR dense pendant la fenêtre de réveil")
- **Lead time slider** (visible seulement en mode smart) : 5-30 min, step 5, label "Fenêtre de réveil : X min avant"
- **Haptic pattern picker** : 4 options en carousel ou liste (Progressive/Doux/Moyen/Intense) → mappé vers les patternId du bracelet
- **Bouton "Tester la vibration"** : envoie `RUN_ALARM=68` (si bracelet connecté) + `runHapticsPattern` avec le pattern sélectionné, loops=3
- **Bouton "Désactiver sur le bracelet"** : envoie `DISABLE_ALARM=69` (si connecté)
- **Footer informatif** : "L'alarme vibre sur le bracelet même si l'iPhone est éteint ou l'app fermée. Le mode intelligent tente de te réveiller pendant une phase de sommeil léger jusqu'à X min avant l'heure."
- **État de connection** : si bracelet non connecté, désactiver les boutons "Tester" et "Désactiver sur le bracelet", afficher "Bracelet non connecté — tes réglages seront appliqués à la prochaine connexion."

#### 2. Nouveau composant Today : `AlarmWidget` (card quand alarme active)

Lieu : `Loop/Features/Today/Widgets/AlarmWidget.swift` (nouveau fichier)
Ajouter `case alarm` dans `TodayWidgetID` (`Loop/Features/Today/Model/TodayContext.swift`)
Ajouter dans `TodayContext.widgets` : si `alarmEnabled`, insérer `.alarm` en haut (avant `.deviceAlert` si batterie critique, sinon après `.deviceAlert`)

Contenu :
- `WidgetLabel(symbol: "alarm.fill", title: "Réveil", trailing: alarmTimeText)` 
- `WidgetMetric(value: alarmTime, unit: nil)` (ex: "07:00")
- Caption : jours actifs résumés ("Lun–Ven" / "Tous les jours" / "Lun, Mer, Ven") + mode ("Intelligent · 15 min" / "Régulier")
- Tap → `NavigationLink` vers `DeviceRoute.alarm` (ouvre la page config dans le tab Device — utiliser un `TodayRoute.alarm` ou `NavigationLink(value: DeviceRoute.alarm)`)

#### 3. Modèle : `AlarmMode` enum

Lieu : `Loop/Core/Preferences/AlarmMode.swift` (nouveau fichier) ou extension de `UserPreferences`

```swift
enum AlarmMode: String, CaseIterable, Codable {
    case off
    case regular
    case smart

    var label: String {
        switch self {
        case .off:      return "Désactivé"
        case .regular:  return "Régulier"
        case .smart:    return "Intelligent"
        }
    }
}
```

#### 4. Controller : `SmartAlarmController`

Lieu : `Loop/Core/Alarm/SmartAlarmController.swift` (nouveau fichier)

`@MainActor final class SmartAlarmController: ObservableObject`

Responsabilités :
- `@Published var isArmed: Bool` (calculé depuis `UserPreferences.alarmEnabled` + présence d'un prochain déclenchement)
- `@Published var nextFireDate: Date?` (prochain déclenchement calculé)
- `func arm(using connection: DeviceConnectionViewModel)` : 
  1. Calcule la prochaine date de déclenchement (next weekday actif à l'heure cible)
  2. Envoie `SET_CLOCK=10` (UTC correct, requis avant SET_ALARM_TIME — cf. commentaire `BLECommands.swift:48`)
  3. Envoie `SET_ALARM_TIME=66` avec `WhoopCommand.setAlarmPayload(epochSec:)` (epoch u32 LE)
  4. Si mode == `.smart`, planifie un `Task` qui à `nextFireDate - leadMinutes` :
     - entre `ENTER_HIGH_FREQ_SYNC=96` (payload `[0x01]`)
     - observe les samples HR (peut écouter `connection.state.heartRate` ou `connection.bleManager` via publisher)
     - si HR rise ≥5 bpm sur la fenêtre → envoie `RUN_ALARM=68` + sort
     - à `nextFireDate` (timeout) → sort (le firmware RTC prend le relais)
     - **sur tous les chemins de sortie** : envoie `EXIT_HIGH_FREQ_SYNC=97` (payload `[0x00]`)
- `func disarm(using connection: DeviceConnectionViewModel)` : envoie `DISABLE_ALARM=69` + cancel le `Task` smart-wake + `EXIT_HIGH_FREQ_SYNC=97` (defensive)
- `func rearmIfNeeded(using connection: DeviceConnectionViewModel)` : appelé après un fire ou au foreground — si alarm activée et `nextFireDate` est dans le passé, calcule la nouvelle prochaine date et ré-arme
- `func testBuzz(using connection: DeviceConnectionViewModel, patternId: Int)` : envoie `RUN_ALARM=68` + `runHapticsPattern` (payload `[patternId, 3, 0, 0, 0]`)
- `func computeNextFireDate(from prefs: UserPreferences, now: Date = Date()) -> Date?` : pure, testable — prend l'heure + weekdays, retourne la prochaine Date

**Pure helper** (peut être dans le même fichier ou un `AlarmScheduler.swift`) :
```swift
enum AlarmScheduler {
    /// Prochaine Date de déclenchement étant donné l'heure cible + jours actifs.
    /// `weekdays` : indices Calendar 1..7 (1=dim, 7=sam). Si vide → one-shot (prochaine occurrence).
    static func nextFireDate(hour: Int, minute: Int, weekdays: Set<Int>, from now: Date = Date()) -> Date?
}
```

#### 5. Wire dans `BLEConnectionManager` ou `DeviceConnectionViewModel`

- À la connexion (après handshake), appeler `alarmController.rearmIfNeeded(using: connection)` — pour ré-armée l'alarme firmware si elle a été perdue (redémarrage bracelet, etc.)
- Au foreground (`enterForeground()` dans `DeviceConnectionViewModel`), idem
- Observer `UserPreferences.alarmEnabled` / `alarmHour` / etc. : quand ça change, `rearmIfNeeded`

#### 6. Passage de `SmartAlarmController` aux vues

- Ajouter `@StateObject private var alarmController = SmartAlarmController()` dans `LoopApp` (comme `repository`, `connection`, `backup`)
- Injecter via `.environmentObject(alarmController)` sur `MainTabView`
- `AlarmView` et `AlarmWidget` le consomment en `@EnvironmentObject`
- `UserPreferences.shared` est déjà un singleton accessible directement

### Contraintes techniques

1. **Sécurité BLE** : `EXIT_HIGH_FREQ_SYNC=97` sur TOUS les chemins (success/cancel/error/background). Utiliser `defer` dans le `Task` smart-wake ou un wrapper qui garantit l'exit.
2. **`SET_CLOCK=10` avant `SET_ALARM_TIME=66`** : sinon le bracelet RTC peut être désynchronisé et l'alarme fire au mauvais moment. Commentaire déjà dans `BLECommands.swift:48`.
3. **`@MainActor`** sur `SmartAlarmController` (UI-binding) ; les `Task` BLE peuvent être `detached` mais repassent en main pour les `@Published`.
4. **Pas de UNUserNotificationCenter** dans ce ticket — l'alarme vibre sur le bracelet, pas de notif iOS (ce sera un autre ticket pour les notifications locales battery/recovery).
5. **Tests** : écrire `LoopTests/SmartAlarmControllerTests.swift` testant `AlarmScheduler.nextFireDate` (pure, sans BLE). Cas : weekdays vides (one-shot), weekdays lun-ven, weekday uniquement dim, heure déjà passée aujourd'hui, heure dans le futur aujourd'hui, weekday demain.
6. **Preview SwiftUI** : chaque nouveau composant doit avoir un `#Preview` couvrant les états clés (alarm off / regular / smart, connected / disconnected).
7. **Pas de commentaires évidents**. Commenter seulement les invariants (smart-wake exit, set-clock-before-alarm) et le pourquoi des choix.
8. **Glass shell** : utiliser `.loopGlass(cornerRadius: 26)` existant — NE PAS créer un nouveau shell.
9. **Langue** : tout en français (labels, captions, headers).
10. **XcodeGen** : après ajout de nouveaux fichiers, lance `xcodegen` pour régénérer le projet (le `project.yml` est à la racine). Vérifie que les nouveaux fichiers sont bien dans `Loop/` ou `LoopTests/` sources.

### Fichiers à créer

- `Loop/Core/Alarm/AlarmScheduler.swift` (pure helper)
- `Loop/Core/Alarm/SmartAlarmController.swift` (`@MainActor ObservableObject`)
- `Loop/Core/Preferences/AlarmMode.swift` (enum + haptic patterns)
- `Loop/Features/Device/Components/AlarmView.swift` (page config)
- `Loop/Features/Today/Widgets/AlarmWidget.swift` (Today card)
- `LoopTests/SmartAlarmControllerTests.swift` (tests `AlarmScheduler`)

### Fichiers à modifier

- `Loop/Core/Preferences/UserPreferences.swift` — ajouter `alarmEnabled`, `alarmHour`, `alarmMinute`, `alarmWeekdays`, `alarmMode`, `alarmLeadMinutes`, `alarmHapticPattern` (avec `@Published` + `didSet` qui persist dans UserDefaults, comme `strainDifficulty`). Ajouter dans `resetOnboarding()` pour réinitialiser.
- `Loop/Features/Device/DeviceView.swift` — ajouter `case alarm` à `DeviceRoute`, ajouter le `DeviceDetailsRow` "Réveil" dans `connectedLayout` (entre battery et info group), ajouter la destination dans `navigationDestination`
- `Loop/Features/Today/Model/TodayContext.swift` — ajouter `case alarm` à `TodayWidgetID`, ajouter `alarmEnabled: Bool` au struct `TodayContext`, insérer `.alarm` dans `widgets` (en haut, après `.deviceAlert` si batterie critique)
- `Loop/Features/Today/TodayView.swift` — passer `alarmEnabled: prefs.alarmEnabled` au `TodayContext`, ajouter la case dans `TodayWidgetStack.widget(for:)` pour rendre `AlarmWidget`
- `Loop/Features/Today/Widgets/TodayWidgetStack.swift` — ajouter le case `alarm` qui rend `AlarmWidget(prefs: prefs)` (en `@ObservedObject` sur `UserPreferences.shared`)
- `Loop/App/LoopApp.swift` — créer `@StateObject private var alarmController = SmartAlarmController()` + `.environmentObject(alarmController)`, appeler `alarmController.rearmIfNeeded(using: connection)` dans `.task` après le bootstrap
- `Loop/Core/Device/DeviceConnectionViewModel.swift` — appeler `alarmController.rearmIfNeeded` dans `enterForeground()` (peut accepter un `SmartAlarmController?` optionnel ou utiliser un protocol — préfère injecter via init avec weak ref, ou observer les changements de prefs côté controller directement)

### Vérification finale

Avant de terminer, l'agent doit :
1. Lancer `xcodegen` (ou `xcodegen generate` si installé) pour régénérer `Loop.xcodeproj`
2. Compiler avec `xcodebuild -scheme Loop -destination 'platform=iOS Simulator,name=iPhone 16'` (ou juste vérifier que le projet build dans Xcode)
3. Lancer les tests : `xcodebuild test -scheme Loop -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LoopTests/SmartAlarmControllerTests`
4. Vérifier que les previews `AlarmView` et `AlarmWidget` compilent et rendent correctement
5. Vérifier que `EXIT_HIGH_FREQ_SYNC=97` est bien envoyé sur tous les chemins de sortie du smart-wake (relecture du `SmartAlarmController`)

### Inspiration externe (référence, ne PAS copier aveuglément — adapter aux conventions Loop)

- `my-whoop` (legacy iOS, git history) : `Alarm/SmartAlarmController.swift` + `Alarm/AlarmView.swift` + `BLE/Commands.swift` `setAlarmPayload`. Logique pure du smart-wake HR heuristic testable.
- `goose` (iOS alpha) : `HealthSleepSheetsViews.swift:223` `SleepV2AlarmSheet` (4 modes + pattern picker) + `GooseBLEClient+UserActions.swift:372` (commands query/set/run/disable alarm)
- `openwhoop-gen4-debug` (Rust) : `src/openwhoop-codec/src/packet_implementations.rs:203-230` `alarm_time()` (Gen4 payload `[rev=0x01]+epoch u32 LE+[0x00×4]` — **les 4 padding bytes sont inconnus**, potentiellement smart-wake window, ne pas tenter de les deviner, laisser à 0)
- Voir `loop/loop-redesign/05-inventaire-depots-externes.md` §1 Smart Alarm pour le détail feature-par-feature.

### Payloads BLE exacts (déjà dans `BLECommands.swift`)

```swift
// SET_ALARM_TIME (66) — Rev1 form, verified on Gen4
WhoopCommand.setAlarmTime.frame(seq: seq, payload: WhoopCommand.setAlarmPayload(epochSec: UInt32(fireDate.timeIntervalSince1970)))

// GET_ALARM_TIME (67) — read current armed alarm
WhoopCommand.getAlarmTime.frame(seq: seq, payload: [0x01])

// RUN_ALARM (68) — immediate buzz
WhoopCommand.runAlarm.frame(seq: seq, payload: [0x01])

// DISABLE_ALARM (69) — disarm
WhoopCommand.disableAlarm.frame(seq: seq, payload: [0x01])

// ENTER_HIGH_FREQ_SYNC (96) — dense HR for smart-wake window
WhoopCommand.enterHighFreqSync.frame(seq: seq, payload: [0x01])

// EXIT_HIGH_FREQ_SYNC (97) — MUST be sent on every exit path
WhoopCommand.exitHighFreqSync.frame(seq: seq, payload: [0x00])

// RUN_HAPTICS_PATTERN (79) — pattern test
WhoopCommand.runHapticsPattern.frame(seq: seq, payload: [UInt8(patternId), 3, 0, 0, 0])

// SET_CLOCK (10) — send BEFORE SET_ALARM_TIME
WhoopCommand.setClock.frame(seq: seq, payload: clockPayload)  // voir usage existant dans BLEConnectionManager
```

### Ordre d'implémentation recommandé

1. `AlarmMode.swift` + extension `UserPreferences` (persistence) — base
2. `AlarmScheduler.swift` (pure) + tests — pour valider la logique de next-fire-date
3. `SmartAlarmController.swift` (state + arm/disarm/testBuzz) — relier à BLE
4. `AlarmView.swift` (page config Device) — UI
5. `AlarmWidget.swift` + wire `TodayContext`/`TodayWidgetStack` — UI Today
6. Wire `LoopApp` (environmentObject) + `DeviceConnectionViewModel` (rearm on connect/foreground)
7. `xcodegen` + compile + tests
8. Relecture safety : `EXIT_HIGH_FREQ_SYNC` sur tous les chemins

### Critères d'acceptation

- [ ] L'alarme se règle (heure + jours + mode + pattern) et se persiste à travers les lancements
- [ ] Au arm, `SET_CLOCK` puis `SET_ALARM_TIME` sont envoyés au bracelet (visible dans les logs BLE de DeviceAdvancedView)
- [ ] En mode smart, `ENTER_HIGH_FREQ_SYNC` est envoyé à `fireDate - leadMinutes`, et `EXIT_HIGH_FREQ_SYNC` est envoyé sur tous les chemins de sortie (success, timeout, cancel, error)
- [ ] "Tester" déclenche un buzz immédiat sur le bracelet
- [ ] "Désactiver sur le bracelet" envoie `DISABLE_ALARM`
- [ ] Une card "Réveil" apparaît sur Today quand l'alarme est activée, avec l'heure + jours + mode
- [ ] Tap sur la card Today → navigue vers `AlarmView` (dans le tab Device)
- [ ] Au foreground / connect, `rearmIfNeeded` recalcule la prochaine alarme si la précédente est passée
- [ ] Tests `AlarmScheduler` passent (cas : weekdays vides, lun-ven, dim seul, heure passée, heure future, jour demain)
- [ ] Previews `AlarmView` (off/regular/smart, connected/disconnected) et `AlarmWidget` compilent
- [ ] Code build sans warnings SwiftUI/iOS 17+
- [ ] Aucun commentaire évident, conventions Loop respectées

---

Fin du prompt.
