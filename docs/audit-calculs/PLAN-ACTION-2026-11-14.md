# Plan d'action — un moteur de calcul Loop fiable et personnalisé

Date : 14 novembre 2026  
Entrées : `AUDIT.md`, `RECHERCHE-COMPLETE-2026-11-14.md`, code Swift existant et sauvegardes de 13 h 01 et 13 h 08.  
Statut : plan d'exécution. Aucun correctif n'est réalisé par ce document.

## 1. Objectif produit et principes

Loop doit aider un sportif à comprendre sa nuit, ses entraînements et ses tendances personnelles à partir des données réellement disponibles. Il doit pouvoir répondre : **qu'est-ce qui a été observé, par quel appareil, à quel moment, avec quelle couverture et quelle confiance ?** Les résultats doivent rester reproductibles, corrigibles et lisibles ; une valeur absente ne devient jamais silencieusement zéro.

Le but n'est pas d'imiter un score propriétaire à partir de quelques exemples, ni de présenter un état médical global comme mesuré. Les scores deviennent utiles quand leurs composantes, leur domaine d'application et leurs limites sont vérifiés. On expose séparément sommeil, charge cardiovasculaire, séances, récupération physiologique et ressenti ; la charge musculaire ne se déduit pas précisément de la seule FC.

Architecture retenue pour démarrer : **moteur local modulaire et rejouable**, avec étude d'un serveur optionnel de calcul et d'expérimentation. Le souhait récent de l'utilisateur d'étudier un serveur prévaut sur l'ancienne orientation exclusivement locale comme cible de recherche. La localisation du calcul est une décision expérimentale, pas un critère de précision. Pas de déploiement ni d'envoi externe de données prévu dans cette phase de planification.

## 2. Recoupement et arbitrages

| Sujet | Éléments confirmés | Décision |
|---|---|---|
| Nuit du 13 au 14 | Sur la fenêtre commune, 62,3 min classées éveil par Apple Watch sont classées sommeil par Loop ; ce n'est pas une mesure d'erreur contre PSG. Le code absorbe les éveils courts et n'identifie pas l'éveil immobile dans le cas examiné. | Traiter les états éveil/sommeil/inconnu et la qualité avant d'affiner les stades. Comparer à Watch et au journal, puis éventuellement PSG. |
| Course 13/11 | Watch : 14:26:44–15:42:38, 10,027 km ; Loop : bloc 13:54:26–17:00:11, englobant la marche. Sur les échantillons appariés, la différence absolue moyenne de FC est d'environ 1 bpm. | Utiliser les séances explicites pour les bornes, réconcilier prudemment et calculer la charge dans les fenêtres réellement observées. Ne pas présumer qu'une source FC domine toujours. |
| Cache / calcul incrémental | Un refresh de 3 jours peut remplacer l'ensemble des surfaces après calcul ; le gel de jours anciens et les empreintes par nombre de lignes peuvent manquer des modifications. | Reproduire par tests, puis assurer publication atomique, invalidation par révisions et parité avec un recalcul complet. |
| Mouvement / respiration | L'algorithme applique des coefficients d'actigraphie à des deltas gravité mis à l'échelle ; cette équivalence de signal n'est pas démontrée. Sur la nuit examinée, le canal resp ne contient que 2 valeurs. | Vérifier unité, sens du canal et couverture ; ne pas ajuster arbitrairement le diviseur ni inférer une respiration non validée. |
| Strain | Contribution dès 20 % de réserve FC, y compris en dessous des zones annoncées ; FC max estimée sans âge depuis le pool. | Séparer charge journalière et entraînement, rendre la FC max vérifiable, comparer plusieurs modèles sur cas annotés ; ne pas imposer d'emblée 50 %. |
| Récupération | Dispersion MAD normalisée remultipliée, documentation divergente, données parfois absentes, calibration courte. | Corriger l'incohérence mathématique après test de référence ; signaler historique et qualité ; mesurer la stabilité des tendances. |
| Serveur / IA | Un serveur facilite expérimentation et replay mais n'ajoute pas de signal. Le LLM n'est pas une mesure physiologique. | Benchmarker local/serveur ; IA explicative et facultative, avec entrées structurées et vérification des chiffres. |

### Corrections de lecture de la recherche externe

