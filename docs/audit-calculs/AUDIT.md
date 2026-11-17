# Audit du moteur de calcul Loop — 14 novembre 2026

## Périmètre et conclusion

Audit statique du moteur Swift, de l'acquisition, de l'intégration Apple Santé et des tests, complété par une lecture locale de la sauvegarde fournie. Aucun diagnostic médical ni mesure de précision contre une référence indépendante n'a été réalisé. Le projet se présente actuellement comme local-first et sans serveur ; le moteur serveur antérieur a été supprimé (voir `AGENTS.md`).

**Conclusion : le serveur est possible et utile pour des recalculs, des expériences et des traitements longs, mais ne rend pas les résultats plus précis à lui seul.** Les principales priorités sont la qualité et la disponibilité des signaux, la correction de défauts identifiés, puis la validation sur des exemples annotés. Une équivalence avec WHOOP ne peut pas être revendiquée : ses modèles sont propriétaires et les signaux ou résultats ne sont pas nécessairement comparables.

## Constats classés par priorité

| Priorité | Constat et conséquence | Preuve |
|---|---|---|
| P0 | La sauvegarde examinée contient zéro séance `external_workout` et zéro `health_sample`. La course Apple Watch n'était donc pas disponible comme séance Santé pour les calculs de cette sauvegarde. Ce constat ne prouve pas la cause de l'absence. | Lecture SQLite en mode immuable de `Loop-2026-11-14-1301.loopbackup` |
| P0 | La validation de baseline, récupération et strain est neutralisée : les tests de parité correspondants ont un corps vide. Les tests sommeil tolèrent certains nombres de sessions ou recouvrements incorrects. Les tests qui passent ne prouvent pas l'exactitude physiologique. | `Packages/LoopStrapEngine/Tests/LoopStrapEngineTests/ParityHarness/DailyParityTests.swift:18`, `:90`, `:100`; `SleepParityTests.swift:177`, `:240`, `:264` |
| P1 | Les éveils classés de moins de 2 minutes sont absorbés après un lissage majoritaire. La durée d'éveil et le nombre de perturbations peuvent donc être sous-estimés. | `Sleep/SleepTypes.swift:41`; `Sleep/SleepClassifier.swift:211` |
| P1 | L'éveil immobile ne peut pas être classé éveillé quand la fréquence cardiaque est présente ; un mouvement sans activation cardiaque peut aussi devenir sommeil léger. Les données manquantes ne sont pas toujours distinguées du sommeil. | `Sleep/SleepClassifier.swift:313`; `Sleep/EpochGrid.swift:178` |
| P1 | Les segments d'éveil au début et à la fin sont supprimés avant le calcul : la latence d'endormissement vaut zéro par construction. L'efficacité calculée rapporte le sommeil à la période de sommeil retenue, pas nécessairement au temps passé au lit. | `Sleep/SleepEngine.swift:135`, `:220`, `:255` |
| P1 | La détection d'activité utilise un seuil de FC, une durée de 10 min et des interruptions jusqu'à 12 min ; elle produit seulement `detected_cardio`. La FC moyenne porte sur les points au-dessus du seuil. Des efforts distincts peuvent être regroupés ; une activité sans forte FC peut être manquée. | `Loop/Core/Engine/LocalMetricsEngine.swift:925` |
| P1 | Le déclenchement Santé en arrière-plan observe les types d'échantillons, mais pas les séances HKWorkout ; celles-ci ont un chemin d'import séparé au premier plan. | `Loop/Core/Health/HealthBackgroundSync.swift:37`, `:165` |
| P1 | L'invalidation du cache utilise des nombres de lignes et le refresh peut sortir avant de vérifier les empreintes Santé ; un remplacement à nombre constant n'est pas détectable par ce compteur. Les nuits anciennes déjà calculées peuvent aussi être gelées malgré des données tardives. À reproduire sur les parcours concernés. | `Loop/Core/Store/LoopDataRepository.swift:229`; `Loop/Core/Engine/LocalMetricsEngine.swift:186`, `:221` |
| P2 | Le profil est passé à `nil` et la FC maximale du chemin principal est déduite du percentile 99,5 global sans âge. Un historique sans effort maximal peut sous-estimer la FC max et majorer la charge ; l'utilisation d'un pool global peut faire varier les scores historiques lors d'un recalcul. | `Loop/Core/Engine/LocalMetricsEngine.swift:467`, `:478`, `:500`, `:542` |
| P2 | La dispersion de baseline est déjà issue d'une MAD normalisée puis multipliée de nouveau par 1,253 pour les z-scores. Cela atténue les écarts en dehors des planchers. Des valeurs invalides non nulles ne vieillissent pas correctement la baseline. | `Daily/Baselines.swift:243`, `:282`; `Daily/Recovery.swift:96`; `Daily/SleepScore.swift:177` |
| P2 | Le score de récupération est une formule heuristique : HRV, FC de repos et efficacité, avec poids renormalisés ; la respiration n'est pas passée par le pipeline courant. Une situation au centre des références et une efficacité de 85 % donne 50 %, malgré un commentaire annonçant 58 %. | `Daily/Recovery.swift:93`; `Daily/Daily.swift:247` |
| P2 | WASO absent est remplacé par zéro dans le score sommeil, ce qui lui donne un effet favorable plutôt que neutre. La FC de repos d'une session peut être choisie sur une fenêtre de 5 minutes avec un seul échantillon. | `Daily/SleepScore.swift:189`; `Sleep/SleepEngine.swift:554` |
| P2 | La fusion des séances par recouvrement peut réunir des activités distinctes, car elle ne vérifie pas systématiquement sport et source et utilise une union transitive. | `Loop/Core/Health/HealthReconciliation.swift:294` |
| P2 | Aucun moteur de fatigue distinct n'a été identifié ; le stress est lui-même une approximation fondée sur FC/HRV et utilise des références journalières dans le chemin examiné. | `Daily/Stress.swift`; `Loop/Core/Engine/LocalMetricsEngine.swift:880` |

