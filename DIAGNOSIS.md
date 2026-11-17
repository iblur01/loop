# Loop — Diagnostic de la chaîne de données

> Rédigé le 2026-06-17. Diagnostic de bout en bout : persistance, recalcul, sommeil, serveur.
> Preuves `fichier:ligne` à l'appui. Aucune donnée supprimée, aucune refonte appliquée à ce stade.

> **MISE À JOUR 2026-06-18 — Cutover offline-first complet.** Le serveur VPS
> (`iblur01@vps.dlnntheo.fr`) a été **entièrement supprimé** : plus de `LoopUploader`,
> `ServerImporter`, `LoopUploadConfig`, `LoopConfiguration`, `Secrets.xcconfig` ni clés
> `LOOP_*`. Le backup/restore passe désormais par un **backup fichier** (`BackupCoordinator`) :
> export/import d'un paquet `.loopbackup` (`whoop.sqlite` + `cache.json` + `meta.json`) via l'app
> Fichiers / iCloud Drive (`UIDocumentPickerViewController`). Aucun entitlement (CloudKit écarté :
> réservé aux comptes Apple Developer payants). Optionnel, jamais une dépendance de runtime. Le
> deviceId local stable vit dans `UserDefaults` via `LocalDeviceID`.
> Les §1/§2 ci-dessous décrivent l'état AVANT cutover ; les blocs serveur sont obsolètes.

---

## 1. Carte de flux des données

```
WHOOP 4.0 (BLE)
   │  frames brutes
   ▼
BLEFrameReassembler / BLEFrameRouter ──► WhoopProtocol (décodage)
   │  streams décodés (HR, RR, gravity, spo2, skinTemp, resp, battery, events)
   ▼
Collector / Backfiller  ── deviceId = "my-whoop" (défaut placeholder) ──┐
   ▼                                                                    │ race
WhoopStore (SQLite, RAW DURABLE)  <AppSupport>/Loop/whoop.sqlite        │
   tables: hrSample, rrInterval, gravitySample, respSample,            │
           spo2Sample, skinTempSample, battery, event, rawBatch        │
   ▲                                                                    │
   │  configure() reassignDevice("my-whoop" → "theo-whoop") en Task ◄──┘ (async, après coup)
   │
   ├─► LocalMetricsEngine.compute(days: 60)  ── moteur dérivé
   │       lit RAW par jour/chunk → SleepEngine, DailyEngine, AdviceEngine
   │       écrit ► cache.json (LoopCache : daily, sleepSessions, stress, hrSamples)
   │       (n'écrit PAS les tables dailyMetric/sleepSession SQLite — voir §4)
   │
   ▼
cache.json  <AppSupport>/Loop/cache.json   ── SOURCE DE VÉRITÉ UI ACTUELLE
   ▼
LoopDataRepository.cache (@Published)
   ▼
UI : TodayView / DeviceView / SettingsView  (lit cache uniquement, jamais le réseau)

BACKUP fichier (.loopbackup, remplace le serveur VPS — voir bandeau 2026-06-18)
   BackupCoordinator.prepareExport()  ── checkpoint WAL → paquet whoop.sqlite + cache.json + meta.json
   BackupCoordinator.importBackup(from:) ── paquet choisi (Fichiers) → remplace les fichiers locaux
   → canal backup/restore manuel UNIQUEMENT, aucun entitlement, jamais une dépendance de runtime
```

**Constat clé** : il existe **deux familles de tables dérivées** qui ne sont PAS toutes utilisées de la même façon :
- `cache.json` (LoopCache) = ce que l'UI lit réellement, écrit par le moteur local.
- Tables SQLite `dailyMetric` / `sleepSession` / `adviceSignal` = cache « miroir serveur » documenté comme rempli par le serveur (`MetricsCache.swift:4-9`), mais le moteur local **écrit dans cache.json, pas dans ces tables**. Désalignement de design (§4, P5).

---

## 2. Chemins et configuration réels

