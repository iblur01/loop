# Jour calendaire local — décisions, migration, limites (2026-11-14)

Corrige P3, S9 et W7 (`RECHERCHE-COMPLETE-2026-11-14.md`) et lève la première limite de `IMPLEMENTATION-PHASES-1-3.md`.

## Politique

- Un jour est un **jour calendaire local**, défini dans le fuseau de l'appareil (`TimeZone.autoupdatingCurrent`, relu à chaque calcul). Aucun fuseau n'est codé en dur. Les jours de changement d'heure durent 23 h ou 25 h.
- Une seule source pour les jours : `LocalDaySchedule` (`LoopStrapEngine/Daily/LocalDay.swift`). Elle gère les bornes `dayBounds`, l'attribution d'une nuit (fin dans `[début, fin)` du jour), le strain et le stress journaliers, la détection et la réutilisation des séances, « aujourd'hui » (complet, express et `LoopDataRepository`), la clé `@window:` et les empreintes `dayCounts`. La vue Santé d'Aujourd'hui en dépend aussi. Les trois formateurs de jour de l'interface (`TodayView`, `SleepDetailView`, `TimelineBuilder`) passent du fuseau UTC au fuseau local.
- **Fuseau figé par jour** : chaque jour calculé enregistre son fuseau (`DailySnapshot.timeZone`, registre `LoopCache.dayTimeZones`, `LocalComputeResult.dayTimeZones`). Aujourd'hui et les jours suivants utilisent le fuseau courant. Un jour passé garde son fuseau d'origine, en calcul complet comme en incrémental.
- Contiguïté : le jour J commence à minuit de J dans le fuseau de J‑1 et se termine à minuit de J+1 dans son propre fuseau. Il n'y a ni trou ni double comptage. Le jour du voyage dure par exemple 30 h de Paris vers New York, 18 h dans l'autre sens.
- Empreintes : les révisions d'entrée restent indexées par jour UTC (triggers SQLite inchangés, `Database.swift` non modifié). L'empreinte d'un jour local additionne les révisions monotones des jours UTC qu'il recoupe, ce qui peut seulement invalider un jour de trop, jamais en oublier un. Un jour dont le fuseau change est marqué modifié, et `@zone:<id>` signale un changement de fuseau de l'appareil.
- Séances bracelet : la détection se fait par jour local avec 6 h de marge de part et d'autre. Le seuil d'effort reste calculé sur le jour seul. Une séance à cheval sur minuit est vue en entier et attribuée une seule fois, à son jour de début. Les séances Santé sont lues par recouvrement (`externalWorkouts(overlapping:to:)`).

## Migration

- Clé moteur `@engine:v5` → `@engine:v6-localday`. Les anciens caches sont invalidés et recalculés intégralement sur la fenêtre de 60 jours à partir des données brutes, qui ne sont pas modifiées. Les champs persistants du cache (difficulté, séances rejetées) sont conservés. Un recalcul vide garde l'ancien cache (garde-fou existant).
- Décision conservatrice pour les jours anciens sans fuseau d'origine (caches v5, en UTC) : on ne reconstitue aucun voyage passé. Ces jours prennent le fuseau courant au moment de la migration, puis restent figés. Garder des jours UTC à côté de jours locaux aurait créé des chevauchements d'une à deux heures, donc du strain compté deux fois. Le décodage des anciens `cache.json` reste tolérant (`timeZone`/`dayTimeZones` à nil).
- Les signaux de conseil (`advice_signal`) gardent les mêmes clés de jour et sont réécrits au recalcul.

## Vérifications

- Tests ciblés : DST printemps et automne, nuit à cheval sur minuit, séance à cheval sur minuit, strain entre 00 h et 02 h, parité complet / incrémental près de minuit, voyage Paris → New York (jour figé, jour de 30 h, complet = incrémental), migration d'un cache v5. Voir `SleepDayTimeZoneTests` (moteur) et `LoopTests/LocalDayPipelineTests.swift` (exécuté sous macOS via `Tools/LoopReplay`).
- Replay du backup 2026-11-14 (Europe/Paris) : course de 10,027 km et marche de 2,896 km distinctes le 13/11. Nuit du 13 au 14 : 408,31 min (Santé). Strain du 13 : 13,78 en local, 13,91 avec `--timezone UTC`. Ce strain dépend désormais des bornes locales (1 231 min observées, contre 1 289 min avec les bornes UTC).

## Limites

- Le replay et un calcul sans cache partent sans registre et appliquent un seul fuseau à toute la fenêtre. Un voyage n'est conservé que par le cache de l'app.
- Lors d'un voyage vers l'est, les premières heures après minuit peuvent encore tomber dans le jour précédent figé. Pendant ce temps, le jour courant peut ne pas avoir commencé.
- L'interface regroupe sommeil et séances par jour dans le fuseau **courant**, pas dans le fuseau figé du jour. Après un voyage, l'affichage d'un jour passé peut différer de ses bornes de calcul.
- `bedtimeOffsetMinutes` (Advice) reste référencé à midi UTC. Il n'a aucun effet tant que `bedtimeBaseline` vaut nil. Il faudra le corriger avant d'activer le conseil d'heure de coucher.
- `HealthSleepAdapter.summaries` garde un repli UTC quand on ne lui passe pas de fenêtre. Ce repli ne sert qu'aux appelants hérités et aux fixtures : le moteur passe toujours la fenêtre locale.
- Le registre est élagué à 400 jours.