Les chemins `Sleep/` et `Daily/` du tableau sont relatifs à `Packages/LoopStrapEngine/Sources/LoopStrapEngine/`.

## Lecture de la sauvegarde

La base contient environ 209 000 mesures de FC, 145 000 intervalles RR et 202 000 mesures de gravité, du 11 au 14 novembre pour les séries considérées. Le cache a été mis à jour le 14 novembre à 12 h 56, heure de Paris. Il ne constitue pas une preuve que les données HealthKit ont été autorisées ou synchronisées.

Pour la nuit du 13 au 14 novembre, le cache décrit une période de 01 h 04 à 10 h 02, environ 8 h 02 de sommeil, 14 épisodes d'éveil et un score de sommeil de 54,4/100. Ce sont les sorties actuelles de Loop, pas des valeurs de référence. Les éveils courts filtrés et la veille calme peuvent manquer ; il faut comparer au journal de l'utilisateur. Le cache indique une récupération en cours de calibration, sans score de récupération exploitable dans ce relevé.

Le 13 novembre, une activité automatique va de 13 h 54 à 17 h 00, soit environ 3 h 06, avec un pic à 182 bpm. Son éventuel lien avec la course de 10 km n'est pas établi sans les horaires de la séance. L'absence de séance Apple Santé dans cette sauvegarde empêche une comparaison directe. Les horaires ci-dessus sont en Europe/Paris.

## Architecture recommandée

1. **Contrat de données d'abord** : conserver événements horodatés, source et appareil, unités, qualité, trous, fuseau horaire, modifications et suppressions ; identifier les lots de manière idempotente. Garder les mesures distinctes des résultats dérivés et des corrections de l'utilisateur.
2. **Moteur versionné et rejouable** : séparer les fonctions de calcul des lectures SQLite et de l'interface. Pour chaque résultat, stocker version du moteur, paramètres, plage et révision des données, provenance et qualité. Recalculer les dépendances à l'arrivée de données tardives ; ne pas confondre nombre de lignes et version des données. Conserver les corrections manuelles.
3. **Option serveur, après prototype local** : iPhone collecte et conserve une copie locale ; synchronisation chiffrée et incrémentale avec accusé de réception et reprise ; service d'ingestion persistant ; file de jobs idempotents ; workers de calcul ; base de résultats versionnés ; synchronisation des résultats et état de fraîcheur vers l'iPhone. Prévoir déconnexion, retries, backfill tardif, suppressions, contrôle d'accès, chiffrement au repos, sauvegardes et export/suppression. Les données de santé exigent un choix explicite de confidentialité et d'hébergement.
4. **Temps réel et arrière-plan** : le serveur ne peut calculer que ce que l'iPhone lui a effectivement envoyé. Les fenêtres d'exécution iOS, la collecte BLE et les livraisons HealthKit ne garantissent pas un flux instantané continu. Afficher la dernière synchronisation et un résultat provisoire si nécessaire.
5. **IA** : commencer par une explication des mesures vérifiées et de leurs limites, ancrée dans des données structurées ; l'utilisateur doit pouvoir corriger une séance ou une nuit. Un modèle statistique de détection exige un jeu annoté et une évaluation hors échantillon. Ne pas demander à un LLM d'inventer les valeurs ni de poser un diagnostic ; valider toute affirmation générée contre les données fournies.