- La sauvegarde 13 h 08 **contient** 670 séances et 2 174 572 échantillons Santé : l'affirmation que les deux sauvegardes ont des tables vides est contradictoire. Celle de 13 h 01 en était dépourvue.
- Le grand bloc détecté débute à **13 h 54, heure de Paris**, pas 14 h 54. Le tableau de la recherche mélange intitulé Paris et horaires UTC. Stocker les instants en UTC et présenter les horaires avec le fuseau adapté.
- Reproduire le résultat actuel ne valide pas la justesse des bornes ; le REM Watch n'est pas une vérité terrain et l'accord entre appareils ne démontre pas la précision absolue.
- Les suggestions « seuil 50 % HRR », « Watch toujours prioritaire », « baseline fiable après 14 nuits », « ±5 % de HRV » et les objectifs de kappa sont des hypothèses ou objectifs expérimentaux, pas des faits établis. SDNN Apple et RMSSD Loop ne sont pas interchangeables.
- Les scripts pointés dans `/private/tmp` sont éphémères : les remplacer par un banc de replay maintenu, sans commettre de sauvegardes personnelles.

## 3. Ordre d'exécution et dépendances

```text
0. Replay, annotations et mesures de référence
                  ↓
1. Intégrité, temps, cache et recalcul
                  ↓
2. Santé et séances ─────→ 4. Charge cardio et entraînement
                  ↓                         ↓
3. Sommeil et HRV ─────────────────→ 5. Récupération et rapport
                                            ↓
                            6. IA explicative et décision serveur
```

Les chantiers 2 et 3 peuvent avancer en parallèle après la stabilisation des contrats de données. Les résultats restent expérimentaux tant que le jeu de validation est insuffisant.

## 4. Phase 0 — Reproduction, données et validation

**Livrables**

1. Un outil de replay local sur copie en lecture seule d'une `.loopbackup`, versionnant moteur, configuration, fuseau et empreinte des données ; sortie structurée comparable entre versions. Vérifier la cohérence SQLite/WAL et ne jamais modifier le backup original.
2. Des fixtures minimisées et synthétiques committables ; les extraits réels et annotations restent locaux et exclus de Git. Cas incontournables : nuit et course des 13–14 novembre, course + marche, nuit courte et données absentes, ajouts tardifs. Ajouter les corrections de l'utilisateur sans les écraser au recalcul.
3. Un manifeste de référence par fenêtre : source, origine, fuseau IANA, limites, disponibilité, couverture, version, annotation et niveau de référence. Ne pas additionner les doublons Apple Watch/Strava ni les pas multi-sources.
4. Une mesure initiale du temps de calcul, mémoire, batterie sur iPhone réel, taille des données et latence, plus l'écart complet/incrémental. Enregistrer la version et la configuration du moteur.
5. Jeu chronologique distinct : développement, réglage et validation finale non chevauchants ; ne pas choisir des seuils sur la nuit de validation. Annotations de coucher, lever, éveils rappelés, entraînements, RPE et ressenti au réveil. Les observations manuelles ont elles aussi leurs erreurs.

**Critères de sortie** : replay deux fois identique à version et entrées identiques ; différence expliquée avec l'existant ; tests sans réseau ; aucune donnée personnelle dans les fixtures commitées. Le jeu réel initial sert aux régressions, pas à une revendication clinique.

## 5. Phase 1 — Assurer l'intégrité et la fraîcheur

**Fichiers de départ** : `Loop/Core/Store/LoopDataRepository.swift`, `Loop/Core/Engine/LocalMetricsEngine.swift`, `Packages/WhoopStore/Sources/WhoopStore/`, `Loop/Core/Collect/` et `Loop/Core/BLE/`.

- Reproduire la perte possible d'historique lors d'un refresh 3 jours ; fusionner les seules fenêtres recalculées, sans supprimer le reste. Préserver l'historique nécessaire aux baselines et les corrections utilisateur.
- Remplacer le seul comptage de lignes par des révisions par source/intervalle couvrant insertions, mises à jour, suppressions, import Santé, paramètres, moteur et corrections. Propager la zone sale aux nuits et références dépendantes. Ne marquer traitée qu'une révision effectivement calculée ; lever le gel quand une entrée historique change.
- Publier atomiquement une projection calculée pour une révision précise ; gérer concurrence express/full, arrivée de données durant le calcul, annulation et reprise. Le résultat express doit être signalé provisoire ; éviter tout écrasement par calcul ancien.
- Paginer les lectures ou signaler explicitement toute limite atteinte. Aucun résultat incomplet ne doit être présenté comme complet ; erreurs de lecture et couverture insuffisante doivent être visibles.
- Stocker les instants en UTC ; définir le jour et l'affichage avec un fuseau IANA et une politique explicite en cas de voyage, changement d'heure et journée de 23/25 heures. Ne pas coder Paris en dur.
- Auditer et reproduire les hypothèses sur horloge BLE, doublons live/backfill et identité des RR avant modification ; appliquer des changements de protocole seulement après essais sur copies et captures réelles. Ne pas supprimer un battement valide sous prétexte d'une même seconde ou valeur RR.

