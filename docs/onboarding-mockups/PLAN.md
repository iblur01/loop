# Plan d'Onboarding Loop — Analyse Page par Page (Flowform & Liquid Glass iOS 26)

> **Statut** : Phase 2 (v2 après revues croisées UX/Produit et Accessibilité/Localisation) — Document d'architecture UX/produit à valider avant toute modification de code Swift.
> **Cible** : iOS 26+ · Format de référence iPhone (393 × 852 pt) · Mode clair et mode sombre · Local-first.
> **Références internes** : `DESIGN.md`, `docs/design/SPEC-DESIGN-LOOP.md`, `Loop/Features/Onboarding/OnboardingView.swift`, `Loop/Core/Preferences/UserPreferences.swift`, `Loop/Core/Health/HealthKitImporter.swift`, `Loop/Core/Health/HealthSampleImporter.swift`, `Loop/Features/Today/Widgets/TrainingAdviceWidget.swift`, `Loop/Features/Today/Widgets/FocusWidget.swift`.

---

## 1. Diagnostic de l'onboarding actuel et justification de la nouvelle séquence

### 1.1 Pourquoi l'onboarding actuel (`OnboardingView.swift`) ne remplit pas l'objectif produit

L'implémentation actuelle enchaîne 6 écrans (`name` → `health` → `bluetooth` → `notifications` → `connect` → `profile`) avec cinq limites majeures :

1. **Aucune mise en contexte au démarrage** : l'application demande « Comment tu t'appelles ? » dès la première seconde, sans montrer ce que Loop apporte au quotidien (un coach qui aide à décider jusqu'où pousser ou quand lever le pied) ni expliquer son architecture 100 % locale.
2. **Séquence Bluetooth fragmentée** : l'étape 3 (« Active le Bluetooth ») est un écran passif, séparé de l'étape 5 (« Connecte ton bracelet ») par la demande de notifications à l'étape 4.
3. **Accumulation de permissions système à froid** : l'utilisateur subit coup sur coup la feuille HealthKit, une injonction Bluetooth et la popup système de notifications avant d'avoir vu la moindre valeur produit.
4. **Incohérences rédactionnelles dans l'existant** : `Base.strings` et `NoSensorSheet.swift` mélangent le tutoiement (« Connecte ton bracelet ») et le vouvoiement (« Connectez votre bracelet », « Votre capteur est-il en mode association ? ») ainsi que du jargon familier (« suivez le tuto »), et alternent entre *bracelet*, *capteur* et *appareil*.
5. **Décalage avec le langage visuel iOS 26 de Loop** : l'onboarding actuel utilise des contrôles standard (`.roundedBorder`, `.borderedProminent`, `Stepper` brut) et des icônes multicolores (`.red`, `.blue`, `.orange`, `.green`), à rebours de `DESIGN.md` et de `SPEC-DESIGN-LOOP.md`.

### 1.2 Séquence retenue (8 écrans en mode « Flowform » strict)

Chaque écran porte **une seule question ou une seule action principale**, avec progression visible en haut (8 segments + bouton retour) et une option de repli claire (« Passer » / « Continuer sans… ») sur chaque étape facultative :

| # | Fichier maquette | Écran | Intention unique (Flowform) | Obligatoire ? |
|---|---|---|---|---|
| **01** | `01-welcome.html` | **Accueil** | Comprendre la promesse en une phrase (avec un aperçu visuel du conseil matinal) et démarrer — ou restaurer une sauvegarde `.loopbackup`. | Action de départ |
| **02** | `02-manifesto.html` | **Ce que Loop fait et ne fait pas** | Poser le contrat de confiance : guidage quotidien + calibration personnelle + 100 % local vs pas de dispositif médical ni de faux score propriétaire. | Lecture + validation |
| **03** | `03-healthkit.html` | **Connexion Apple Santé** | Relier l'historique Apple Santé en lecture seule via un bouton unique (sans liste technique de types dans l'UI Loop). | Facultatif (repli immédiat) |
| **04** | `04-band.html` | **Bracelet WHOOP 4.0** | Détecter et associer un bracelet en Bluetooth LE — ou continuer avec Apple Santé seul. | Facultatif |
| **05** | `05-profile.html` | **Profil minimal** | Vérifier ou renseigner les 4 repères physiologiques (âge, taille, poids, FC max si connue), pré-remplis si Santé a été relié. | Facultatif (auto-estimation) |
| **06** | `06-goals.html` | **Objectifs sportifs** | Choisir ses pratiques sportives principales (course, natation, salle, marche, vélo… : choix multiples) sans mélanger d'autres réglages. | Facultatif |
| **07** | `07-sync.html` | **Première synchronisation** | Montrer honnêtement l'avancement par source (Apple Santé, bracelet, calcul local), sans bloquer l'utilisateur si le transfert est long. | Transition (passable en tâche de fond) |
| **08** | `08-ready.html` | **Écran final & accès au coach** | Montrer concrètement le guidage quotidien (« Ce que tu peux faire / éviter aujourd'hui ») dans son état réel de calibration, proposer l'alerte matinale et ouvrir Loop. | Clôture (`onboardingComplete = true`) |

---

## 2. Principes transverses, charte éditoriale et contraintes non négociables

### 2.1 Intégrité scientifique et honnêteté des données
- **Aucun chiffre physiologique présenté comme validé médicalement** : Loop produit des estimations d'entraînement et de récupération à partir des capteurs disponibles.
- **Aucune équivalence affirmée avec un score propriétaire** : les termes *Récupération*, *Strain*, *Sommeil*, *VFC (HRV)* et *FC repos (RHR)* désignent des grandeurs physiologiques calculées par les algorithmes locaux de Loop (`LoopStrapEngine`), jamais la copie certifiée d'un indice commercial.
- **Calibration et confiance explicites** : tant que l'historique personnel est inférieur à la fenêtre requise (14 à 28 jours selon l'indicateur, ex. ratio de charge aiguë/chronique EWMA 7j/28j dans `TrainingAdviceEngine`), Loop affiche un badge **Calibration en cours** ou le niveau de confiance réel (`Confiance faible / moyenne / élevée`).