L'extraction du paquet Swift existant peut permettre de partager le moteur entre iOS et un serveur Swift ; un service séparé peut ensuite accueillir des modèles Python si les essais démontrent leur intérêt. Ne pas dupliquer silencieusement deux implémentations divergentes.

## Plan d'action et critères d'acceptation

1. **Mesurer et reproduire** : importer les séances Apple Santé et conserver les références source ; annoter les heures de coucher, lever, réveils et début/fin de course. Construire des fixtures anonymisées à partir de fenêtres autorisées. Contrôler couverture et trous des flux, fuseaux et correspondance des horloges.
2. **Fiabiliser les données** : observer les workouts Santé, rendre la synchronisation visible, traiter ajouts/suppressions, corriger invalidation et backfills. Critères : une séance importée apparaît après synchronisation ; une modification ou suppression déclenche le recalcul pertinent, y compris si le nombre de lignes ne change pas ; fonctionnement hors ligne explicite.
3. **Corriger le sommeil** : préserver périodes au lit et de sommeil, étiqueter les trous « inconnu », séparer lissage visuel et calcul, vérifier la couverture de FC. Tester éveils de 30/60/90/120 s, éveil immobile, trous et siestes. Comparer durée totale et WASO en minutes et bornes en minutes à des annotations ; pour les stades, une montre est une référence comparative imparfaite, la polysomnographie est la référence clinique.
4. **Fiabiliser l'activité et la charge** : réconcilier les workouts Santé par source et compatibilité, tester les chevauchements et les pauses ; mesurer précision/rappel de détection, erreur de début/fin et de durée. Pour la charge, vérifier FC max configurable, couverture FC, intégration temporelle et stabilité historique ; comparer les tendances à la perception d'effort et aux séances, pas seulement à un score propriétaire. Distinguer charge cardio et charge musculaire ; ne pas inférer précisément la musculation depuis la FC seule.
5. **Récupération explicable** : corriger l'échelle statistique, gérer les données absentes et la péremption, expliciter les facteurs et la confiance ; évaluer les variations par rapport aux références personnelles et au ressenti sur plusieurs semaines. Éviter de présenter un score composite comme une mesure globale validée de l'état de santé.
6. **Serveur et IA** : mesurer d'abord les temps et ressources réels ; réaliser un prototype de replay sur une copie, comparer strictement les résultats avec le moteur local, puis décider si le bénéfice justifie la synchronisation. Évaluer l'IA sur des cas comportant des données manquantes et des faits contradictoires.

Les seuils de réussite chiffrés doivent être fixés avant optimisation sur un jeu d'évaluation distinct, avec assez de nuits et séances variées ; une seule nuit et une seule course servent à reproduire les erreurs, pas à démontrer une précision générale.

## Sources externes

- WHOOP décrit son strain comme une mesure personnalisée non linéaire : https://support.whoop.com/s/article/WHOOP-Strain?language=en_US
- Apple décrit les contraintes de livraison HealthKit et les observers : https://developer.apple.com/documentation/Xcode/configuring-healthkit-access
- Apple précise que la collecte cardiaque hors exercice dépend notamment du mouvement et de la qualité du signal : https://www.apple.com/health/pdf/Heart_Rate_Calorimetry_Activity_on_Apple_Watch_November_2024.pdf
- L'American Academy of Sleep Medicine rappelle que les appareils grand public ne remplacent pas les instruments validés d'évaluation clinique : https://pmc.ncbi.nlm.nih.gov/articles/PMC5940440/

## Vérification exécutée