**Critères de sortie** : recalcul complet et incrémental produisent les mêmes résultats pour un même jeu et contexte, y compris ajout, modification et suppression à nombre de lignes constant ; refresh court conserve l'historique ; reprise après interruption sans perte ; DST/voyage testés ; aucun résultat silencieusement tronqué. Tester les courses de données express/full par ordonnanceur contrôlé.

## 6. Phase 2 — Apple Santé et séances fiables

**Fichiers de départ** : `HealthKitImporter.swift`, `HealthBackgroundSync.swift`, `HealthReconciliation.swift`, `HealthDayReport.swift`, `ExternalWorkoutStore.swift`, `LocalMetricsEngine.swift`.

- Après activation et autorisation, synchroniser les séances ancrées au lancement et via un observer adapté lorsque le système le permet ; gérer ajouts, modifications et suppressions, curseur et données transactionnellement. Afficher dernière sync, permission et erreur, sans promettre du temps réel en arrière-plan.
- Construire une séance canonique : source, identifiant, type, dates, distance, énergie estimée, intervalles FC et niveau de qualité. Une séance explicitement enregistrée est prioritaire pour ses bornes ; un effort détecté sert de candidat, pas de preuve d'un sport.
- Dédupliquer Watch/Strava et autres sources avec critères de provenance, sport, proximité des bornes et distance, sans regroupement transitif qui absorbe plusieurs entraînements. Préserver les activités ambiguës et proposer une correction. Éviter de fusionner deux séances distinctes d'une même source simplement parce qu'elles se recouvrent.
- Détecter les activités non enregistrées avec couverture, mouvement, FC et interruptions ; label générique et confiance. Améliorer la moyenne FC sur toute la fenêtre et distinguer périodes sans données.
- Garantir une charge journalière sans double comptage et une attribution par séance, y compris séances chevauchantes et passages de minuit.

**Critères de sortie** : la course est une séance course de 10,027 km et 14:26:44–15:42:38 ; la marche reste une séance séparée ; duplicatas Watch/Strava conservés en provenance mais comptés une fois ; suppression, arrivée tardive, chevauchement, repos long, activités sans bracelet et synchronisation interrompue testés. Aucun sport inventé si les indices ne permettent pas de conclure.

## 7. Phase 3 — Sommeil, éveils et qualité des signaux

**Fichiers de départ** : `SleepEngine.swift`, `SleepClassifier.swift`, `SleepFeatures.swift`, `EpochGrid.swift`, `InBedDetection.swift`, `LocalMetricsEngine.swift`.

- Introduire pour chaque époque la couverture et la qualité de chaque signal ainsi que l'état **inconnu** ; distinguer les interruptions de capteur, le non-port et l'immobilité.
- Séparer période au lit, début de sommeil, réveil final et sortie du lit quand l'information existe ; sinon renvoyer une valeur absente. Calculer latence et efficacité uniquement quand leur dénominateur est connu ; bien distinguer TIB, SPT, TST et WASO.
- Conserver les labels bruts/qualifiés pour les calculs ; ne réserver le lissage éventuellement choisi qu'à l'affichage. Revoir les règles mouvement/FC et les éveils brefs en tant qu'hypothèses testables, sans prétendre identifier tous les éveils immobiles.
- Auditer l'échelle du proxy de gravité, sa sensibilité aux trous et les unités nécessaires à Cole–Kripke ; caractériser le canal respiratoire et le protocole avant de l'exploiter. Ne pas transformer l'absence de respiration en preuve favorable au sommeil profond.
- Privilégier des estimations d'éveil et de durée interprétables ; afficher les stades comme estimations seulement si leur évaluation le justifie, sinon les masquer. RHR/HRV : fenêtres et couverture minimales, filtres RR, écart-type correctement défini, indicateur de confiance propre à chaque mesure.
- Permettre correction de début/fin et d'épisodes, avec provenance et conservation après recalcul ; afficher les désaccords avec Santé plutôt que les effacer.