### 2.2 Lecture seule vis-à-vis d'Apple Santé & confidentialité locale
- **Lecture seule stricte** : `HealthKitImporter.requestAllAccess()` appelle `healthStore.requestAuthorization(toShare: [], read: Self.allReadTypes)`. Aucun échantillon n'est jamais écrit ni modifié dans Apple Santé.
- **100 % sur l'iPhone** : toutes les données résident dans `whoop.sqlite` et `cache.json`. Aucun compte, aucun cloud obligatoire, aucun serveur distant.

### 2.3 Réconciliation Liquid Glass iOS 26 & `SPEC-DESIGN-LOOP.md`
- **Note importante sur les maquettes HTML** : l'effet Liquid Glass est **une approximation visuelle en HTML/CSS** (`backdrop-filter: blur(24px) saturate(180%)`, reflets spéculaires `inset 0 1px 0`, ombres douces et transitions morphing entre étapes). Il ne s'agit pas du rendu shader réel d'iOS 26 (`.glassEffect(.regular)` / `GlassEffectContainer`).
- **Règle d'or (`SPEC-DESIGN-LOOP.md` §1.4 & §5)** : *« Verre pour ce qui flotte, opaque pour ce qui se lit »* :
  - **En Liquid Glass (translucide avec reflets et morphing)** : la barre supérieure flottante (bouton retour, indicateur de progression segmenté, bouton « Passer »), le dock d'action inférieur (`GlassEffectContainer` regroupant le bouton primaire `.glassProminent` et l'action secondaire `.glass`), et les capsules de statut.
  - **En surface opaque (`surface.card` `#FFFFFF` / `#1A1A1D` et `surface.nested` `#F2F2F6` / `#2A2A2E`)** : toutes les cartes de lecture, les explications du contrat de confiance, les champs de profil, les tuiles de sport et l'aperçu du coach. **Zéro verre sur verre.**
  - **Une seule teinte d'accent par écran** : fini l'arc-en-ciel d'icônes (`.red`, `.blue`, `.orange`, `.green`) de l'ancien `OnboardingView.swift`. Les couleurs d'état (`state.good`, `state.fair`, `state.poor`, `state.neutral`) sont réservées aux statuts réels et toujours accompagnées d'une icône et d'un mot.

### 2.4 Charte rédactionnelle FR / EN (correction des incohérences existantes)
1. **Tutoiement exclusif en français (`tu / ton / ta`)** : suppression de tout vouvoiement résiduel (comme celui présent dans `NoSensorSheet.swift`).
2. **Vocabulaire normé** :
   - **Bracelet** (*Band*) : le bracelet compatible WHOOP 4.0 porté au poignet.
   - **Appareil** (*Device*) : l'iPhone ou l'iPad sur lequel tourne Loop.
   - **Guide / Instructions** (*Guide / Instructions*) : remplace le terme familier « tuto ».
3. **Concision des boutons (< 26 caractères)** : chaque libellé d'action est calibré pour tenir sur une seule ligne à 393 px en taille standard et ne jamais dépasser 2 lignes en Dynamic Type Accessibilité (`+25 %`).

---

