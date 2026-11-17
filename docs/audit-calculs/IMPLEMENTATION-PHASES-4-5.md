# Moteur cardio et récupération — état des travaux

## Changements

- FC : filtrage des valeurs non finies ou hors limites techniques (25–250 bpm ; repos 25–150), doublons temporels neutralisés, trous bornés à 10 secondes de support, paramètres et réserve contrôlés. Ces bornes sont des garde-fous d'entrée, pas une validation physiologique.
- Charge : zones d'effort ≥50 % de réserve FC conformément aux bornes affichées ; le temps sous cette zone reste mesuré séparément. La contribution historique dès 20 % à la charge quotidienne est conservée, mais n'est plus comptée dans les minutes de zone 1. Score borné à 21. Le modèle et son échelle demeurent des approximations Loop.
- Fusion : sur les plages de séances enregistrées, la source FC externe placée avant le bracelet dans les préférences peut remplacer celui-ci, seulement lorsque ses mesures sont disponibles ; le reste du temps, le bracelet et les sources de secours restent disponibles. Pas de double comptage. Les mêmes règles alimentent la charge journalière et les séances.
- Références personnelles : dispersion MAD normalisée une seule fois, références obsolètes après des observations manquantes ou invalides, confiance dégradée si références ou observations manquent. Les composantes standardisées de récupération sont conservées avec le snapshot.
- Sommeil : le score personnalisé attend une référence de durée disponible et un résumé valide ; une période non classée ou une efficacité inconnue ne devient pas un score artificiel. Une valeur de stade connue et nulle est distinguée d'une valeur absente.
- Le calcul rapide ne remplace plus la FC de repos manquante par 60 bpm ou un percentile de la FC éveillée. Une absence reste absente ; une erreur de lecture Santé ne devient pas un score bracelet seul apparemment valide.
- Le snapshot conserve les minutes de FC prises en charge et les références FC utilisées. La clé de version du moteur a changé pour invalider les anciens résultats. Les baselines ou références en cours de calibration ne sont pas présentées comme fiables. Un indicateur de charge récente est absent plutôt que faux si la référence manque.
- Une API séparée calcule sRPE × durée quand une perception valide est fournie ; elle n'est pas additionnée au strain cardio. La saisie et le stockage du RPE dans l'app restent à construire.

## FC maximale et sensibilité

Le moteur accepte une FC maximale fournie explicitement et inclut cette valeur dans la clé de calcul. Le replay l'expose via `--max-hr` ; l'interface iPhone ne permet pas encore de la saisir, donc l'app continue à utiliser son estimation. Aucune valeur personnelle n'a été déduite arbitrairement.

Sur la sauvegarde du 14 novembre, un replay de trois jours donne une estimation FC max de 169 bpm, un strain quotidien de 13,91 pour le 13 et une charge de course de 11,33. Avec une **hypothèse illustrative non vérifiée** de 190 bpm, ces valeurs deviennent respectivement 13,23 et 10,16. Cela illustre la sensibilité du modèle, pas la vraie FC max ni une validation des scores. La fenêtre temporelle choisie influence l'estimation.

## Limites restantes

- Pondérations, seuil de contribution à 20 % HRR, normalisation et seuil de qualité des séances restent des hypothèses à calibrer sur des séances variées et des références indépendantes. Ne pas présenter ces scores comme équivalents à WHOOP.
- Le calcul emploie encore une FC maximale estimée depuis le pool de toute la fenêtre : un recalcul historique peut donc être influencé par une FC ultérieure. Une référence personnelle datée et sa provenance restent à intégrer dans l'app.
- Les références Santé ne disposent pas encore d'une identité de capteur et d'un indicateur de qualité assez riches pour arbitrer tous les conflits multisources. Les observations maintenues jusqu'à 10 s sont du support estimé, pas des mesures indépendantes à 1 Hz.
- Les sorties de preuve sont persistées, mais leur présentation complète dans l'interface reste à construire. L'import, la saisie et la persistance du RPE utilisateur restent à connecter.
- Les contrôles sont techniques, pas des diagnostics. La récupération et les stades de sommeil exigent une validation prospective ; Apple Watch sert de comparateur imparfait.
- Le calendrier reste UTC ; tests UIKit/iPhone, performances et consommation batterie réels restent à vérifier.

## Sources de méthode

- FC maximale : [étude chez des sportifs d'endurance et limites individuelles des prédictions par âge](https://pubmed.ncbi.nlm.nih.gov/42088591/).
- Charge sRPE : [étude de validité de méthodes de charge d'entraînement](https://pubmed.ncbi.nlm.nih.gov/24662229/).
- Variabilité des mesures HRV : [étude longitudinale de fiabilité](https://pubmed.ncbi.nlm.nih.gov/32505705/).