| Élément | Valeur | Preuve |
|---|---|---|
| SQLite (RAW + dérivé miroir) | `<AppSupport>/Loop/whoop.sqlite` (chemin unique, WAL, busy_timeout 5s) | `StorePaths.swift:6-12`, `WhoopStore.swift:27-34` |
| Cache JSON (dérivé UI) | `<AppSupport>/Loop/cache.json` | `LocalDataStore.swift:51-52` |
| ~~Config serveur~~ (supprimée 2026-06-18) | — | deviceId local désormais dans `UserDefaults` via `LocalDeviceID` |
| deviceId collecteur (défaut placeholder) | `"my-whoop"` puis résolu | `BLEConnectionManager` bootstrapStore |
| deviceId local stable | `"theo-whoop"` (fallback `LocalDeviceID.fallback`) | `LocalDeviceID.swift` |
| Store | instance unique par session (`guard collector == nil`) | `BLEConnectionManager.swift:229-232` |
| Fenêtre de calcul | **60 jours en dur**, à chaque run | `LocalMetricsEngine.swift:84,99` ; appelé `compute(days: 60)` `LoopDataRepository.swift:127` |

Pas de DB sur simulateur (l'app tourne sur device réel) → stats live à récupérer via l'outil `scripts/loop_diag.py` (§9) quand la DB est accessible.

---

## 3. Problèmes confirmés (preuves)

### P1 — Race de deviceId : `my-whoop` vs `theo-whoop` → données à 0 / qui « disparaissent »
- Collector/Backfiller insèrent sous `my-whoop` dès le bootstrap (`BLEConnectionManager.swift:123,261-264`).
- `configure()` ré-aligne vers `theo-whoop` **dans un `Task` asynchrone après coup**, recrée l'engine, et appelle `reassignDevice` (`:267-289`).
- Fenêtre de course : tant que le `Task` n'a pas tourné, l'engine interroge sous un deviceId pendant que les lignes sont sous l'autre → `compute` renvoie des séries vides.
- Au démarrage, `load()` remplace une config stockée `my-whoop` par la config bundlée `theo-whoop` (`LoopDataRepository.swift:219-221`) → re-déclenche le ré-alignement à chaque lancement.
- **Conséquence directe** : recalcul vide → garde-fou conserve l'ancien cache (`:130-132`) si présent, sinon UI à 0.

### P2 — Recalcul intégral non incrémental, fenêtre 60 jours systématique
- `compute(days: 60)` recalcule **toujours** 60 jours depuis zéro (`LocalMetricsEngine.swift:84,99-102`).
- Seul garde-fou « dirty » : comparaison du **nombre total de lignes** (`rowsUnchanged`, `LoopDataRepository.swift:116`). Tout ajout d'1 ligne (offload BLE) → recompute des 60 jours.
- Aucun watermark ni dirty-flag par jour. Pas d'incrémentalité.
- `lastComputedRowCount` est **en mémoire seulement** → nil à chaque relance → recompute complet garanti au démarrage.

### P3 — Détection de sommeil cassée : session de 64h55 (nuit 16→17 juin)
Cause racine (preuves dans `Sleep/`) :
- `mergeMidSleepWakes` absorbe les réveils ≤ **120 min** (`InBedDetection.swift:247`, `midSleepWakeMaxMin=120`) → fusionne plusieurs nuits.
- `buildRuns` ne sépare qu'au-delà de **20 min** de trou (`InBedDetection.swift:14,168`) → port continu = un seul run.
- Le span retourné = `confirmed[0].start → confirmed[last].end` (`InBedDetection.swift:72`), **trous inclus**.
- Durée de session = `end - start` **sans soustraire les gaps** (`SleepEngine.swift:98-99,157`).
- `buildEpochGrid` construit une grille de `min(start)→max(end)` sans cap ni reset jour (`EpochGrid.swift:119-130`) → grille géante si span multi-jours.
- **Aucun plafond** sur la durée max d'une session.

### P4 — Lenteur (8 jours → 30-40 min) : voir §6, même cause racine que P3.

### P5 — Désalignement « cache UI » vs « tables dérivées SQLite »
- `MetricsCache.swift:4-9` documente `dailyMetric`/`sleepSession` comme remplies **par le serveur**, « le téléphone ne calcule rien ici ».
- Mais le moteur local écrit ses résultats dans `cache.json` (`LoopDataRepository.swift:137-145`), **pas** dans ces tables.
- Donc : deux stores dérivés concurrents, l'UI ne lit que `cache.json`, les tables `dailyMetric` ne servent qu'au chemin serveur (aujourd'hui non utilisé pour le pull). Source de vérité dérivée ambiguë.

### P6 — `try?` masque les erreurs sur tout le chemin chaud
- Toutes les lectures de streams : `(try? await store.hrSamples(...)) ?? []` (`LocalMetricsEngine.swift:135-146,191-209`). Une erreur DB devient une série vide silencieuse → métriques à 0 sans trace.

### P7 — Barre de progression trompeuse
- `progressTotal = sleepChunks.count + dates.count * 2` (`LocalMetricsEngine.swift:118`). Pour 60 jours = 9 + 120 = **129**, pas 120.
- Le blocage « vers 51/120 » correspond à la phase sommeil (chunks) + début de la boucle quotidienne : chaque chunk de 7 jours peut prendre plusieurs minutes (P4), donc l'incrément reste figé longtemps entre deux ticks. La barre n'est pas pondérée par le coût réel de chaque phase.

---

## 4. Hypothèses invalidées

- ❌ « L'app contacte le serveur au démarrage et bloque l'UI. » → **Faux.** Aucun appel serveur automatique bloquant ; `requestSync` lance un `Task` non bloquant et no-op si pas de config (`SyncCoordinator.swift:105,154-160`). L'UI lit toujours le cache disque. Le mode offline-first est déjà en place côté affichage.
- ❌ « L'UI affiche une réponse serveur non persistée. » → **Faux.** L'UI lit `repository.cache` (disque) ; tout passe par `importStreams` → SQLite → recompute → cache (`TodayView.swift:18-26`).
- ❌ « Plusieurs stores ouverts en parallèle sur le même fichier. » → **Non observé** : instance unique gardée par `guard collector == nil` (`BLEConnectionManager.swift:230`).
- ❌ « Import serveur sous mauvais deviceId silencieux. » → Partiellement faux : l'import **rejette** un mismatch (`ServerImporter.swift:69-71`). Le vrai problème de deviceId est la race locale BLE (P1), pas l'import.
- ❌ « Manque d'index SQLite sur (deviceId, ts). » → **Faux** : les PK composites `(deviceId, ts)` couvrent les requêtes par plage (`Database.swift`). Le coût n'est pas l'index mais le volume chargé en mémoire (§6).

---

## 5. Bottlenecks mesurés / fortement suspectés

**Cause racine unique de la lenteur ET du bug 64h : la détection de sommeil sur des spans continus géants.**

1. **Chargement massif en mémoire par chunk** : `chunkLimit = chunkDays * 150_000` (`LocalMetricsEngine.swift:133`) → jusqu'à **~1,05 M échantillons HR** + autant de RR + resp + gravity par chunk de 7 jours, mappés/transformés en arrays Swift (`:135-155`). 9 chunks pour 60 jours.
2. **Grille d'époques explosive** : avec la fusion multi-nuits (P3), un run peut couvrir 64h → `64*3600/30 ≈ 7 700` époques (`EpochGrid.swift:130`), chacune calculant des features HRV sur fenêtre RR (`SleepFeatures.swift`). Coût ≈ O(époques × échantillons/fenêtre).
3. **`detectWorkoutSessions` + `makeStressSnapshot` par jour** sur `hrSeries` complet (`LocalMetricsEngine.swift:217-229`) × 60.
4. **O(N²) en mémoire** : refold des baselines sur l'historique croissant pour chaque jour (`Daily.swift:161-187`, `Baselines.swift:238-254`) + slicing `allInputs[0..idx]` (`LocalMetricsEngine.swift:262+`). Mineur (60² ≈ 3600) mais réel.
5. **Sérialisation** : tout est séquentiel jour par jour / chunk par chunk, aucune parallélisation (`actor LocalMetricsEngine`, `await` en boucle).

**Pourquoi 8 jours → 30-40 min** : même quand seuls 8 jours portent des données, le moteur balaie 60 jours (jours vides peu coûteux), mais les 1-2 chunks contenant le port continu chargent ~1M échantillons **et** lancent une détection de sommeil sur des spans géants (grilles de milliers d'époques avec maths HRV par époque). Le bug de fusion (P3) gonfle la grille → le coût explose. **Corriger la segmentation du sommeil corrige aussi la lenteur.**

---

## 6. Risques de corruption / perte de données

- 🟠 **Orphelins de deviceId** (P1) : lignes sous `my-whoop` jamais ré-assignées si `configure` n'a pas tourné → invisibles, mais **non perdues** (RAW durable, jamais pruné). `purgeOrphans` les supprimerait par erreur si le deviceId courant est mauvais au moment du purge.
- 🟠 **`purgeAll` / `purgeOrphans`** vident cache + lignes décodées (`LoopDataRepository.swift:181-204`, `Reads.swift:172-181`) — destructif, à protéger.
- 🟢 **Écriture cache atomique** (`.atomic`, `LocalDataStore.swift:44`) + garde-fou « recalcul vide » (`:130-132`) : le cache valide n'est pas écrasé par un compute vide. Bonne protection existante.
- 🟢 RAW jamais pruné → la vérité brute survit ; tout est reconstructible.

---

## 7. Réponses explicites aux questions

- **Pourquoi recalcule-t-elle trop ?** → `compute(days:60)` complet à chaque déclenchement (foreground, offload, import, reassign), garde-fou seulement sur le compte total de lignes ; `lastComputedRowCount` non persisté → recompute complet à chaque lancement. (P2)
- **Pourquoi lit/écrit au mauvais endroit ?** → Race deviceId `my-whoop`/`theo-whoop` : collecte sous placeholder, requête sous config, ré-alignement asynchrone. (P1)
- **Pourquoi le serveur intervient au démarrage ?** → Il **n'intervient pas** de façon bloquante ; `requestSync` est non bloquant et no-op sans config. Perception probablement due au recompute long au foreground. (hypothèse invalidée §4)
- **Pourquoi les données serveur importées ne s'affichent pas tout de suite ?** → L'import écrit le RAW puis déclenche un recompute 60 jours **long** (P4) ; l'UI n'affiche qu'après `saveCache`. Délai = durée du recompute, pas un bug d'affichage.
- **Pourquoi le cache revient à zéro ?** → Pas le cache lui-même (atomique + garde-fou) ; c'est le **recompute sous mauvais deviceId** (P1) qui produit du vide, et au tout premier run (cache vide) l'UI montre 0.
- **Pourquoi pas incrémental aujourd'hui ?** → Aucun watermark/dirty-flag par jour ; design « tout recalculer sur 60 jours ». (P2)
- **Le serveur doit-il fournir un dump SQLite brut ?** → Recommandé en option (§8, étape 5) : un dump des tables RAW est plus simple et plus fiable que l'API JSON jour-par-jour actuelle pour un restore complet. Mais le calcul doit rester **local**.
- **Quelle source de vérité ?** → **RAW SQLite = vérité unique.** Dérivé = cache reconstructible. Cible : une seule table dérivée SQLite (`dailyMetric`/`sleepSession`/`advice`) alimentée par le moteur local ; `cache.json` rétrogradé en simple projection UI (ou supprimé). Serveur = backup/restore du RAW uniquement.

---

## 8. Plan de refonte incrémentale (ordre recommandé)

> Principe : RAW = vérité. Dérivé = cache reconstructible, écrit par le moteur local dans SQLite. Incrémental par jour. Serveur optionnel = backup du RAW. **Casser le mécanisme actuel de stockage dérivé et de calcul sommeil est autorisé et nécessaire.**

**Étape 0 — Instrumentation (réversible, non invasif).**
- Ajouter des timings `os_signpost` / logs par phase dans `compute` (chunk sommeil, boucle quotidienne, write). Mesurer réellement P4 avant de toucher.
- Livrer l'outil `scripts/loop_diag.py` (§9) et capturer un état réel.

**Étape 1 — Geler le deviceId (corrige P1, priorité absolue).**
- Décider d'**un seul** deviceId canonique au démarrage **avant** tout insert : si config bundlée existe, ouvrir le collector directement sous `theo-whoop` (ne jamais insérer sous `my-whoop`).
- Rendre `reassignDevice` synchrone vis-à-vis du premier insert (ordonner bootstrap → configure → collect).
- Remplacer les `try?` du chemin chaud par une remontée d'erreur explicite (corrige P6).
- Tests : insert→reassign sans perte ; engine et collector partagent toujours le même id.

**Étape 2 — Réparer la segmentation du sommeil (corrige P3 + gros de P4).**
- Plafonner la durée de session (ex. 18h) et **splitter** sur gap > seuil (réduire `midSleepWakeMaxMin`, ne pas fusionner par-dessus minuit sans preuve de sommeil continu).
- Soustraire les `wakeGaps` de la durée (`end - start - gaps`).
- Borner la grille d'époques par session, pas par `min..max` global.
- S'appuyer sur la **méthode serveur** comme référence (cf. pipeline Python `iblur01@vps.dlnntheo.fr`, `server/ingest/`) — extraire ses seuils de segmentation et les porter/valider via le ParityHarness existant (`Tests/.../ParityHarness/SleepParityTests.swift`).
- Tests de non-régression : aucune session > plafond ; nuit 16→17 juin redevient plausible.

**Étape 3 — Incrémentalité par jour (corrige P2).**
- Table `derivedWatermark(deviceId, day, rawRowCount, computedAt)` ou dirty-flag par jour.
- `compute` ne recalcule qu'un jour si son `rawRowCount` (count des échantillons de la journée) a changé depuis `computedAt`.
- Persister `lastComputedRowCount`/watermark en DB (plus en mémoire) → pas de recompute complet au lancement.
- Recalcul complet = commande explicite, mesurée (`recomputeAll`).

**Étape 4 — Unifier le store dérivé (corrige P5).**
- Le moteur local écrit dans `dailyMetric`/`sleepSession`/`adviceSignal` (SQLite), pas dans `cache.json`.
- UI lit ces tables (via `Reads`). `cache.json` → supprimé ou réduit à un snapshot widget.
- Migration DB : aucune nouvelle table (elles existent), juste rerouter les écritures + backfill depuis cache.json existant une fois.

**Étape 5 — Serveur optionnel = backup du RAW.**
- Conserver `/v1/ingest-decoded` + `/v1/export/decoded` (RAW).
- Ajouter (optionnel) un endpoint dump SQLite brut pour restore rapide complet, au lieu de l'export jour-par-jour.
- Aucune dépendance serveur pour calculer : tout dérive du RAW local.

**Stratégie d'indexation** : PK composites `(deviceId, ts)` suffisent pour les plages. Ajouter au besoin un index `(deviceId, day)` matérialisé si on introduit un count par jour fréquent.

**Tests nécessaires** : P1 (race deviceId), P3 (cap/split sommeil + parité serveur), P3-perf (compute 8 jours < quelques secondes après fix), incrémental (1 jour modifié = 1 jour recalculé), garde-fous purge.

---

## 8bis. Corrections appliquées (2026-06-17)

Validées contre 9 jours de vraies données serveur (`RealVolumeTests`, fixtures via `scripts/fetch_fixtures.sh`).

| # | Correction | Fichiers | Preuve |
|---|---|---|---|
| P3 | Cap physiologique 16h/session + anti-chaînage `mergeMidSleepWakes` + HR obligatoire sur longs spans | `InBedDetection.swift` | bug 64h → 0 session > 16h ; max réel 14.6h |
| P4 | `classifyStill` O(n·fenêtre) → O(n) (prefix-sum) ; `rowsBetween`/`sessionRestingHR`/`sessionAvgRmssd` scans complets → recherche binaire/passe triée ; `buildEpochGrid` nourri par streams slicés par session | `InBedDetection.swift`, `SleepEngine.swift` | `detectSleep` 9j : 270s → 130s (debug) ; **parité sommeil préservée** (oracle Python OK) |
| P1 | `bootstrapStore` résout le deviceId bundlé avant de créer le collector | `BLEConnectionManager.swift` | plus d'écriture sous placeholder sur le chemin restore |
| P2 | Watermark `computedRowCount` persisté dans cache.json | `LoopModels.swift`, `LoopDataRepository.swift` | relance sans changement = pas de recompute 60j |
| P6 | Lectures DB loggées (`loggedRead`) au lieu de `try?` muet | `LocalMetricsEngine.swift` | échec de lecture visible en console, plus de 0 silencieux |
| P7 | Barre de progression pondérée par jours traités (`dates.count*3`) | `LocalMetricsEngine.swift` | chunks sommeil avancent de `chunkDays`, plus de blocage |

**Reste (coût plancher, pas un bug)** : la Welch PSD par-ancre (`hrvFromRR`→`hrvFrequency`) dans `extractFeatures` domine le temps « sain » de staging. Inhérente au modèle ; release (Accelerate) ≈ 5-10× plus rapide que les chiffres debug ci-dessus. Le cap borne désormais le nombre de FFT par session. Pistes futures si besoin : décimer les streams 1 Hz avant staging (30 s/époque rend le 1 Hz sur-échantillonné ~30×), ou vectoriser la PSD.

**deviceId** : après P1, le placeholder `my-whoop` n'est plus jamais persisté. La colonne `deviceId` reste (sécurité données, clé de tables, migration) mais la valeur est unique en pratique. Collapse total vers une constante unique = possible mais touche onboarding UI + tests → étape opt-in séparée, non faite sans validation.

## 8ter. Parité sommeil avec le Python serveur validé (2026-06-17)

Vérité-terrain : le `sleep.py` du serveur (VM `iblur01@vps...`) = `sleep.py` local (md5 identique
host/container/local) → le Python local est une référence valable. 9 jours réels comparés.

**Cause racine du désaccord Swift↔Python : représentation de la gravity.**
- Le pipeline Swift collapsait la gravity en **magnitude** `sqrt(x²+y²+z²)` puis re-différenciait.
- Python (`_gravity_deltas`) utilise `hypot(Δx,Δy,Δz)` = **norme du vecteur de changement**.
- La magnitude est aveugle à l'orientation : une rotation du poignet garde `|g|≈1` → `|Δ|g||≈0`
  → lu comme immobilité → journées éveillées fusionnées en sommeil (sessions 2-3× trop longues).
- La parité par-nuit passait quand même car les fixtures sont des nuits propres (peu de rotation) ;
  seule la donnée continue multi-jours exposait le bug.

**Correctifs (commits `662b930`, `6b2d760`) :**
- `gravityDeltaProxy` porte `_gravity_deltas` fidèlement ; `SleepStreams.gravity` = proxy de
  mouvement (plus la magnitude) ; câblé moteur + harness + tests.
- Port fidèle de `detect_sleep` : `detectInBedPeriods` (spans HR-confirmés + wake-gaps pontés),
  staging **par span** + insertion wake + trim Sleep-Period-Time. Retrait des pansements
  (cap 16h, anti-chaînage, HR-reject long-span) — Python n'en a aucun.

**Résultat (vs 11 sessions serveur validées, 9 jours) :** MAE durée **256 min → 22 min**,
**11/11 sessions** (compte exact), bornes souvent à la minute. Parité par-nuit + perf + cap-sanity
toutes vertes. Écarts résiduels (06-15 doze +167 min, 06-14 sieste +66 min) = subtilités du
**classifieur d'époques** (`SleepClassifier`/`SleepFeatures`), dans la tolérance — chantier futur
à rendement décroissant.

Repro : `swift test --filter testCompareWithServerSleep` (fixtures via `scripts/fetch_fixtures.sh`
+ sessions serveur via `/v1/sleep`).

## 9. Outil de diagnostic local

Livré : `scripts/loop_diag.py` — localise la DB (simulateur ou chemin fourni), imprime deviceIds, counts par table, min/max ts, jours couverts, état du cache.json. Voir le fichier pour l'usage.
