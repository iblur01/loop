# Séances : détection bracelet et fusion multisource (2026-11-15)

## Constats et causes

- **Séances « cardio détecté » le soir jusqu'à l'endormissement.** Le détecteur ne connaissait pas le sommeil. Le seuil de FC est `max(FC basse du jour + 35, 110)` bpm. Les passages au-dessus de ce seuil sont reliés tant que l'écart reste sous 12 min. Une soirée à FC proche du seuil formait donc une « séance » de plusieurs heures, terminée à l'endormissement.
- **Détections presque vides.** La durée minimale de 10 min portait sur l'écart entre le premier et le dernier échantillon actif, pas sur l'effort. Quelques pics isolés espacés de 10 min suffisaient.
- **Fragments de 2 à 3 min.** C'étaient des faux départs enregistrés sur Apple Watch et recopiés par Strava, quelques minutes avant la vraie séance. Seul l'affichage les masquait (moins de 5 min).
- **Doublons Santé.** Strava écrit souvent le type « Autre » (`HKWorkoutActivityType` 3000) pour une séance qu'une autre app nomme précisément, comme Hevy avec « Musculation ». Les types étaient différents, donc les deux séances n'étaient pas fusionnées. Chacune recevait sa charge, comptée deux fois dans les volumes par séance.
- **Doublons bracelet / Santé.** Une détection n'était absorbée que si elle couvrait au moins la moitié de la séance Santé. Une détection partielle, ou un échauffement et un retour au calme encore au-dessus du seuil, passait à côté. La règle de priorité des sources existait à deux endroits, avec deux ordres différents : réglage `workouts` (montre, bracelet, Santé) et chronologie.

## Règles (LoopStrapEngine, `Training/WorkoutDetection.swift`, `Training/WorkoutCanonicalization.swift`)

- **Priorité unique** : `WorkoutSourcePriority.order` = Apple Watch, Strava, autre source Santé, bracelet. La fusion du cache et la chronologie (`DayTimelineSource.priority`) utilisent cet ordre.
- **Création des détections** (`WorkoutDetectionPolicy`) :
  - durée minimale de 10 min, comme la règle de fragment ;
  - au moins 5 minutes dont la médiane dépasse le seuil, soit la moitié de la durée minimale. La médiane par minute écarte les pics d'une ou deux secondes : artefacts optiques, lever ;
  - aucune détection ne peut recouper un sommeil retenu, nuit ou sieste, toutes sources, élargi de 30 min de chaque côté. Cette garde couvre la latence d'endormissement habituelle, de 10 à 20 min, et l'écart entre les bornes de sommeil des différentes sources. Une séance séparée du sommeil par plus de 30 min est conservée ;
  - les plages des séances Santé coupent le signal bracelet : seul ce qui dépasse de ces plages peut devenir une détection.
  - Le seuil de FC et l'écart de 12 min sont inchangés. Le seuil absolu de 110 bpm ne suffit pas à séparer une soirée agitée d'une séance de musculation : leurs FC se recoupent. C'est la fenêtre de sommeil qui fait la différence.
- **Fusion** (`WorkoutCanonicalization`), à la lecture, sans toucher aux lignes brutes :
  - deux enregistrements Santé de producteurs différents représentent la même séance si leur recouvrement couvre au moins 50 % de la plus courte et 70 % de la plus longue, et si leurs sports sont compatibles. Le type 3000 est compatible avec tout. La séance prioritaire fournit les bornes. Le sport retenu est celui du primaire, sinon le premier type précis d'un membre ;
  - une séance enregistrée de moins de 10 min, à moins de 10 min d'une séance compatible plus longue, est absorbée comme faux départ. Elle ne devient jamais primaire. Une séance courte isolée est conservée ;
  - une détection bracelet est absorbée par une séance Santé dans deux cas : leur recouvrement couvre la moitié de la plus courte, ou elle la prolonge à 12 min près ou moins (échauffement, retour au calme).
- **Charge** : la charge journalière est calculée sur une FC fusionnée seconde par seconde (`mergePrioritizedHR`). Une même période n'y est jamais comptée deux fois. La charge par séance n'est calculée qu'une fois par séance canonique.
- Clé moteur `@engine:v7-hrzones` → `@engine:v8-workouts` : le cache est recalculé à partir des données brutes.

## Replay (copie privée de la sauvegarde du 14/11, 7 jours, Europe/Paris)

- La course Apple Watch du 13/11 (14:26 → 15:42) reste unique, avec la même charge (11,33). Elle reste distincte de la marche (15:42 → 16:27, 6,48). Le faux départ de 14:17 est absorbé.
- La détection du 13/11 de 22:03 à 00:59 n'est plus créée.
- Les quatre doublons Strava / Hevy de la fenêtre sont fusionnés. Ils apparaissent en « Musculation », avec les bornes Strava.
- La charge journalière est inchangée sur les 7 jours (13/11 : 13,78), comme attendu : elle ne dépend pas de la liste des séances.
- Aucun seuil n'a été réglé sur ces cas.

## Limites

- Une vraie séance non enregistrée qui finit moins de 30 min avant l'endormissement n'est plus détectée. Un effort non enregistré qui prolonge une séance Santé sans pause lui est rattaché.
- Les bornes Strava priment sur celles d'une autre app (Hevy), même si elles sont plus courtes. La perception d'effort (RPE) saisie sur une séance devenue secondaire n'est plus affichée sur la séance fusionnée. Elle n'est pas supprimée.
- Le réglage `workouts` de `HealthSourcePriority` n'arbitre plus la fusion des séances. Il reste utilisé par le rapport Santé du jour (`HealthDayReport`).
- Les seuils restent des hypothèses Loop, sans référence indépendante.