## 3. Analyse détaillée écran par écran

---

### Écran 01 — Accueil (`01-welcome.html`)

- **But de l'écran** : Énoncer la promesse de Loop en une phrase limpide et montrer immédiatement un aperçu visuel sobre de ce que l'utilisateur obtiendra chaque matin (le conseil quotidien : jusqu'où pousser, quand récupérer), tout en affirmant la confidentialité locale.
- **Seule décision ou action demandée** :
  - Action primaire : **« Commencer »** (`Get started`) → passe à l'écran 02.
  - Action secondaire : **« Restaurer une sauvegarde »** (`Restore a backup`, sous-texte `.loopbackup`) → ouvre `UIDocumentPickerViewController` via `BackupCoordinator`.
- **Données réellement disponibles à ce moment-là** :
  - Aucune donnée physiologique personnelle.
  - La carte d'illustration centrale montre la structure du conseil matinal avec la mention explicite **`Exemple d'aperçu · Aucune mesure personnelle`** (`Sample preview · No personal data yet`), sans aucun faux pourcentage présenté comme acquis.
- **Ce qui est facultatif / modifiable plus tard** :
  - La restauration d'une sauvegarde `.loopbackup` reste accessible à tout moment dans `Profil › Sauvegarde`.
- **Ce qui est refusé ou impossible & message de repli** :
  - Fichier `.loopbackup` invalide, incomplet ou corrompu lors d'une tentative de restauration : aucune donnée locale n'est écrasée ; un message calme propose de réessayer ou de démarrer une configuration neuve.
- **États vides et d'erreur modélisés** :
  - *État nominal* : Promesse en une phrase + aperçu conceptuel du coach quotidien + pilule « 100 % sur cet iPhone · Sans compte ».
  - *État d'erreur (échec de restauration `.loopbackup`)* : Bannière sobre (`state.poor` + icône `exclamationmark.triangle.fill`) :
    - FR : « Ce fichier n'est pas une sauvegarde Loop valide. Aucune donnée n'a été modifiée. Tu peux choisir un autre fichier `.loopbackup` ou commencer une configuration neuve. »
    - EN : « This file isn't a valid Loop backup. No data was changed. You can choose another `.loopbackup` file or start a fresh setup. »

---

### Écran 02 — Ce que Loop fait et ne fait pas (`02-manifesto.html`)

- **But de l'écran** : Poser un cadre honnête et rassurant en opposant clairement les engagements de Loop (guidage quotidien, calibration individuelle avec niveau de confiance, stockage 100 % local) et ses limites assumées (pas un dispositif médical, pas une copie d'un score propriétaire, aucune écriture dans Santé).
- **Seule décision ou action demandée** :
  - Action primaire : **« Continuer »** (`Continue`) → passe à l'écran 03.
- **Données réellement disponibles à ce moment-là** :
  - Aucune donnée personnelle requise. L'écran reflète fidèlement l'architecture de `LoopStrapEngine` et `HealthReconciliation`.
- **Ce qui est facultatif / modifiable plus tard** :
  - Un bloc repliable optionnel (« Comment fonctionne la période de calibration ? ») permet aux curieux de lire comment Loop établit les lignes de base sur 14 à 28 jours sans alourdir la lecture principale.
- **Ce qui est refusé ou impossible & message de repli** :
  - Aucun appel système ni permission sur cet écran : aucun échec possible.
- **États vides et d'erreur modélisés** :
  - *État nominal* : Deux cartes opaques (`surface.card`) très lisibles : **« Ce que Loop fait »** (3 engagements) et **« Ce que Loop ne fait pas »** (3 limites claires).
  - *État alternatif (Détail calibration & incertitude déplié)* : Explique ce qui se passe lorsque deux signaux se contredisent (ex. nuit courte mais VFC élevée → Loop affiche `Signaux contradictoires` au lieu d'inventer une conclusion tranchée).

---

### Écran 03 — Connexion Apple Santé (`03-healthkit.html`)

- **But de l'écran** : Relier Apple Santé en **lecture seule** via un bouton unique pour récupérer les séances de sport, la fréquence cardiaque, la VFC, le sommeil et le profil de base déjà enregistrés sur l'iPhone (Apple Watch, Garmin, Strava, etc.).
- **Seule décision ou action demandée** :
  - Action primaire : **« Connecter Apple Santé »** (`Connect Apple Health`) → appelle `HealthKitImporter.shared.requestAllAccess()` (`toShare: []`, `read: allReadTypes`).
  - Action secondaire : **« Continuer sans Santé »** (`Skip Apple Health`) → passe à l'écran 04.
- **Données réellement disponibles à ce moment-là** :
  - Disponibilité du framework sur l'appareil (`HealthKitImporter.isAvailable` via `HKHealthStore.isHealthDataAvailable()`).
  - Statut de la demande (`authorization` : `.notRequested`, `.requested`, `.unavailable`).
  - **Règle de vérité iOS** : Apple ne permettant jamais à une application de savoir si l'utilisateur a coché ou décoché les permissions de **lecture**, Loop n'affiche jamais « Accès refusé » sur simple retour de la feuille système. Elle indique que la demande a été enregistrée et vérifie au moment de l'import si des échantillons arrivent.
- **Ce qui est facultatif / modifiable plus tard** :
  - Entièrement facultatif. Activable ou vérifiable plus tard dans `Profil › Apple Santé`.
  - Aucune liste de types de données à cocher dans Loop : la sélection granulaire se fait exclusivement dans la feuille système officielle d'iOS.
- **Ce qui est refusé ou impossible & message de repli** :
  1. **Apple Santé absent sur l'appareil (ex. iPad, `isAvailable == false`)** :
     - FR : « Apple Santé n'est pas disponible sur cet appareil. Tu peux continuer directement avec un bracelet compatible ou importer une sauvegarde. »
     - EN : « Apple Health isn't available on this device. You can continue with a compatible band or import a backup. »
  2. **Refus dans la feuille iOS ou aucune donnée trouvée** :
     - FR : « Autorisations enregistrées. Pour protéger ta vie privée, iOS n'indique pas quelles lectures sont refusées. Si tes données n'apparaissent pas, vérifie Réglages › Santé › Accès aux données › Loop. »
     - EN : « Permissions saved. To protect your privacy, iOS doesn't disclose which read permissions were denied. If your data doesn't show up, check Settings › Health › Data Access › Loop. »
- **États vides et d'erreur modélisés** :
  - *État nominal* : Résumé en 3 lignes de ce que Loop lit (Séances · Sommeil, FC & VFC · Poids & année de naissance) + badge `Lecture seule · Rien n'est écrit dans Santé` + bouton unique « Connecter Apple Santé ».
  - *État repli / indisponible ou refus silencieux iOS* : Encart calme (`state.neutral` / `state.fair`) expliquant le comportement de confidentialité d'iOS et le chemin `Réglages › Santé`, avec bouton « Continuer ».

---

### Écran 04 — Bracelet WHOOP 4.0 (`04-band.html`)

- **But de l'écran** : Détecter et associer en Bluetooth LE un bracelet compatible WHOOP 4.0, tout en précisant clairement que Loop fonctionne aussi très bien sans bracelet si Apple Santé est connecté.
- **Seule décision ou action demandée** :
  - Action primaire :
    - Avant scan : **« Rechercher mon bracelet »** (`Search for my band`).
    - Capteur détecté : **« Associer ce bracelet »** (`Pair this band`).
    - Connecté : **« Continuer »** (`Continue`).
  - Action secondaire permanente : **« Continuer sans bracelet »** (`Continue without a band`).
- **Données réellement disponibles à ce moment-là** :
  - État temps réel de `DeviceConnectionViewModel.phase` (`.noSensor`, `.scanning`, `.detected(name, model, battery)`, `.bonding`, `.connected`).
  - Dès la détection : nom annoncé (`WHOOP 4.0 · 4B2A`), modèle (`WHOOP 4.0`) et pourcentage de batterie (`batteryPct`).
- **Ce qui est facultatif / modifiable plus tard** :
  - Entièrement facultatif. Le jumelage peut être lancé plus tard depuis l'onglet `Appareil` (`DeviceView`).
- **Ce qui est refusé ou impossible & message de repli** :
  1. **Bluetooth désactivé ou permission Bluetooth refusée pour Loop** :
     - FR : « Le Bluetooth est désactivé ou non autorisé pour Loop. Active-le dans Réglages pour détecter ton bracelet, ou continue sans bracelet. »
     - EN : « Bluetooth is off or not allowed for Loop. Enable it in Settings to detect your band, or continue without a band. »
  2. **Aucun bracelet détecté après 15 s (état vide)** :
     - Instructions claires sans jargon : retirer le bracelet du poignet, tapoter fermement le dessus jusqu'à voir la **LED bleue clignoter** (accompagnée d'une étiquette textuelle explicite pour l'accessibilité daltonisme), puis relancer la recherche.
  3. **Échec de l'association (`.bonding` interrompu par un ancien jumelage système)** :
     - FR : « L'association n'a pas abouti. Si ce bracelet a déjà été relié à cet iPhone, oublie-le dans Réglages › Bluetooth, puis réessaie. »
     - EN : « Pairing didn't complete. If this band was previously paired with this iPhone, forget it in Settings › Bluetooth and try again. »
- **États vides et d'erreur modélisés** :
  - *État nominal (Bracelet détecté)* : Indicateur visuel + textuel « LED bleue clignotante » et carte du bracelet détecté (`WHOOP 4.0 · 78 % de batterie`) prête à être associée.
  - *État vide / erreur (Aucun bracelet détecté ou Bluetooth coupé)* : Diagnostic calme en 2 points + boutons « Réessayer » et « Continuer sans bracelet ».

---

### Écran 05 — Profil minimal (`05-profile.html`)

- **But de l'écran** : Permettre de vérifier ou renseigner les **4 paramètres physiologiques** demandés (**Âge, Taille, Poids, FC maximale si connue**, ainsi qu'un prénom optionnel) dans une seule carte épurée. Si Apple Santé a fourni la date de naissance et le poids, ces valeurs sont **déjà pré-remplies** : l'utilisateur valide l'écran en un seul tap.
- **Seule décision ou action demandée** :
  - Action primaire : **« Continuer »** (`Continue`).
  - Action secondaire : **« Passer »** (`Skip`) → conserve les estimations automatiques du moteur.