**Critères de sortie** : scénarios de réveils de 30, 60, 90 et 120 s, éveil calme, lever, sieste, trou de capteur et non-port couverts ; aucun temps inconnu additionné comme sommeil ; SOL jamais artificiellement zéro ; rapport sur fenêtres communes et couverture. Sur validation séparée, comparer biais/erreur absolue de TST, WASO et bornes, sensibilité et spécificité éveil, et régression par rapport au moteur initial. Kappa ou accord Watch mesurent la concordance avec la Watch, pas la validité clinique. Pour valider les stades de manière médicale, données PSG nécessaires.

## 8. Phase 4 — Charge cardiovasculaire et sport

**Fichiers de départ** : `Daily/Strain.swift`, `Daily/SupplementalHeartRate.swift`, `LocalMetricsEngine.swift`, modèles de profil et de séance.

- Définir séparément charge cardiovasculaire quotidienne, charge par séance et, si assez de données, charge d'entraînement. Expliquer ce que chaque indicateur mesure et sa plage ; distinguer intensité et volume.
- Configurer une FC maximale personnelle facultative avec origine/date ; sinon afficher l'estimation et son incertitude. Vérifier les valeurs observées et ne jamais utiliser une valeur future pour recalculer le passé sans versionner cette politique.
- Intégrer les durées réelles et bornées des mesures, pauses et lacunes. Choisir la source à partir de la qualité, du contexte et des réglages plutôt que toujours la Watch ou toujours le bracelet. Conserver les deux séries pour audit ; ne pas prolonger une mesure isolée au-delà de sa validité.
- Comparer la formule actuelle à des candidats documentés et au sRPE × durée ; effectuer une analyse de sensibilité sur seuils et paramètres. Fixer les poids après confrontation aux séances annotées, pas après sélection sur un unique 10 km.
- Course, natation et musculation demandent des jeux d'évaluation distincts ; proposer RPE et, si souhaité, séries/charges pour l'entraînement de force. Ne pas présenter un proxy FC comme une mesure de charge musculaire.
- Évaluer séparément FC moyenne/max et charge, avec couverture ; affichage journalier et attribution des séances sans double compte.

**Critères de sortie** : pas de minutes de zone comptabilisées hors de leurs bornes déclarées ; trous/pauses explicites ; cohérence complet/express ; invariants et simulations d'efforts longs/courts, marche, intervalles, haute FC sans sport, musculation et natation. Les résultats sont comparés par type et par séance à un protocole de référence ; pas d'objectif d'équivalence WHOOP sans données adaptées.

## 9. Phase 5 — Récupération et rapport réellement utiles

- Revoir dispersion MAD et formule de récupération avec tests de calculs de référence ; traiter valeurs invalides, dates manquantes, péremption et bruit. Un changement de formule crée une nouvelle version et un recalcul explicite, pas une rupture cachée de l'historique.
- RHR, RMSSD, sommeil, respiration et ressenti ont chacun leur historique, source, fenêtre de mesure et qualité. Ne pas fusionner SDNN et RMSSD ; calibrer les baselines par signal et déclarer un état « données insuffisantes » sans attribuer une fatigue.
- Présenter les composantes, écarts à la référence personnelle, couverture, disponibilité et évolution ; expliquer que la « surcharge » actuelle signifie qu'une charge récente dépasse une baseline, pas une fatigue ou un diagnostic.
- Recueillir optionnellement ressenti, courbatures, RPE et événements contextuels ; vérifier s'ils améliorent réellement la pertinence. Un LLM ne décide ni d'une modification d'entraînement médicale ni de l'état physiologique.

**Critères de sortie** : chaque chiffre affiché a source, unité, période, version et qualité accessibles ; signaux manquants explicités ; scores absents en calibration ; stabilité au recalcul ; comparaison prospective au ressenti sur des semaines non utilisées pour régler le modèle.

## 10. Phase 6 — IA et cerveau de calcul optionnels

### Expérience serveur

Après mesure de la phase 0, comparer sur les mêmes entrées un moteur Swift local et un worker Swift côté serveur : résultats identiques à tolérance numérique documentée, temps de calcul, mémoire, latence totale incluant transfert, fréquence de recalcul, coût d'hébergement et robustesse hors ligne. Décider à partir de ces mesures ; un worker Python ou un modèle ML peut être expérimenté séparément si un gain vérifié justifie une seconde implémentation.