`swift test` dans `Packages/LoopStrapEngine` : 232 tests exécutés, 7 ignorés, aucun échec. Ce résultat ne valide pas la précision : plusieurs tests de parité sont vides et une fixture sommeil signale une différence de nombre de sessions sans échouer. Aucun code de production modifié.

## Complément : croisement avec la sauvegarde Apple Santé de 13 h 08

La nouvelle sauvegarde contient 670 séances et 2 174 572 échantillons Santé. Les horaires sont en Europe/Paris. Les valeurs suivantes décrivent les enregistrements, sans ériger l'Apple Watch en référence médicale.

### Course du 13 novembre

- Apple Watch : course de 14 h 26 min 44 s à 15 h 42 min 38 s, 10,027 km, durée 1 h 15 min 54 s environ. Une courte course de 14 h 17 à 14 h 20 et une marche de 15 h 42 min 57 s à 16 h 27 min 47 s sont aussi enregistrées. Des doublons Strava existent pour certaines séances.
- Loop : une seule activité cardio détectée de 13 h 54 min 26 s à 17 h 00 min 11 s, soit 3 h 05 min 45 s. Elle débute 32 min 18 s avant la course principale et se termine 1 h 17 min 33 s après celle-ci ; elle englobe également la marche.
- Pendant les bornes de la course, le bracelet contient 4 556 mesures de FC, moyenne simple 164,39 bpm, maximum 178 bpm. Pour 670 mesures Watch appariées à une mesure bracelet à ±5 secondes, l'écart absolu moyen est d'environ 1,00 bpm et le biais bracelet moins Watch de +0,25 bpm. Il s'agit de moyennes d'échantillons et d'une comparaison descriptive ; l'indépendance des sources ne peut être garantie. La FC moyenne de 145,86 bpm dans le cache Loop concerne la longue activité détectée et seulement ses points au-dessus du seuil : elle n'est pas comparable à la moyenne de la course.
- La segmentation est donc un défaut concrètement observé ; les FC concordent bien sur les points comparés, sans valider l'ensemble de la chaîne ni le strain.

### Nuit du 13 au 14 novembre

| Mesure | Apple Watch / Santé | Loop |
|---|---:|---:|
| Début – fin de la période classée | 00 h 58 min 27 s – 09 h 29 min 57 s | 01 h 04 min 25 s – 10 h 02 min 46 s |
| Sommeil estimé | 6 h 48 min | 8 h 02 min |
| Éveil estimé | 103,2 min, 12 segments | 56 min, 14 segments |
| Sommeil léger | 247,3 min | 425,9 min |
| Sommeil profond | 43,4 min | 38 min |
| Sommeil paradoxal | 117,7 min | 18,5 min |

Les fenêtres diffèrent : Loop continue 32 min 49 s après le dernier segment Watch et commence près de 6 min plus tard. Sur la fenêtre commune de 01 h 04 min 25 s à 09 h 29 min 57 s, environ 62,3 minutes classées éveil par la Watch sont classées sommeil par Loop ; environ 5,6 minutes classées sommeil par la Watch sont classées éveil par Loop. Par exemple, la Watch indique un éveil de 03 h 50 min 26 s à 04 h 14 min 22 s ; Loop classe éveil jusqu'à 04 h 00 min 55 s, puis sommeil léger. Des pas Watch et iPhone enregistrés dans cette plage corroborent du mouvement, sans prouver à eux seuls l'état de conscience.

Les stades issus des deux appareils sont des estimations et ne constituent pas une vérité terrain. Néanmoins, les désaccords d'éveil observés sont cohérents avec les limites du classifieur constatées dans le code. Le cache de sommeil Loop n'a pas changé entre les deux sauvegardes pour cette nuit ; dans le parcours de calcul inspecté, seuls la fréquence cardiaque et la fréquence cardiaque de repos Santé sont injectées dans les calculs journaliers (`LocalMetricsEngine.swift:453–471`, `:1005–1006`), pas les stades de sommeil Santé.

Le signal `recent_overload` passe de faux à vrai après l'import de l'historique Santé et sa confiance affichée devient élevée, tandis que la récupération reste en calibration. Ce signal signifie ici qu'au moins une des trois dernières charges dépasse la baseline calculée ; il ne prouve pas une surcharge physiologique. La comparaison utilise un historique hétérogène avec des jours manquants et doit être interprétée avec prudence (`AdviceEngine.swift:198–217`).