- **Données réellement disponibles à ce moment-là (et transparence sur l'usage réel du moteur)** :
  - **Ce que le moteur utilise dès aujourd'hui (`UserPreferences.swift` / `LocalMetricsEngine`)** :
    - **Âge** (`healthAge` lu depuis `HKHealthStore().dateOfBirthComponents()`) : sert à estimer la FC maximale par la formule de Tanaka ($208 - 0{,}7 \times \text{âge}$) lorsque l'utilisateur ne connaît pas sa FC max réelle.
    - **FC maximale personnelle** (`userMaxHeartRate`, bornes `120...230 bpm`, provenance `.measured`, `.manual` ou `.ageEstimate`) : calibre directement les 5 zones de fréquence cardiaque et le calcul du Strain.
    - **Prénom** (`firstName`) : personnalise l'accueil.
  - **Ce qui est lu dans Santé ou préparé pour les prochains jalons (BMR / dépense énergétique)** :
    - **Poids** (`HealthSampleKind.bodyMass` en base SQLite) et **Taille** : utilisés pour les estimations métaboliques (calories BMR Mifflin-St Jeor prévues en P1-15). L'interface indique honnêtement que la FC max (ou l'âge) est le seul paramètre qui modifie le calcul du Strain aujourd'hui, et que laisser la FC max vide active l'estimation automatique.
