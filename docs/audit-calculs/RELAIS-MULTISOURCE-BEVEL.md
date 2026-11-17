# Relais de récupération multisource

Bevel sert ici de référence fonctionnelle : sources distinctes par mesure, données complémentaires, fenêtres temporelles explicites et absence de double comptage. Sa formule propriétaire n'est pas reproduite. Voir [ses réglages de calcul](https://help.bevel.health/en/articles/10431233) et [son guide de sources](https://help.bevel.health/en/articles/10416961).

## Fonctionnement ajouté

- Le sommeil retenu (bracelet ou Santé selon priorité) définit la fenêtre utilisée pour chercher les observations Santé de la nuit.
- Le SDNN de l'Apple Watch est résumé par la médiane des échantillons valides de cette fenêtre. Un seul producteur est retenu ; les doublons d'horodatage ne renforcent pas le nombre d'observations. Les autres sources HealthKit ne sont pas automatiquement considérées comme du SDNN Apple vérifié.
- À défaut d'une FC de repos nocturne du bracelet et de sa baseline, la médiane de FC Watch pendant la fenêtre de sommeil peut servir de **proxy expérimental**, avec au moins cinq mesures distinctes couvrant au moins 30 minutes. Ce proxy n'est pas la FC de repos journalière d'Apple ni la FC de repos nocturne du bracelet. La valeur, la méthode, le producteur et le nombre d'échantillons sont conservés.
- Chaque baseline est propre au couple mesure/producteur/méthode. Le RMSSD du bracelet n'est jamais fusionné avec le SDNN, et les FC de définitions différentes ne partagent pas de baseline. Les valeurs manquantes restent des trous dans le calendrier. Une source non calibrée ne peut pas emprunter la référence d'une autre.
- Lorsque le RMSSD et sa baseline sont utilisables, ils restent prioritaires ; le SDNN Watch prend le relais quand il possède sa propre référence. Les données nécessaires à ces références sont persistées même les jours où le bracelet est choisi, pour préserver les recalculs incrémentaux.
- Les résultats utilisant le SDNN ou le proxy Watch sont limités à une confiance moyenne et libellés expérimentaux. Les composantes et leur source sont conservées dans le snapshot. Les anciens caches sont invalidés par la version du moteur et l'identité du bracelet.

## Limites

Il s'agit d'un modèle de bien-être expérimental, non d'une reproduction de Bevel ou d'une mesure clinique de récupération. La médiane de FC nocturne ne constitue pas une FC de repos validée ; le SDNN échantillonné ponctuellement dépend du capteur et du contexte. Des nuits annotées supplémentaires et une validation contre une référence indépendante sont nécessaires.

Le relais Watch ne fonctionne que si Santé contient suffisamment d'observations nocturnes et si l'historique propre à chaque métrique/source est suffisamment complet. Il peut être indisponible même si des données Santé journalières existent. Le stress n'a pas encore de relais Apple complet. L'import des séries de battements Apple et leur usage éventuel pour RMSSD restent un chantier séparé ; ne jamais calculer RMSSD à partir d'une moyenne de FC. Les priorités fines par appareil, le fuseau local historique et l'évaluation sur iPhone restent à compléter.