Si le serveur est retenu : iPhone → file d'envoi chiffrée et reprise → API authentifiée → stockage des observations versionnées → file de jobs idempotents → worker versionné → résultats avec provenance, qualité et version → synchronisation locale. Gérer arrivées tardives, tombstones, corrections, conflits, retries, observabilité, sauvegarde, effacement et migration. Un seul résultat fait autorité par révision ; le mode hors ligne affiche un résultat local/provisoire avec date de fraîcheur. Le serveur ne peut calculer que les données effectivement collectées et envoyées ; iOS reste maître des opportunités d'exécution en arrière-plan.

### IA

D'abord produire un bilan à partir de règles et valeurs calculées. Si un LLM apporte une valeur mesurable, lui fournir uniquement les éléments nécessaires, avec consentement approprié au partage externe. Il peut reformuler, expliquer les facteurs observés et poser des questions ; les propositions de correction restent réversibles et validées par l'utilisateur. Vérifier les chiffres, les unités, la provenance, l'absence de valeurs et l'absence d'affirmations diagnostiques par un jeu de tests de faits et de cas contradictoires. Pas de changement automatique des scores.

**Critères de décision** : démonstration reproductible du gain, jeu d'évaluation indépendant, modèle de coûts mesuré, traitement des données et confidentialité clairement choisis. Ne pas figer d'identifiant de modèle ni promettre un coût avant benchmark. [Règles Apple de protection des données de santé et de partage avec des tiers](https://developer.apple.com/app-store/review/guidelines/).

## 11. Tableau de validation à maintenir

| Domaine | Données comparatives | Mesures à suivre | Limite |
|---|---|---|---|
| Pipeline | Données synthétiques + replay sur copies | Parité full/incrémental, pertes, délais, révisions, couverture | Une parité valide l'implémentation, pas la physiologie. |
| Séances | Séances Santé dédupliquées + annotations utilisateur | Précision/rappel, erreur début/fin, durée et distance, doublons | Une séance enregistrée peut elle-même être erronée. |
| FC exercice | Watch et si possible ceinture ECG synchronisée | Biais, erreur absolue et couverture par sport/intensité, points appariés | Une seule course ne généralise ni ne garantit l'indépendance des capteurs. |
| Nuit | Watch + journal ; PSG si disponible | Écart TST/WASO/bornes, détection éveil et trous ; accord des stades séparé | Watch = comparateur imparfait ; PSG nécessaire pour validation clinique. |
| HRV | Même métrique, fenêtre et capteur de référence | Biais, variabilité et qualité RR ; stabilité des baselines | SDNN et RMSSD mesurent des grandeurs différentes. |
| Charge | Séances, durée, FC, RPE et ressenti | Concordance et sensibilité par sport et intensité, fiabilité test-retest | Aucun indicateur unique ne mesure toute la charge musculaire. |
| Rapport / IA | Faits calculés et situations de données manquantes | Fidélité des valeurs et unités, corrections acceptées, utilité | L'utilité perçue ne prouve pas une performance clinique. |

Avant de régler chaque algorithme, fixer les objectifs chiffrés et la méthode sur le jeu de validation en fonction des données disponibles. Ne pas faire passer les 30 nuits ni κ ≥ 0,5 proposés par la recherche pour une preuve de performance clinique.

## 12. Sources primaires et documentation

- [Étude de six dispositifs de sommeil comparés à la polysomnographie, 62 adultes](https://pubmed.ncbi.nlm.nih.gov/40303381/) : la détection de l'éveil et la concordance des stades varient selon l'appareil.
- [Étude sur la charge de natation et les variations d'intensité](https://pubmed.ncbi.nlm.nih.gov/24942164/).
- [Étude de la charge perçue dans l'entraînement de résistance](https://pubmed.ncbi.nlm.nih.gov/24378665/).
- [Documentation Apple : configuration et livraison en arrière-plan HealthKit](https://developer.apple.com/documentation/Xcode/configuring-healthkit-access).
- [Documentation WHOOP sur la nature non linéaire du strain](https://support.whoop.com/s/article/WHOOP-Strain?language=en_US) : utile pour décrire leur produit, insuffisante pour reproduire sa formule.

## 13. Première séquence de travail

1. Construire le replay sur copies et les tests de non-régression des deux événements.
2. Corriger cache court, invalidation et publication atomique après reproduction ; instrumenter couverture et fraîcheur.
3. Faire apparaître course et marche comme séances distinctes et dédupliquer Apple/Strava.
4. Isoler les inconnus et supprimer les biais évidents du sommeil, puis évaluer les règles candidates.
5. Refaire la charge par séance et les baselines sur des critères documentés ; compléter par RPE.
6. Produire le rapport explicable ; mesurer l'intérêt d'un serveur et d'une IA sur un prototype avant intégration.
