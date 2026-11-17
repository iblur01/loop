# LoopReplay — banc de replay local macOS

Exécute les fonctions **actuelles** `detectSleep` et `strain` du package Swift `LoopStrapEngine` sur une fenêtre d'une sauvegarde `.loopbackup`. Il extrait aussi les séances et segments sommeil Apple Santé de la même fenêtre pour comparaison. Le JSON est reproductible pour une même copie d'entrée, les mêmes options et le même moteur. Les données sont traitées localement.

```sh
cd /Users/theo/dev/loop/Tools/LoopReplay
swift test
swift build -c release
# Exemple synthétique : adapter chemin, bornes UTC Unix et version du code.
umask 077
.build/release/loop-replay '/chemin/vers/Loop.loopbackup' \
  --from 1704067200 --to 1704153600 --timezone Europe/Paris \
  --revision 'commit-ou-version-de-travail' > /tmp/loop-replay.json
```

La fenêtre est `[from, to)` et limitée à 48 heures. Les valeurs restent des secondes Unix ; le fuseau IANA constitue une métadonnée. Si plusieurs bracelets ont des FC dans la fenêtre, préciser `--device`. Pour calculer la charge cardio, ajouter `--resting-hr 60 --max-hr 190` en fournissant les deux valeurs ; la charge est omise si les FC sont insuffisantes. Il ne s'agit pas d'une estimation automatique de FC max.

L'outil copie le fichier SQLite et ses éventuels WAL/SHM dans un dossier temporaire privé, vérifie son intégrité, puis lit la copie. Utiliser uniquement une sauvegarde **inactive**, non en cours d'écriture : la copie séquentielle ne constitue pas un snapshot atomique d'une base vivante. L'original n'est jamais ouvert par SQLite. Le digest SHA-256 couvre les fichiers SQLite et WAL copiés (pas SHM), et `--revision` est un identifiant **fourni par l'opérateur** ; il faut donc le changer à chaque modification du moteur. Les résultats contiennent des données de santé sensibles : garder les JSON hors du dépôt, limiter leurs permissions et les supprimer après analyse.

Limites du premier exécutable `loop-replay` : il teste les fonctions publiques de sommeil et de strain, **pas** le pipeline iOS `LocalMetricsEngine` dans sa totalité, ni la détection de séances, la réconciliation des sources, les calculs journaliers ou la fusion de FC Apple Santé. Utiliser `loop-daily-replay` ci-dessous pour ceux-ci. Les séances et segments Santé sont les enregistrements bruts, non dédupliqués ; plusieurs sources et intervalles peuvent se chevaucher. Une absence de nuit ne prouve pas une absence de sommeil. Les segments Apple Santé ne sont pas une vérité clinique. Le SHA couvre les octets du snapshot, pas une normalisation des données logiques. `swift test` utilise uniquement des données synthétiques et vérifie notamment le replay déterministe, la séparation des séances en entrée et l'intégrité de la sauvegarde.

## Replay du pipeline journalier de l'application

Le second exécutable compile **les fichiers Swift du moteur iOS lui-même**, liés au dépôt sans copie du code métier, ainsi que `WhoopStore` et les adaptateurs Santé. Il utilise une horloge explicite et s'exécute sur une copie privée de la sauvegarde ; les migrations et résultats calculés ne touchent que cette copie.

```sh
umask 077
.build/release/loop-daily-replay '/chemin/vers/Loop.loopbackup' \
  --date 2024-01-02 --days 3 --device bracelet-test --timezone Europe/Paris \
  --revision 'commit-ou-version-de-travail' > /tmp/loop-daily.json
```

La date est le **dernier jour calendaire local** inclus, dans le fuseau IANA `--timezone` (par défaut celui du Mac) ; l'horloge du moteur est placée à la dernière seconde de ce jour. Tous les jours de la fenêtre utilisent ce fuseau : le replay part sans registre de fuseaux (`cache.json` n'est pas relu pour cela), il ne reconstitue donc pas un voyage. Le JSON indique `endingLocalDay`, `timeZone` et le fuseau de chaque snapshot ; `--days` est borné de 1 à 60. Il faut fournir l'identifiant du bracelet tel qu'enregistré dans la sauvegarde. Le moteur utilise la difficulté et les séances rejetées dans `cache.json`, sauf `--difficulty` explicite. Les priorités Santé proviennent des réglages `UserDefaults` du processus macOS et sont consignées dans `healthSettings` ; elles peuvent différer des réglages de l'iPhone. Le digest couvre SQLite, WAL et cache ; la version est une étiquette saisie par l'opérateur. La sortie contient les séances réconciliées, les nuits et les snapshots quotidiens, avec leurs limitations fonctionnelles réelles. Le logger iOS est remplacé par un logger muet pour ne pas écrire dans Documents ni mélanger traces et JSON.

Pour comparer l'effet d'une FC maximale personnelle connue, ajouter `--max-hr 190` (exemple uniquement). Sans cette option, le moteur estime la FC maximale à partir de l'historique. Ce paramètre de replay ne modifie pas les réglages de l'application iPhone.

`swift test` compile également les tests de réconciliation de `LoopTests` contre les sources réelles et les tests d'intégrité incrémentale compatibles macOS. Le test de `LoopDataRepository` qui dépend d'UIKit ne peut pas tourner ici ; la compilation de ces sources et ces tests ne remplacent pas un lancement sur iPhone ni les tests du runtime HealthKit. Le replay ne réalise aucun nouvel import HealthKit : il traite uniquement les données déjà présentes dans la sauvegarde.
