# Audit produit — Rappel médicament intelligent pour Loop

Cet audit est grounding dans l'architecture réelle de Loop (moteur `LoopStrapEngine`, store GRDB `whoop.sqlite` schema v5, `LocalMetricsEngine`, `SmartAlarmController`, Live Activity battery, couche Reference HealthKit). La conclusion courte en bas : **construire d'abord un rappel déterministe à fenêtre + confirmation + Live Activity + historique local, n'ajouter la « smart-timing » WHOOP qu'en Phase 2, et garder le LLM strictement hors du médical.**

Une convention de balisage utilisée tout au long :

- `[DÉTERMINISTE]` = doit être du code pur, testable, jamais du LLM.
- `[LLM]` = peut être assisté par un LLM local (Apple Intelligence / `FoundationModels`), jamais seul pour une décision médicale.
- `[WHOOP]` = dépend des données du bracelet.
- `[SANS BRACELET]` = doit fonctionner même si WHOOP est absent (garde-fou obligatoire).
- `[DANGER MÉDICAL]` = limite à ne jamais franchir.

---

## 0. Constat de départ (ce qui existe déjà et change la donne)

Trois choses existent déjà dans Loop et accélèrent nettement le projet :

1. **Un précédent de « smart-timing » éprouvé : `SmartAlarmController`** (`Loop/Core/Alarm/SmartAlarmController.swift:15`). C'est un 2-couches : (a) RTC firmware = déclencheur garanti même app tuée, (b) fenêtre « lead » qui observe le HR live et déclenche tôt si HR monte. Exactement la forme qu'un rappel intelligent doit prendre, mais côté `UNNotification` au lieu du bracelet.
2. **Une Live Activity locale sans APNs** : `BraceletBatteryLiveActivityController` (`Loop/Core/LiveActivity/BraceletBatteryLiveActivityController.swift:5`) avec `pushType: nil` — pattern copiable pour une Live Activity « prochaine dose ».
3. **La permission notification déjà demandée à l'onboarding** (`OnboardingView.swift:98`) mais **jamais utilisée** : aucun `UNNotificationRequest`, aucun delegate. Donc on part de zéro sur le scheduling, mais on ne reprompt pas les utilisateurs existants.

Et trois choses qui manquent et qu'il faut admettre d'emblée :