- **Ce qui est facultatif / modifiable plus tard** :
  - Tous les champs sont facultatifs. Modifiables à tout moment dans l'onglet `Profil` (`BodyProfileCard` et `MaxHeartRateCard`).
- **Ce qui est refusé ou impossible & message de repli** :
  - Saisie d'une valeur hors bornes physiologiques (FC max hors `120...230 bpm` ou âge hors `10...100 ans`) :
    - Le champ invalide est signalé par `aria-invalid="true"`, une icône `exclamationmark.triangle.fill` et un message précis sous la ligne (jamais par la couleur rouge seule).
    - FR : « Entre une FC maximale entre 120 et 230 bpm, ou laisse vide pour garder l'estimation automatique. »
    - EN : « Enter a maximum heart rate between 120 and 230 bpm, or leave blank to keep the automatic estimate. »
- **États vides et d'erreur modélisés** :
  - *État nominal (Pré-rempli avec Santé)* : Âge (`29 ans · Santé`) et Poids (`72 kg · Santé`) pré-remplis, Taille (`178 cm`), FC max sur `Auto (≈ 188 bpm · estimée par l'âge)` avec mention explicite que l'estimation Tanaka est une moyenne de population approximative.
  - *État vide / erreur de saisie* : Champs non pré-remplis + saisie d'une FC max hors bornes (`245 bpm`) affichant le message de correction calme et un bouton « Revenir sur Auto ».

---

### Écran 06 — Objectifs sportifs (`06-goals.html`)

- **But de l'écran** : Permettre à l'utilisateur d'indiquer ses disciplines sportives principales (**Course, Natation, Salle / Musculation, Marche, Vélo, HIIT / Cross, Mobilité** — choix multiples possibles) sur un écran dédié à cette seule question.
- **Seule décision ou action demandée** :
  - Sélectionner un ou plusieurs sports (boutons accessibles `role="checkbox"` / `aria-pressed`) puis toucher **« Continuer »** (`Continue`).
  - Action secondaire : **« Passer »** (`Skip`).