1. **Aucun détecteur « endormi maintenant » en temps réel.** Le sommeil n'est calculé que rétrospectivement, par jour, dans `LocalMetricsEngine.computeCore`. Le seul signal physio temps réel est `state.heartRate` (HR live). Un rappel « ne pas réveiller quelqu'un qui dort » doit donc soit réutiliser l'heuristique HR-rise du smart alarm, soit s'appuyer sur le `sleepEnd` du dernier `DailySnapshot` + un cache « dernier état de sommeil connu ».
2. **Aucun modèle domaine médicament.** Ni dans `UserPreferences`, ni dans `whoop.sqlite` (schema v5 n'a que la physio). À créer.
3. **`UserProfile` (âge/poids/taille/sexe) toujours `nil`** (`LocalMetricsEngine.swift:459`). Inutile pour un rappel simple, mais à savoir si on veut un jour de la posologie-dependant (hors scope MVP).

---

## 1. Détection du bon moment pour rappeler

### Principe directeur

Un rappel à heure fixe échoue parce qu'il est **décorrélé de l'état réel**. La bonne unité n'est pas « 8h00 » mais **une fenêtre temporelle bornée + un déclencheur contextuel**. On sépare toujours :

- **La fenêtre autorisée** (`DoseWindow`) : ex. matin = [réveil+10 min, réveil+2h], midi = [11h30, 14h30], soir = [18h00, coucher−30 min]. `[DÉTERMINISTE]`
- **Le déclencheur** (`DoseReminderEngine`) : dans la fenêtre, attendre une condition de disponibilité, puis notifier. `[DÉTERMINISTE]` avec signaux `[WHOOP]` optionnels.

### Signaux utilisables et leur fiabilité

| Signal | Source | Fiable ? | Usage recommandé |
|---|---|---|---|
| `sleepEnd` (heure de réveil estimée) | `DailySnapshot.sleepEnd` via `SleepEngine` | **Fiable** après calcul rétroactif (dispo ~quelques min après lever) | Ancre la fenêtre du matin `[WHOOP]` |
| HR live en hausse | `state.heartRate` | **Fragile** (bruit, mouvement) | Heuristique de « probable réveillé » comme dans `SmartAlarmController` `[WHOOP]` |
| Mouvement (gravity stream) | `gravitySample` | **Fiable** pour « en mouvement / debout », bruité pour « disponible » | Garder « actif récemment », pas « disponible » |
| `recoveryBand` (red/yellow/green) | `DailySnapshot.recoveryBand` | **Fiable** mais c'est un état de la veille passée, pas un moment | Contexte, pas trigger. Jamais « recovery rouge → reporter le médicament » `[DANGER MÉDICAL]` |
| `strain` courant | `DailySnapshot.strain` | Rétrospectif par jour | Inutile pour le timing intraday |
| Steps / stand time | HealthKit (`ReferenceMetric.stepCount`, `appleStandTime`) | **Fiable** si Apple Watch | Signal de « levé / en mouvement » `[SANS BRACELET]` |
| `sleepAnalysis` HealthKit | `ReferenceMetric.sleepAnalysis` | **Fiable** mais latence (HK pousse après détection) | Backup « endormi ? » si WHOOP absent |
| Calendrier / localisation | EventKit / CoreLocation | **Fiable** si consentement | Optionnel, Phase 3 |

### Règles concrètes (déterministes)

1. **Ne jamais notifier pendant une période de sommeil connue.** Si `sleepEnd` du jour courant est nul (encore en sommeil selon le dernier session), on retient. `[DÉTERMINISTE]`
2. **Pas de rappel avant `réveil + délaiMin`** (défaut 10 min, appris). Évite le rappel au réveil brutal. `[DÉTERMINISTE]`
3. **Fenêtre du midi ancrée sur l'horloge** (pas le bracelet) : 11h30–14h30 par défaut, décalable par habitude. `[SANS BRACELET]`
4. **Fenêtre du soir ancrée sur `coucher estimé − marge`** : utiliser `UserPreferences.sleepTargetMin` + heure de coucher habituelle (apprise) pour borner. `[DÉTERMINISTE]` avec habitude `[WHOOP]` optionnelle.
5. **Jours différents** : un flag par jour `weekdayMask` + un mode `routine: standard | deplacement | repos` que l'utilisateur peut déclarer manuellement (le système ne devine pas « tu voyages » sans contexte). `[DÉTERMINISTE]`
6. **Si le bracelet est absent**, fallback sur fenêtres horaires pures + `UserPreferences.wakeHour/wakeMinute`. `[SANS BRACELET]` — non-négociable.

### Ce qu'il ne faut PAS surinterpréter

- **Recovery/Strain pour décider du timing du médicament.** Un médicament n'est pas un effort physique ; la recovery n'indique pas « bon moment pour prendre ». `[DANGER MÉDICAL]`
- **HRV pour inférer « stress » et reporter.** L'HRV est bruitée intra-jour et n'a pas de sens clinique pour la prise d'un traitement. `[DANGER MÉDICAL]`
- **Déduire « l'utilisateur est disponible » du mouvement.** « En mouvement » ≠ « disponible pour prendre un médicament ». Le mouvement sert à *éviter* de notifier pendant le sommeil, pas à garantir l'attention.

---

## 2. Utilisation des données du bracelet

### Fiables (utilisables pour le timing)

- **`SleepEngine` → `SleepSession.start/end` + `stages`** (`SleepEngine.swift`). Le signal le plus solide pour : (a) ancrer la fenêtre du matin, (b) empêcher un rappel nocturne, (c) savoir « temps depuis le réveil ». `[WHOOP]`
- **HR live** via `state.heartRate` (`SmartAlarmController.swift:126`), pour l'heuristique « HR en hausse = probablement réveillé » dans une lead window. `[WHOOP]`
- **Gravity (accéléromètre)** pour « en mouvement / debout » dans les dernières minutes. `[WHOOP]`

### Fragiles (à utiliser avec prudence, jamais seules)

- **`recovery` / `recoveryBand`** : excellent pour du *coaching* (ex. « aujourd'hui tu es en recovery rouge, c'est normal d'être un peu flapi »), mais **jamais** pour modifier le timing ou la dose d'un médicament. `[DANGER MÉDICAL]`
- **`strain`** : rétrospectif par jour, inutile intraday.
- **Stress timeline** (`StressResult`) : bruitée par minute, à utiliser uniquement pour *éviter* une relance pendant un pic de stress aigu, jamais pour diagnostiquer.

### À ne pas surinterpréter

- **`skinTemp`, `SpO2`, `resp`** sont explicitement marquées « APPROXIMATE / UN-FITTED » dans `Units/SkinTemp.swift` etc. → **jamais pour une décision médicale**, tout au plus pour des insights non médicaux en Phase 3. `[DANGER MÉDICAL]`
- **HRV SDNN (Apple Watch)** vs **RMSSD (WHOOP)** : ce ne sont pas les mêmes métriques. La couche Reference (`ReferenceStore`) calcule déjà des résidus pour la *documentation de confiance*, pas pour modifier Loop.

### Ce que WHOOP **ne sait pas**

- Si l'utilisateur a son médicament avec lui.
- S'il est à table.
- S'il est au travail / en réunion / en déplacement.
- Ce qu'il prend comme médicament.

→ Ces infos viennent soit de l'utilisateur (bouton « je ne l'ai pas avec moi »), soit de sources optionnelles consenties (calendrier/localisation, Phase 3). **Ne jamais les deviner à partir du bracelet.**

---

## 3. Système de rappel progressif

### Principe

Pas d'escalade aggressive. On veut **augmenter doucement la probabilité de prise** sans créer d'anxiété. Trois états de reminder : `soft`, `visible`, `late`, puis `overdue` avec Live Activity persistante.

### États et transitions `[DÉTERMINISTE]`

```
[scheduled] --(entrée fenêtre + condition dispo)--> soft
soft        --(+12 min, non confirmé)-->            visible
visible     --(+20 min, non confirmé)-->            late
late        --(fenêtre toujours ouverte)-->         overdue (Live Activity persistante)
n'importe   --(confirmation prise)-->               taken (Live Activity → "pris", fin après 5 min)
n'importe   --(snooze)-->                            snoozed (reschedule dans [min..max])
n'importe   --(sortie de fenêtre)-->                missed (Live Activity "manqué", ~30 min puis fin)
```

### Caractéristiques par état

| État | Canal | Son | Texte | Fréquence |
|---|---|---|---|---|
| `soft` | notification + Live Activity « bientôt » | doux, court | « Ton [médoc] du matin est prêt quand tu veux. » | 1 fois |
| `visible` | notification + Live Activity « maintenant » | normal | « Petit rappel : [médoc] du matin. » | 1 fois |
| `late` | notification + Live Activity « en retard » | normal, pas alarmant | « Tu n'as pas encore pris [médoc]. Pas grave, c'est encore bon. » | 1 fois, + bouton snooze |
| `overdue` | Live Activity persistante seule | silencieux | (écran verrouillé : « [médoc] — pas encore pris ») | pas de notification répétée ; la Live Activity suffit |

### Snooze intelligent `[DÉTERMINISTE]`

- **Snooze « standard »** : +15 min (par défaut), borné par `window.end`.
- **Snooze « quand je serai actif »** : reschedule au prochain HR-rise dans la fenêtre, sinon à `window.end − 10 min`. `[WHOOP]` avec fallback `[SANS BRACELET]` = `window.end − 15 min`.
- **Snooze « ce soir »** (pour midi manqué) : déplace à la fenêtre du soir si elle existe pour ce médicament, sinon flag `missed` avec raison `reporte`.
- **Pas de snooze après `window.end`** : on bascule en `missed`/`late` selon config ; l'utilisateur peut toujours confirmer a posteriori.

### Anti-spam `[DÉTERMINISTE]`

- Maximum **3 notifications** par dose (`soft`, `visible`, `late`), jamais plus.
- Si l'utilisateur ignore les 3 → on **arrête de pousser**, on laisse uniquement la Live Activity. C'est plus respectueux que de harceler.
- Cooldown **5 min** minimum entre deux notifications d'une même dose.
- Si l'utilisateur est en sommeil connu (voir §10), **tout est suspendu** et repris au prochain état « réveillé » sans le recaler bruyamment.

### Pause automatique `[DÉTERMINISTE]` + `[WHOOP]`

- Si `sleepEnd` du jour est `nil` et qu'on est dans une plage habituelle de sommeil → on retient toutes les doses `soft/visible/late`.
- Si HR live < seuil bas (ex. < RHR − 3) pendant ≥ 10 min → présomption de sommeil/ repos profond → on retient (jamais de notification dans ce cas).

---

## 4. Live Activity

### Attributs (suivre le pattern `BraceletBatteryActivityAttributes`)

```swift
struct MedicationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let medicationName: String
        let doseLabel: String            // "1 comprimé"
        let moment: Moment               // .matin | .midi | .soir | custom
        let status: Status               // .dueSoon | .dueNow | .late | .taken | .missed
        let dueAt: Date                  // borne "à prendre maintenant"
        let windowEnd: Date
        let minutesUntilDue: Int?        // pour le compte à rebours
        let updatedAt: Date
    }
    enum Status: String, Codable, Hashable { case dueSoon, dueNow, late, taken, missed }
    enum Moment: String, Codable, Hashable { case matin, midi, soir, custom }
    let medicationId: UUID
}
```

`pushType: nil` (local uniquement, pas d'APNs — conforme au principe offline-first). Voir `BraceletBatteryLiveActivityController.swift:87`.

### États visuels (UX précise)

| Statut | Lock screen | Dynamic Island (compact) | Dynamic Island (expanded) |
|---|---|---|---|
| `dueSoon` | Carte sobre, icône pilule, « [médoc] • bientôt », compte à rebours discret | Picto pilule + « 12 min » | Nom + dose + boutons |
| `dueNow` | « À prendre maintenant » + 2 boutons (« Pris », « + tard ») | Picto pilule plein | + boutons « Pris / + tard / sans moi » |
| `late` | Teinte ambre douce (jamais rouge alarme), « Pas encore pris — c'est ok » | Picto pilule + « en retard » | + bouton « Ignorer exceptionnellement » |
| `taken` | Coche verte, « Pris à 8:42 », **disparaît après 5 min** | Coche | (minimal) |
| `missed` | Gris sobre, « Manqué — on reprend demain », **disparaît après 30 min** | — | — |

### Boutons (actions Live Activity)

Apple permet des `Button` dans les Live Activity (iOS 16.2+, natif iOS 26). Quatre actions max :

1. **Pris** → `status = .taken`, fin après 5 min, log automatique `taken at now, source: liveActivity`.
2. **Plus tard** → snooze standard (15 min) ou intelligent selon réglage.
3. **Je ne l'ai pas avec moi** → `status = .missed` avec raison `pasSurMoi`, fin après 30 min. **Aucun jugement.**
4. **Ignorer exceptionnellement** → `status = .missed` raison `volontaire`, fin immédiate. Possible seulement en `late`.

### Règles d'arrêt automatique `[DÉTERMINISTE]`

- `taken` → fin après 5 min (l'utilisateur voit la confirmation, puis ça disparaît proprement).
- `missed` → fin après 30 min.
- `windowEnd` dépassé + aucune interaction → transition `late → missed` après 30 min, fin.
- Une seule Live Activity médicament à la fois (prioriser la dose la plus en retard). Si plusieurs médicaments, on affiche la plus urgente et on liste les autres en compact.
- Au démarrage de l'app, `rearmIfNeeded` (comme `SmartAlarmController.rearmIfNeeded`) : s'il existe une dose « due » non confirmée, on réouvre la Live Activity.

### Ton

Calme, monochrome, jamais rouge vif. Réutiliser `.deviceSurface()` / `glassEffect` (Liquid Glass). Une coche verte `Pop.green` pour `taken`, un ambre `Pop.amber` pour `late`, du gris pour `missed`. **Zéro icône d'alerte, zéro point d'exclamation.**

---

## 5. Historique et suivi

### Stockage `[DÉTERMINISTE]`

Nouvelle table GRDB dans `whoop.sqlite` (schema v6), en respectant la convention `deviceId`-scoped + `ts`/`day`-keyed déjà en place :

```swift
// medicationDoseLog
medicationId TEXT, day TEXT, moment TEXT, status TEXT,
scheduledTs INTEGER, remindedTs INTEGER, takenTs INTEGER,
reason TEXT,                 // "pris" | "snooze" | "pasSurMoi" | "volontaire" | "oublie"
confirmSource TEXT,          // "liveActivity" | "notification" | "app" | "manualEdit"
contextConfidence TEXT,      // "high" | "medium" | "low" | "none"
reminderCount INTEGER,
metadataJSON TEXT,
PK(medicationId, day, moment)
```

Pourquoi GRDB et pas SwiftData : **cohérence avec le reste de l'app** (qui utilise déjà GRDB), inclusion gratuite dans le `.loopbackup` via `BackupCoordinator` (qui exporte `whoop.sqlite`), et pas de dépendance à `NSPersistentCloudKitContainer` (CloudKit est explicitement dropped, voir AGENTS.md). SwiftData/CoreData serait un écart d'architecture.

### Présentation

- **Historique jour par jour** : liste simple, une ligne par dose, avec statut coloré sobre (vert/ambre/gris, jamais rouge).
- **Adhérence** : % de prises confirmées dans la fenêtre, sur 7/30/90 jours. Toujours présenté avec bienveillance : « Cette semaine : 19/21 prises. C'est solide. » Jamais « 90% — attention ».
- **Tendances par moment** : « Tu prends mieux le matin (98%) que le soir (78%). » Simple bar chart `Charts`.
- **Créneaux à risque** : `HabitEngine` (Phase 3) détecte ex. « le mardi soir, 4 oublis sur 6 » → surfaced comme *insight*, pas comme alerte.
- **Export** : `ExportManager` produit un PDF/CSV (le `.loopbackup` est un package binaire ; pour un médecin il faut un format lisible). C'est la seule fonction du module export.

### Raisons de report — vocabulaire fixe `[DÉTERMINISTE]`

`pris | snooze | pasSurMoi | volontaire | oublie | priseTardive`. Ce vocabulaire borné évite le libre-texte et garde les statistiques propres. Pas de « autre » au début (trop tentant).

---

## 6. Apprentissage des habitudes

### Avant le LLM : des statistiques locales simples `[DÉTERMINISTE]`

Sur une fenêtre glissante de 30 jours, calculer :

- **Heure de réveil habituelle** : médiane des `sleepEnd` sur 30 j (`DailySnapshot.sleepEnd`). Robuste aux outliers (médiane, pas moyenne). `[WHOOP]` avec fallback `UserPreferences.wakeHour` `[SANS BRACELET]`.
- **Délai réveil → prise du matin** : médiane des `takenTs − sleepEnd` pour les doses `matin` confirmées.
- **Heure de prise du midi** : médiane des `takenTs` pour `midi`.
- **Heure de coucher habituelle** : médiane des `sleepStart`.
- **Moments/jours à risque** : pour chaque `(moment, weekday)`, ratio `manqués + tardifs / total` ; flag si ≥ 40% et ≥ 5 occurrences.
- **Contexte où les rappels marchent** : pour chaque dose confirmée, noter `délai rappel→prise`. Si ce délai est court pour `soft` → le `soft` marche. Si long → il faut `visible`.
- **Meilleur type de notification par moment** : comptage simple de « quel état a déclenché la confirmation ».

Tout ça tient en quelques médianes et compteurs, **pas besoin de ML**. On peut stocker ces résumés dans une table `habitSummary(medicationId, moment, weekday, medianTakenTs, ...)` mis à jour par le `BGProcessingTask` (30 min, déjà en place).

### Ce que ça permet déjà

- Recaler `DoseWindow.start` du matin sur `réveil habituel + délai habituel`.
- Prévenir un oubli récurrent : « le mardi soir tu oublies souvent → je te le rappellerai 10 min plus tôt » (Phase 3, opt-in).
- Choisir l'état initial : si l'utilisateur confirme quasi toujours au `soft`, on reste en `soft` ; s'il ignore souvent `soft`, on passe à `visible` plus vite.

### Limite à énoncer

Ces statistiques sont **descriptives, pas prédictives au sens médical**. Elles ajustent le *moment du rappel*, jamais la *posologie*. `[DANGER MÉDICAL]`

---

## 7. Rôle du LLM local / Apple Intelligence

### Ce que le LLM **peut** faire `[LLM]`

- **Reformuler les notifications** avec ton variable (calme/matinal/concis) selon l'heure et l'historique. Ex. matin → court ; soir → plus doux. Mais toujours sur un **template borné** ; le LLM choisit la formulation, pas le sens.
- **Résumé hebdomadaire** : « Cette semaine, 19 prises sur 21. Le mardi soir a glissé deux fois — c'était tes jours de déplacement. » à partir de `medicationDoseLog` + `habitSummary`. `[LLM]` consommant des données `[DÉTERMINISTE]`.
- **Expliquer pourquoi un rappel arrive maintenant** : « Je te le rappelle maintenant parce que tu es réveillé depuis 18 min et que tu le prends d'habitude dans les 30 min suivant le réveil. » Phrase générée à partir de *données déterministes* (réveil estimé + habitude), pas inventée.
- **Q&A sur l'historique** : « Est-ce que j'oublie souvent le midi ? » → réponse chiffrée. Le LLM ne fait que reformater une requête SQL/résumé.
- **Détecter des patterns** dans l'historique pour proposer des ajustements de *réglage applicatif* (ex. « veux-tu avancer le rappel du soir de 15 min ? »). Toujours avec acceptation explicite de l'utilisateur.
- **Personnaliser le ton**, en respectant le cahier des charges : jamais culpabilisant, jamais anxiogène.

### Ce que le LLM **ne doit pas** faire `[DANGER MÉDICAL]`

- Décider médicalement de changer une posologie, un horaire prescrit, ou une durée de traitement.
- Dire qu'un médicament peut être ignoré, sauté, ou décalé sans risque.
- Interpréter des symptômes (fatigue, palpitations, douleur) à partir des données WHOOP.
- Donner un diagnostic.
- Remplacer un professionnel de santé.
- Inventer un conseil médical, même « bienveillant ».
- Modifier le statut d'une dose sans action explicite de l'utilisateur.

### Règle d'implémentation

Le LLM **n'est jamais dans la boucle de décision de timing**. Il est uniquement en bout de chaîne : générer du texte à partir de faits déterministes. Toute sortie LLM est **post-filtered** par un validateur déterministe (longueur max, ton, vocabulaire autorisé, pas de terme médical interdit). Le moteur de rappel tourne sans lui.

---

## 8. Architecture technique

Tous les modules nouveaux vivent dans `Loop/Core/Medication/` (nouveau dossier) + extension `UserPreferences` + nouvelle table GRDB. Aucun nouveau package SPM nécessaire (pas de réutilisation cross-app prévue).

| Module | Rôle | Type | Dépend de |
|---|---|---|---|
| `MedicationPlan` | Représente un médicament + son dosage textuel + ses `DoseWindow`s. Modèle Codable, persisté. | `struct` | — |
| `MedicationDose` | Représente une dose *instance* (jour + moment + statut). | `struct` | `MedicationPlan` |
| `DoseWindow` | Fenêtre temporelle bornée + ancrage (`fixedHour` \| `afterWake` \| `beforeBed`) + rappels min/max. | `struct` | — |
| `DoseReminderEngine` | Cœur décisionnel : étant donné `MedicationPlan` + `ContextSnapshot` + `HabitSummary`, décide `reminder = now \| at(time) \| wait`. **Pur, testable, pas d'IO.** | `enum` (namespace, comme `AlarmScheduler` / `DailyEngine`) | `DoseWindow`, `ContextSnapshot` |
| `ContextDetector` | Construit `ContextSnapshot` (réveillé?, enMouvement?, sleepEnd?, recoveryBand?, source HR live ou HealthKit ou fallback horloge). `[WHOOP]` + fallback `[SANS BRACELET]`. | `@MainActor final class` | `LoopDataRepository`, `DeviceConnectionViewModel`, `ReferenceRepository` |
| `HabitEngine` | Calcule `HabitSummary` (médianes, ratios d'oubli par `(moment, weekday)`). Pur. | `enum` | `medicationDoseLog` |
| `NotificationScheduler` | Possède `UNUserNotificationCenter.current()`, `.delegate`, `arm/disarm/rearmIfNeeded` (modélisé sur `SmartAlarmController`). | `@MainActor final class ObservableObject` | `DoseReminderEngine`, `MedicationPlan` |
| `LiveActivityManager` | Start/update/end de la `MedicationActivityAttributes` (modélisé sur `BraceletBatteryLiveActivityController`). | `@MainActor final class` | `MedicationDose` |
| `LocalHistoryStore` | GRDB CRUD sur `medicationDoseLog` + `habitSummary` (modélisé sur `WhoopStore` actor pattern). | `actor` | GRDB |
| `PrivacyConsentManager` | Gère les consentements granulaires : WHOOP pour timing, HealthKit, calendrier, localisation. Stocké dans `UserPreferences`. | `@MainActor final class` | `UserPreferences` |
| `LLMInsightEngine` | Génère texte (résumé, explication, Q&A) à partir de `medicationDoseLog` + `HabitSummary`. Toujours post-filtré. | `@MainActor final class` | `FoundationModels` (iOS 26+) |
| `ExportManager` | Export PDF/CSV de l'historique. | `final class` | `LocalHistoryStore` |

### Flux de données

```
WHOOP BLE → WhoopStore → LocalMetricsEngine → cache.daily → ContextDetector
HealthKit → ReferenceStore → ReferenceRepository ↗
UserPreferences → DoseWindow ↘
medicationDoseLog → HabitEngine → HabitSummary → DoseReminderEngine → NotificationScheduler → UNNotification
                                                                              → LiveActivityManager → ActivityKit
Confirmation (Live Activity / notif / app) → LocalHistoryStore → HabitEngine (MAJ)
LLMInsightEngine lit LocalHistoryStore + HabitSummary → texte (UI)
```

---

## 9. Modèle de données

### Swift (Codable, GRDB-friendly)

```swift
struct MedicationPlan: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String                  // "Vitamine D" — nom libre court, saisi par l'utilisateur
    var doseLabel: String             // "1 comprimé" — texte, PAS calculé
    var moments: [DoseMoment]         // [{.matin, window}, {.midi, window}, {.soir, window}]
    var criticality: Criticality      // .normal | .critical (changed timing needs explicit ack)
    var foodConstraint: FoodConstraint? // nil | .withMeal | .afterMeal | .beforeBed | .emptyStomach
    var aiAssistEnabled: Bool         // default true ; peut être désactivé par médicament
    var state: PlanState              // .active | .paused | .archived — cycle de vie dynamique
    var createdAt: Date
}

// L'utilisateur gère sa liste en autonomie : ajout, édition, pause temporaire
// (ex. arrêt de traitement pendant 2 semaines), archivage (garde l'historique,
// ne schedule plus). Aucun preset, aucune base de médicaments — tout est saisi
// à la main, librement, à tout moment.
enum PlanState: String, Codable { case active, paused, archived }

struct DoseMoment: Codable, Equatable {
    let moment: Moment                // .matin | .midi | .soir | .custom
    var window: DoseWindow
}

struct DoseWindow: Codable, Equatable {
    var anchor: Anchor                // .fixedHour | .afterWake(minutes) | .beforeBed(minutes)
    var startOffsetMin: Int           // relatif à l'ancre
    var endOffsetMin: Int             // relatif à l'ancre
    var reminderMinOffset: Int        // défaut du 1er rappel (soft)
    var reminderMaxOffset: Int        // dernier rappel possible
    var weekdayMask: Set<Int>         // Calendar 1…7 ; vide = tous les jours
    enum Anchor: Codable { case fixedHour(Int, Int); case afterWake(Int); case beforeBed(Int) }
}

enum Moment: String, Codable { case matin, midi, soir, custom }
enum Criticality: String, Codable { case normal, critical }
enum FoodConstraint: String, Codable { case withMeal, afterMeal, beforeBed, emptyStomach }

struct MedicationDose: Codable, Identifiable, Equatable {
    let id: UUID
    let medicationId: UUID
    let day: String                   // "YYYY-MM-DD"
    let moment: Moment
    var status: DoseStatus            // .scheduled | .reminded | .snoozed | .taken | .missed
    var scheduledTs: Date
    var remindedTs: Date?
    var takenTs: Date?
    var reason: DoseReason?           // pour .missed / .snoozed
    var confirmSource: ConfirmSource?
    var contextConfidence: Confidence // .high | .medium | .low | .none
    var reminderCount: Int
    var metadata: DoseMetadata?       // réveil détecté via WHOOP?, HR au moment, etc.
}

enum DoseStatus: String, Codable { case scheduled, reminded, snoozed, taken, missed }
enum DoseReason: String, Codable { case pris, snooze, pasSurMoi, volontaire, oublie, priseTardive }
enum ConfirmSource: String, Codable { case liveActivity, notification, app, manualEdit }
enum Confidence: String, Codable { case high, medium, low, none }
```

Compatible SwiftData si l'équipe veut plus tard migrer (tous `Codable` + `Identifiable`), mais **persisté en GRDB** pour rester cohérent avec `whoop.sqlite` et le `.loopbackup`. Le `metadata` capture *pourquoi* le rappel est arrivé à ce moment — ça nourrit l'écran « pourquoi je reçois ce rappel maintenant » (§11).

---

## 10. Algorithme de décision

`DoseReminderEngine.decide(plan:moment:context:habit:now:) -> Decision` — **pur, testable**, aucune IO.

```text
Entrées :
  plan        : MedicationPlan
  moment      : Moment (matin/midi/soir)
  context     : ContextSnapshot { isAwake: Confidence, sleepEnd: Date?,
                                   inMotion: Bool, recoveryBand: String?,
                                   hrLive: Double?, source: "whoop"|"healthkit"|"clock" }
  habit       : HabitSummary { medianWakeTs, medianDelayMorningMin,
                               medianTakenTs[moment], riskRatio[(moment,weekday)] }
  now         : Date

Sortie : Decision = .remindNow(reason) | .remindAt(date, reason) | .wait(reason) | .giveUp(reason)

ALGO :

  # 1. Résoudre la fenêtre effective pour aujourd'hui
  anchorTs = selon window.anchor :
      fixedHour(h,m) → Calendar next occurrence of (h:m) today (ou null si hors weekdayMask)
      afterWake(d)   → context.sleepEnd + d   (si sleepEnd connu)
                       sinon habit.medianWakeTs + d  (fallback)
                       sinon UserPreferences.wakeHour + d  (fallback ultime)
      beforeBed(d)   → habit.medianBedtimeTs − d
                       sinon (UserPreferences.wakeHour + 24h − sleepTargetMin) − d
  start = anchorTs + window.startOffsetMin
  end   = anchorTs + window.endOffsetMin

  # 2. Hors weekdayMask → giveUp("hors routine aujourd'hui")
  if now.weekday not in window.weekdayMask and mask non vide:
      return .giveUp("hors routine")

  # 3. Avant la fenêtre → rappel calendrier à start
  if now < start:
      return .remindAt(start, "début de fenêtre")

  # 4. Déjà pris → rien
  if dose.status == .taken:
      return .wait("déjà pris")

  # 5. Dans la fenêtre : choisir le bon moment
  if start <= now <= end:
      # 5a. Gate de sommeil (ne jamais réveiller)
      if not context.isAwake or context.isAwake == .low:
          # si on est avant end − 10 min, on attend ; sinon on notifie quand même (dose critique)
          if now < end − 10min or plan.criticality == .normal:
              return .wait("utilisateur probablement endormi")
          # dose critique en fin de fenêtre : on notifie (avec raison)
      # 5b. Disponibilité : si enMouvement récent (HR-rise ou steps), c'est le bon moment
      if context.inMotion and reminderCount == 0:
          return .remindNow("réveillé et actif dans la fenêtre")
      # 5c. Sinon, premier rappel à start + reminderMinOffset si pas encore rappelé
      if reminderCount == 0 and now >= start + reminderMinOffset:
          return .remindNow("début de fenêtre, délai minimum atteint")
      # 5d. Escalade selon temps écoulé depuis dernier rappel (voir §3)
      ... (soft → visible → late selon deltas)

  # 6. Après la fenêtre sans prise
  if now > end:
      if plan.criticality == .critical and dose.status != .missed:
          return .remindNow("fenêtre close, médicament critique — à confirmer")
      else:
          return .remindAt(rien) → transition missed après 30 min

  # 7. Habit préventif (Phase 3) : si risque élevé pour (moment, weekday) et
  #    now >= start − 10min, anticiper un soft (opt-in)
  if habit.riskRatio[(moment, now.weekday)] >= 0.4 and anticiperActive:
      return .remindAt(start − 10min, "créneau à risque pour toi")
```

### Garde-fous intégrés `[DÉTERMINISTE]`

- **Anti-doublon** : `NotificationScheduler` garde l'id de notification `"{medicationId}/{day}/{moment}"` ; si déjà pending, pas de re-schedule.
- **Anti-spam** : `reminderCount` plafonné à 3 (voir §3).
- **Bracelet absent** : `context.source == "clock"` → on saute les gates 5a/5b et on notifie à `start + reminderMinOffset`. `contextConfidence = .none` pour la dose. `[SANS BRACELET]`
- **Confirmation tardive** : si `takenTs` est dans la fenêtre + grâce (ex. +30 min), statut `taken` avec `metadata.tardive = true`. Au-delà, `priseTardive` si la fenêtre du moment suivant n'a pas commencé, sinon `missed` (l'utilisateur peut toujours éditer manuellement).

---

## 11. UX / UI

### Écrans

1. **Médicaments** (`Features/Medication/MedicationListView`) — liste sobre, une carte par médicament avec prochain rappel. `.deviceSurface()`. Bouton « + » pour ajouter un médicament à tout moment ; swipe pour pause/archiver ; tap pour éditer. La liste est **vide par défaut** — rien n'est pré-rempli, l'utilisateur saisit lui-même ce qu'il prend.
2. **Ajout / édition d'un médicament** — nom libre (pas de base de médicaments, pas d'autocomplétion médicale), dosage textuel, moments (matin/midi/soir/custom), fenêtres, contraintes alimentaires, criticité, IA activée. L'utilisateur peut ajouter, modifier, mettre en pause ou archiver à tout moment — le scheduler re-branche les notifications en conséquence (`rearmIfNeeded`).
3. **Routine matin/midi/soir** — sous-écran de config d'une fenêtre : ancrage (`afterWake` / `fixedHour` / `beforeBed`), offsets min/max, weekdayMask. Slider visuel de la fenêtre.
4. **Today** — une carte « Prochain médicament » dans le `TodayView` existant (à côté des rings). Si rien à prendre → carte discrète « Rien à prendre avant [heure]. »
5. **Live Activity** (§4).
6. **Historique** — liste jour par jour, adhérence 7/30/90 j.
7. **Statistiques d'adhérence** — bar charts par moment, heatmap `(moment × weekday)`.
8. **Réglages notifications** — ton (doux/standard), snooze par défaut, heure « ne pas déranger ».
9. **Réglages confidentialité** — toggles granulaires : WHOOP pour le timing, HealthKit, calendrier, localisation. Chaque toggle explique *ce qu'il apporte* et *ce qu'on ne fait pas*.
10. **« Pourquoi ce rappel maintenant ? »** — feuille explicative générée à partir de `metadata` : « Tu t'es réveillé vers 7:18 (WHOOP). Tu prends d'habitude ce médicament dans les 25 min qui suivent. C'est pour ça que je te le rappelle maintenant. » `[DÉTERMINISTE]` phrase générée par template, ou `[LLM]` reformulé en Phase 3.

### Ton & design

- Reprise stricte de `DESIGN.md` (Liquid Glass, monochrome, `.deviceSurface()`, un accent par page).
- **Tonalité non médicale** : « ton médicament du matin », pas « votre traitement ». Tutoiement. Pas d'icône croix rouge, pas de terme clinique.
- **Jamais culpabilisant** : un oubli → « Pas grave, on reprend demain. » Jamais « Vous avez manqué votre dose ! »
- **Explicable par défaut** : tout rappel a un « pourquoi » accessible en un tap.

---

## 12. Notifications — exemples de textes

Calme, court, jamais alarmiste, jamais culpabilisant. Tutoiement. Pas de point d'exclamation.

| Type | Texte |
|---|---|
| **Douce** (soft, matin) | « Bonjour. Ton [médoc] du matin est là quand tu veux. » |
| **Douce** (soft, midi) | « Petit rappel : [médoc] du midi, à ton rythme. » |
| **Douce** (soft, soir) | « Ce soir, n'oublie pas [médoc] quand tu es posé. » |
| **Visible** (dueNow) | « C'est le bon moment pour [médoc]. » |
| **En retard** (late) | « Tu n'as pas encore pris [médoc]. Pas grave, c'est encore bon. » |
| **Après snooze** | « Comme prévu : [médoc], quand tu veux. » |
| **Contextuelle réveil** `[WHOOP]` | « Tu es debout depuis un moment — [médoc] du matin quand tu es prêt. » |
| **Fin de journée** | « Avant de terminer la soirée : [médoc] du soir. » |
| **Créneau à risque** (Phase 3, opt-in) | « Le [jour] soir, ça glisse parfois. Je te le rappelle un peu plus tôt. » |
| **Confirmation** (silencieuse, après Pris) | « [médoc] noté. Bonne journée. » |

Les boutons d'action : « Pris », « Plus tard », « Je ne l'ai pas avec moi », « Ignorer exceptionnellement ». Pas de « Pourquoi je l'ai pas pris ? ».

---

## 13. Cas particuliers

| Cas | Comportement `[DÉTERMINISTE]` |
|---|---|
| Dort tard | Gate sommeil (§10) retient tout ; rappel décalé au prochain `isAwake`, borné par `window.end`. |
| Réveil très tôt (4h) | Si `window.anchor == .afterWake`, la fenêtre s'ouvre tôt — c'est attendu. Si `.fixedHour`, le rappel reste à l'heure fixe. L'utilisateur peut configurer un `earliestReminderHour` (ex. « jamais avant 6h ») — **réglage explicite, pas deviné**. |
| Bracelet déconnecté | `context.source = "clock"`, fenêtres horaires pures, `contextConfidence = .none`. Rien ne casse. `[SANS BRACELET]` |
| iPhone en mode économie d'énergie | Les `UNNotificationRequest` programmées sont livrées par l'OS indépendamment. La Live Activity peut être moins fraîche ; acceptable. |
| N'a pas le médicament | Bouton « Je ne l'ai pas avec moi » → `missed` raison `pasSurMoi`, aucune relance, pas de jugement. |
| Ignore plusieurs rappels | Max 3 notifs (§3), puis Live Activity seule. On arrête de pousser. |
| Prend sans confirmer | Pas de détection magique. Si l'utilisateur ouvre l'app et marque « pris » a posteriori → `taken` avec `confirmSource = .manualEdit`, `metadata.tardive = true` si hors fenêtre. |
| Confirmation tardive | Acceptée jusqu'à `window.end + grâce` (ex. 30 min). Au-delà → `priseTardive` si prochain moment pas commencé. |
| Change de routine | `HabitEngine` recalcule sur fenêtre glissante 30 j → la routine s'adapte en ~1 semaine. L'utilisateur peut aussi forcer un mode `routine: deplacement` pour la journée. |
| Voyage / fuseau | Utiliser `Calendar.current` (heure locale du téléphone). Pas de gestion complexe du jet-lag en MVP. |
| Contrainte alimentaire « après repas » | `FoodConstraint.afterMeal` → `window.anchor` idéalement sur un événement repas (non détectable fiable) ; en MVP, fenêtre fixe + note dans l'écran de config « après le repas ». `[DANGER MÉDICAL]` ne pas deviner le repas. |
| Contrainte « avant coucher » | `FoodConstraint.beforeBed` → `anchor = .beforeBed(minutes)`. `[WHOOP]` si `habit.medianBedtimeTs` connu, sinon `UserPreferences` fallback. |
| Ne veut pas être notifié devant d'autres | Toggle « mode discret » : notification silencieuse (pas de son, pas de texte affiché en bannière) + Live Activity uniquement. Actionnable via le bouton matériel du téléphone. |

---

## 14. Garde-fous santé `[DANGER MÉDICAL]`

Limites produit **non négociables**, à afficher dans l'app (onboarding médicament + réglages) :

1. **Ne jamais modifier une prescription.** L'app ne connaît pas la prescription ; elle rappelle ce que l'utilisateur a saisi. Elle ne suggère jamais de changer la dose, l'horaire prescrit, ou la durée.
2. **Ne jamais conseiller d'arrêter ou de décaler dangereusement.** Pas de « tu peux sauter cette dose ». Si l'utilisateur a dépassé la fenêtre, l'app dit « c'est encore bon » seulement dans une marge configurable **par l'utilisateur**, pas par défaut.
3. **Ne pas remplacer un médecin.** Mention explicite dans l'onboarding médicament et dans l'export.
4. **Messages de sécurité** : pour un médicament `criticality == .critical`, afficher un encart « Ce médicament est marqué comme critique par toi. En cas de doute, demande à ton médecin ou ton pharmacien. »
5. **Médicaments critiques avec prudence** : pas de snooze « intelligent » par défaut (l'utilisateur doit explicitement l'activer) ; rappel plus ferme (mais toujours poli) en fin de fenêtre.
6. **Règles prescrites configurables** : l'utilisateur peut saisir « à prendre impérativement dans la fenêtre X », « ne pas décaler de plus de Y min » — l'algo respecte ces bornes, l'IA ne peut pas les outrepasser.
7. **Désactiver l'IA par médicament** : `MedicationPlan.aiAssistEnabled = false` → timing purement déterministe aux fenêtres configurées, pas de smart-timing WHOOP, pas de LLM.
8. **Exporter pour en parler à un professionnel** : `ExportManager` produit un PDF lisible pour apporter au médecin/pharmacien.

Ces garde-fous doivent être **codés en dur** (pas pilotables par LLM, pas désactivables par « optimisation »).

---

## 15. Priorisation MVP

### Phase 1 — MVP utile (6–8 semaines, un dev)

- `[DÉTERMINISTE]` Saisie dynamique des médicaments par l'utilisateur (liste vide par défaut, ajout/édition/pause/archivage à tout moment, nom libre + dosage textuel — aucune base de médicaments, aucun preset).
- `[DÉTERMINISTE]` `DoseWindow` à ancrage `fixedHour` uniquement (pas de WHOOP).
- `[DÉTERMINISTE]` `NotificationScheduler` (`UNCalendarNotificationTrigger` + delegate + actions « Pris/Plus tard/Sans moi »).
- `[DÉTERMINISTE]` Confirmation (notif + app) → `LocalHistoryStore` (GRDB).
- `[DÉTERMINISTE]` `LiveActivityManager` basique : `dueSoon / dueNow / taken` (pas de `late` complexe, pas de Dynamic Island riche en v1).
- `[DÉTERMINISTE]` Historique jour par jour + adhérence 7 j.
- `[DÉTERMINISTE]` Carte Today « prochain médicament ».
- `[DÉTERMINISTE]` Export PDF/CSV.

→ **Déjà différenciant** : un rappel borné dans une fenêtre, avec confirmation en 1 tap, Live Activity, et historique local exportable. Aucun bracelet requis.

### Phase 2 — Proactif (4–6 semaines)

- `[WHOOP]` + `[SANS BRACELET]` `ContextDetector` : `isAwake` via `sleepEnd` du `DailySnapshot` + HR live (`SmartAlarmController` heuristic réutilisée). Fallback horloge.
- `[DÉTERMINISTE]` `DoseWindow.anchor = .afterWake / .beforeBed`.
- `[DÉTERMINISTE]` Escalade `soft → visible → late` + snooze intelligent.
- `[DÉTERMINISTE]` Live Activity enrichie (`late`, Dynamic Island expanded, boutons).
- `[DÉTERMINISTE]` Statistiques d'oubli par moment + heatmap `(moment × weekday)`.
- `[DÉTERMINISTE]` « Pourquoi ce rappel maintenant ? » par template.

### Phase 3 — Intelligent (6–8 semaines)

- `[DÉTERMINISTE]` `HabitEngine` : médianes, créneaux à risque, délai réveil→prise.
- `[DÉTERMINISTE]` Rappel anticipé opt-in pour créneaux à risque.
- `[LLM]` `LLMInsightEngine` : résumé hebdomadaire, Q&A historique, personnalisation du ton, explication reformulée.
- `[DÉTERMINISTE]` Suggestions de réglage (avancer/décaler une fenêtre), acceptation explicite.
- Optionnel : calendrier/localisation (consentement granulaire).

---

## 16. Évaluation de faisabilité

Légende : Impact (1–5), Difficulté (1–5), WHOOP (✓ requis / ○ optionnel / — aucun), iOS API, Faux-positif (1–5), Risque santé (1–5), Priorité (1–5).

| Fonctionnalité | Impact | Diff. | WHOOP | iOS API | FP | Risque santé | Priorité |
|---|---|---|---|---|---|---|---|
| Médicament + fenêtres + notif `fixedHour` | 5 | 2 | — | UNNotification | 1 | 1 | 5 |
| Confirmation + Live Activity basique | 5 | 2 | — | ActivityKit | 1 | 1 | 5 |
| Historique GRDB + adhérence | 4 | 2 | — | GRDB | 1 | 1 | 5 |
| Export PDF | 3 | 2 | — | PDFKit | 1 | 1 | 4 |
| Escalade + snooze | 4 | 3 | — | UNNotification | 2 | 1 | 4 |
| `ContextDetector` (réveillé) | 4 | 3 | ○ | HealthKit/HR live | 3 | 1 | 4 |
| Anchor `afterWake`/`beforeBed` | 4 | 2 | ○ | — | 2 | 1 | 4 |
| Live Activity `late` + DI riche | 3 | 2 | — | ActivityKit | 1 | 1 | 3 |
| Heatmap adhérence | 3 | 2 | — | Charts | 1 | 1 | 3 |
| `HabitEngine` (médianes, risque) | 4 | 3 | ○ | — | 3 | 1 | 3 |
| Rappel anticipé créneau à risque | 3 | 3 | ○ | — | 4 | 2 | 2 |
| `[LLM]` Résumé hebdo + Q&A | 3 | 3 | — | FoundationModels | 2 | 2 | 2 |
| `[LLM]` Ton personnalisé | 2 | 2 | — | FoundationModels | 2 | 2 | 2 |
| `[LLM]` « Pourquoi maintenant » reformulé | 2 | 2 | — | FoundationModels | 2 | 2 | 2 |
| Calendrier/localisation | 2 | 3 | — | EventKit/CL | 3 | 1 | 1 |
| Détection repas (WHOOP) | 1 | 5 | ✓ | — | 5 | 3 | 1 — **à ne pas faire** |
| Modifier posologie | — | — | — | — | — | 5 | **jamais** `[DANGER MÉDICAL]` |
| Interpréter symptômes | — | — | — | — | — | 5 | **jamais** `[DANGER MÉDICAL]` |

---

## 17. Recommandation finale

Construire **Phase 1 uniquement** en premier, et la faire bien. C'est-à-dire :

1. **Un rappel déterministe à fenêtre** (`DoseWindow` + `fixedHour`), pas de bracelet, pas de LLM. Trois fenêtres matin/midi/soir, ancrées sur l'horloge — l'utilisateur configure l'heure cible et une marge.
2. **Confirmation en 1 tap** via notification + Live Activity (`dueSoon / dueNow / taken`), avec les quatre boutons bornés.
3. **Historique local en GRDB** (`medicationDoseLog`, schema v6), adhérence 7/30/90 j, export PDF.
4. **Carte Today** sobre à côté des rings.

Pourquoi c'est déjà différenciant : la **fenêtre bornée + Live Activity persistante + historique exportable** est ce que la plupart des apps de rappel ne font pas (elles notifient à heure fixe et oublient). Ça résout déjà 3 des 4 problèmes de l'utilisateur (oublis du soir, midi en déplacement via « je ne l'ai pas avec moi », prise non confirmée), **sans bracelet, sans IA, sans risque médical**.

N'ajouter **Phase 2 (smart-timing WHOOP)** qu'une fois Phase 1 utilisée en réel pendant 2–3 semaines — parce que le smart-timing n'a de sens que si l'historique est déjà rempli pour valider qu'il améliore l'adhérence. Et **Phase 3 (LLM) encore après**, strictement cantonnée au texte, jamais à la décision.

### Ce qu'il ne faut PAS construire

- Un LLM qui décide du timing `[DANGER MÉDICAL]` et over-engineering.
- Une détection de repas par WHOOP (faux positifs élevés, peu de valeur).
- Une interprétation de recovery/HRV pour ajuster un médicament `[DANGER MÉDICAL]`.
- Une usine à gaz de ML avant d'avoir un historique concret.

### Le tri qui résume tout

| Doit être déterministe | Peut être LLM-assisté | Dépend du bracelet | Doit marcher sans bracelet | Dangereux médicalement | Améliore vraiment l'adhérence |
|---|---|---|---|---|---|
| Fenêtres, scheduler, escalade, Live Activity, historique, habit stats, export, garde-fous | Reformulation notifs, résumé hebdo, Q&A, explication | `isAwake`, `afterWake`, `beforeBed`, HR-rise gate | **Toute la Phase 1**, et tous les fallbacks de Phase 2/3 | Modifier posologie, interpréter symptômes, conseiller d'ignorer, se servir de recovery/HRV pour ajuster un traitement | Fenêtre bornée, Live Activity persistante, « je ne l'ai pas avec moi », historique + adhérence par moment, snooze intelligent, rappel anticipé sur créneau à risque (Phase 3) |

La fonctionnalité gagne sur le **calme, la fiabilité du déterministe, et la transparence** — pas sur la complexité algorithmique. Un rappel qui arrive au bon moment parce qu'il est borné et explicable vaut mieux qu'un rappel « intelligent » opaque.