- **Données réellement disponibles à ce moment-là (et transparence sur le moteur)** :
  - Les types de sport correspondent aux cas de `WorkoutSport.Kind` (`Loop/Shared/DesignTokens/WorkoutSport.swift`) : `.run`, `.swim`, `.strength`, `.walk`, `.cycling`, `.hiit`, `.yoga`.
  - Dans `TrainingAdviceEngine`, le moteur dispose déjà de règles d'analyse de volume spécifiques pour la course (`volumeRun`), la natation (`volumeSwim`) et la musculation (`volumeStrength`), en plus de la charge globale.
  - **Honnêteté affichée sur l'écran** : une note précise que **toutes tes séances** (22 sports reconnus via Apple Santé ou détectés par le bracelet) sont automatiquement importées et prises en compte dans ta charge quotidienne, même si tu ne les coches pas ici.
- **Ce qui est facultatif / modifiable plus tard** :
  - Aucune sélection n'est obligatoire (0, 1 ou plusieurs choix).
- **Ce qui est refusé ou impossible & message de repli** :
  - Si aucun sport n'est sélectionné : aucune erreur ; l'interface indique calmement que toutes les activités détectées seront suivies sans filtre.
- **États vides et d'erreur modélisés** :
  - *État nominal* : Sélection multiple active (*Course à pied*, *Salle & musculation*, *Natation*) avec compteur discret et note d'ouverture multi-sports.
  - *État vide (Aucune sélection)* : Grille vierge avec encart rassurant :
    - FR : « Aucun sport sélectionné : Loop importera et analysera automatiquement toutes tes activités (course, marche, vélo, natation, salle…) dès qu'elles apparaissent dans Santé ou sur ton bracelet. »
    - EN : « No sport selected: Loop will automatically import and analyze all your activities (running, walking, cycling, swimming, strength…) as soon as they appear in Health or on your band. »

---

### Écran 07 — Première synchronisation (`07-sync.html`)

- **But de l'écran** : Exécuter la première lecture des sources connectées et le premier calcul local en affichant une **progression honnête par source**, sans fausse barre de chargement globale ni blocage si le transfert Bluetooth prend du temps.
- **Seule décision ou action demandée** :
  - Action primaire (dès que la première passe est prête) : **« Voir mon aperçu »** (`See my preview`).
  - Action immédiate pendant un import long : **« Continuer en arrière-plan »** (`Continue in background`).
- **Données réellement disponibles à ce moment-là** :
  - **Source 1 — Apple Santé** : `HealthKitImporter.shared.workoutCount` (séances importées) et `HealthSampleImporter.states` (échantillons FC, VFC, sommeil, pas).
  - **Source 2 — Bracelet WHOOP 4.0** : `SyncCoordinator.status` (`.syncing(.fromStrap)`, `.connectedIdle`, `.offline`, `.strapStuck`, `.error`) et nombre de lots reçus.
  - **Moteur local (`LoopDataRepository`)** : `repository.computeProgress` (`stage`, `completed`, `total`).
  - **Honnêteté stricte** : si le téléchargement initial du bracelet est en cours, l'écran explique qu'iOS poursuit la synchronisation en arrière-plan (`HealthContinuedSync` & `BLEOffloadCoordinator`) et qu'il n'est pas nécessaire de garder cet écran ouvert.
- **Ce qui est facultatif / modifiable plus tard** :
  - Attendre la fin complète de l'offload BLE est facultatif : l'utilisateur peut entrer dans l'application immédiatement, où l'accessoire de barre d'onglets (`tabViewBottomAccessory`) affiche la progression restante.
- **Ce qui est refusé ou impossible & message de repli** :
  1. **Aucune source connectée aux étapes 03 et 04** :
     - Aucun faux spinner n'est affiché. L'écran indique honnêtement qu'aucune source n'est encore reliée et propose d'entrer directement dans Loop.
  2. **Bracelet éloigné ou transfert Bluetooth mis en pause** :
     - FR : « Transfert du bracelet en pause. Garde ton bracelet près de l'iPhone : les mesures déjà reçues sont enregistrées et la synchro reprendra toute seule. »
     - EN : « Band transfer paused. Keep your band close to your iPhone: received data is saved and syncing will resume automatically. »
- **États vides et d'erreur modélisés** :
  - *État nominal* : Cartes d'avancement détaillées par source (Apple Santé : `42 séances · Sommeil & VFC lus` ; Bracelet : `Synchronisation des trames en cours…` ; Calcul local : `Lignes de base initialisées`).
  - *État vide / erreur (Aucune source connectée ou transfert BLE interrompu)* : État explicite permettant de continuer immédiatement sans anxiété.

---

### Écran 08 — Écran final et accès au coach (`08-ready.html`)

- **But de l'écran** : Conclure l'onboarding en montrant à quoi ressemble concrètement le coach quotidien de Loop (**ce que tu peux faire aujourd'hui** / **ce qu'il vaut mieux éviter**), avec une transparence totale sur l'état de calibration au Jour 1, et proposer d'activer l'alerte matinale.
- **Seule décision ou action demandée** :
  - Option contextuelle sur l'écran : bascule **« Alerte matinale »** (`Morning readiness alert`, sous-titre : *« Récupération prête au réveil et batterie faible »*) qui déclenche `UNUserNotificationCenter.current().requestAuthorization` au clic.
  - Action primaire finale : **« Ouvrir Loop »** (`Open Loop`) → appelle `prefs.completeOnboarding()` et ouvre l'accueil (`TodayView`).
- **Données réellement disponibles à ce moment-là (fidélité stricte au moteur)** :
  - **Si Apple Santé a fourni un historique suffisant (≥ 14–28 jours)** :
    - L'aperçu présente la synthèse réelle du jour (`FocusWidget` + `TrainingAdviceWidget`) structurée en deux repères lisibles (*Ce que tu peux faire aujourd'hui* / *Ce qu'il vaut mieux éviter*), accompagnée de la jauge de confiance réelle (`TrainingConfidenceRow` : 3 segments + mot `Confiance moyenne` ou `Calibration en cours`).
  - **Si l'utilisateur démarre à froid (Jour 1 sans historique Santé ni bracelet déjà synchronisé)** :
    - Conformément à `TrainingAdviceWidget.swift` (`phase == .calibration` / `.absent`), **Loop n'invente aucun score ni conseil factice**.
    - La carte affiche l'état réel **« Jour 1 · En calibration »** : elle montre les deux rubriques (*Ce que tu peux faire aujourd'hui* / *À éviter*) en expliquant qu'il faut d'abord enregistrer tes premières nuits et séances pour calibrer tes repères personnels sur 14 à 28 jours.
- **Ce qui est facultatif / modifiable plus tard** :
  - La bascule « Alerte matinale » est facultative.
  - Tous les réglages (profil, objectifs de sommeil/réveil à `8 h 00` / `07:00`, sources Santé et bracelet) restent modifiables dans les onglets `Appareil` et `Profil`, et l'onboarding peut être relancé depuis `Profil › Avancé`.
- **Ce qui est refusé ou impossible & message de repli** :
  - Si l'utilisateur active « Alerte matinale » mais refuse la permission système iOS : la bascule revient en position désactivée avec une note discrète :
    - FR : « Notifications désactivées dans iOS. Tu pourras les autoriser dans Réglages › Notifications › Loop. »
    - EN : « Notifications are turned off in iOS. You can allow them in Settings › Notifications › Loop. »
- **États vides et d'erreur modélisés** :
  - *État nominal (Avec historique Santé importé)* : Carte du Coach montrant un exemple concret de lecture prudente (*Ce que tu peux faire* : séance aérobie ou renforcement modéré ; *À éviter aujourd'hui* : cumuler un second effort maximal sur une récupération encore en calibration) + jauge `Confiance modérée · Calibration en cours` + bascule `Alerte matinale`.
  - *État vide / Jour 1 sans historique (`Jour 1 · En calibration`)* : Carte honnête expliquant qu'aucune conclusion n'est tirée sans mesures, précisant le calendrier de calibration (première lecture dès demain matin, référence consolidée sur 14 à 28 jours) + note de repli si les notifications iOS sont refusées.

---

## 4. Matrice de vérification d'accessibilité et parité linguistique FR / EN

| Critère | Spécification et implémentation dans `docs/onboarding-mockups/` |
|---|---|
| **Dimensions & Responsive** | Viewport iPhone `393 × 852 px`, `overflow-x: hidden` strict (zéro défilement horizontal), marges latérales `16 px` (`LoopMeasure.screenGutter`), rayons de carte `26 px` (`radius.card`) et `18 px` (`radius.nested`). |
| **Clair & Sombre** | Tokens exacts de `SPEC-DESIGN-LOOP.md` §2.1 : `bg.base` (`#F2F2F7` / `#000000`), `surface.card` (`#FFFFFF` / `#1A1A1D`), `surface.nested` (`#F2F2F6` / `#2A2A2E`), `text.primary` (`#0B0B0C` / `#FFFFFF`), `text.secondary` (`#5E5E66` / `#A6A6AD`), `stroke.card` (`rgba(0,0,0,0.06)` / `rgba(255,255,255,0.08)`). |
| **Vérification FR / EN parallèle** | Trois modes d'affichage dans le banc d'essai : **FR seul**, **EN seul**, et **FR + EN en parallèle** (sous-titrage bilingue direct dans chaque composant pour contrôler visuellement la chasse typographique à 393 px). |
| **Dynamic Type** | Bascule `100 % (Standard)` vs `125 % (Accessibilité)` : les grilles 2 colonnes basculent automatiquement sur 1 colonne et les valeurs/unités s'empilent proprement sans troncature. |
| **Réduire les transparences** | Bascule dédiée désactivant `backdrop-filter` sur la barre supérieure et le dock inférieur pour les remplacer par des surfaces 100 % opaques à bordure franche (`1px solid`). |
| **Réduire les animations** | Respect de `@media (prefers-reduced-motion: reduce)` et bascule manuelle : coupe la pulsation de la LED bleue, les spinners continus et les transitions glissées. |
| **VoiceOver & Clavier** | Déplacement automatique du focus sur le titre `<h1>` de l'écran actif à chaque changement d'étape, attributs `role="progressbar"`, `role="checkbox"`, `aria-invalid`, `aria-live="polite"`, et cibles tactiles `≥ 44 × 44 px`. |

---

## 5. Questions ouvertes (à valider avant de passer au code Swift)

1. **Persistance de la taille, du poids et de l'âge manuels (Écran 05)** :
   - Aujourd'hui, `UserPreferences.swift` persiste `firstName`, `unitSystem`, `wakeHour`/`wakeMinute`, `sleepTargetMin` et `userMaxHeartRate` (avec un `age: Int?` lié à l'estimation Tanaka), tandis que l'âge (`healthAge`) et le poids (`bodyMass`) sont lus depuis Apple Santé. Par ailleurs, `LocalMetricsEngine` n'utilise actuellement que la FC max (ou l'âge via Tanaka) pour calculer le Strain ; la taille et le poids serviront au calcul futur des calories (BMR Mifflin-St Jeor, P1-15).
   - **À valider** : Souhaites-tu ajouter `manualAge: Int?`, `heightCm: Double?` et `weightKg: Double?` dans `UserPreferences` dès la Phase Code de l'onboarding, ou préfères-tu ne demander sur l'écran 05 que **Prénom + Âge / FC max** tant que l'algorithme BMR n'est pas branché ?
2. **Persistance des objectifs sportifs (Écran 06)** :
   - `WorkoutSport.Kind` définit déjà les 22 sports reconnus et `TrainingAdviceEngine` possède des règles de volume pour `run`, `swim` et `strength`, mais `UserPreferences` ne stocke pas encore de `preferredSports`.
   - **À valider** : Confirmes-tu l'ajout de `preferredSports: Set<String>` dans `UserPreferences` (et dans `LoopCache` pour la sauvegarde `.loopbackup`) afin de personnaliser l'ordre d'affichage des sports et les conseils, tout en conservant l'import et la détection automatiques de tous les sports ?
3. **Réglage de l'objectif de sommeil (`8 h 00`) et de l'heure de réveil (`07:00`)** :
   - Pour respecter strictement la règle Flowform (« une seule question par écran »), l'écran 06 est dédié aux **Objectifs sportifs**, et l'objectif de sommeil / réveil utilise ses valeurs par défaut (`8 h 00` et `07:00`, modifiables dans `Profil` ou via un tiroir optionnel sur l'écran 06).
   - **À valider** : Préfères-tu garder ce tiroir optionnel replié sur l'écran 06, ajouter un 9e micro-écran dédié au sommeil/réveil, ou laisser les valeurs par défaut `8 h 00` / `07:00` pour alléger l'onboarding ?
4. **Comportement après restauration d'une sauvegarde `.loopbackup` (Écran 01)** :
   - Lorsqu'un utilisateur restaure un fichier `.loopbackup` dès l'écran 01, ses données SQLite et son `LoopCache` sont restaurés, mais les autorisations système iOS (HealthKit et jumelage Bluetooth) sont propres à l'appareil.
   - **À valider** : Après une restauration réussie sur l'écran 01, faut-il envoyer l'utilisateur directement aux écrans **03 (Apple Santé)** et **04 (Bracelet)** puis terminer l'onboarding (en sautant Profil et Objectifs déjà restaurés) ? *(Recommandation : oui).*
5. **Placement de la permission de notifications (Écran 08 vs étape dédiée)** :
   - La demande de notification (« Alerte matinale & batterie faible ») est intégrée sous forme de bascule explicite sur l'écran 08 au lieu d'un écran interstitiel au milieu du parcours.
   - **À valider** : Ce placement sur l'écran final te convient-il, ou préfères-tu un écran dédié juste avant l'écran final ?
