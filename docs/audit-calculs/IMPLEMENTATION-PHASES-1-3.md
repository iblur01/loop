# État d'implémentation — phases 1 à 3

## Réalisé

- Replay macOS sur copie privée des sauvegardes, journal WAL inclus. `loop-daily-replay` utilise le moteur de l'app et la réconciliation Santé ; voir `Tools/LoopReplay/README.md` pour les commandes et limites.
- Révisions persistées et transactionnelles des flux et séances, incluant ajouts, modifications et suppressions ; recalcul incrémental, invalidation par version et priorité de sources, conservation de l'historique des rafraîchissements courts et sérialisation des écritures du cache.
- Synchronisation des séances Santé au démarrage et par observer après activation ; réconciliation conservatrice, sports et sources conservés, doublons croisés, FC et strain par séance sous condition de couverture suffisante. Les charges de séance ne sont pas additionnées au strain journalier.
- Données de sommeil Santé retenues suivant les priorités de sources ; durée sans stade conservée sans inventer de stades. La VFC SDNN Santé n'est pas traitée comme RMSSD. Les stades absents ne génèrent plus d'hypnogramme fictif.
- Les relevés FC Santé répétés à la seconde ne gonflent plus artificiellement la couverture. Une source manquante reste absente.
- Attribution du résumé de sommeil alignée sur le fuseau UTC du pipeline actuel ; les incohérences internes près de minuit sont corrigées, mais les journées ne sont pas encore locales.

## Rejeu et vérifications

Sur une copie de la sauvegarde Santé fournie : course de 10,027 km et marche distinctes ; les segments de sommeil Santé donnent 408,31 min après correction d'un chevauchement flottant. Ce résultat confirme le traitement des données Santé de ce cas, pas la précision clinique des stades.

Vérifications sur Mac : 234 tests du paquet moteur (7 ignorés) ; tests ciblés supplémentaires de fuseau ; 89 tests du stockage ; 27 tests du banc replay et de l'intégration native macOS. L'app et les tests iOS compilent pour simulateur générique. Les tests UIKit n'ont pas été exécutés : le runtime iOS 27 est absent ; sur Mac, le profil de signature existant n'autorise pas l'installation de l'app.

## Limites restantes

- Le jour reste découpé en UTC. La migration vers une politique de fuseau local cohérente pour affichage, calcul, historique et changements d'heure reste à réaliser. Les anciennes données ne contiennent pas toutes un fuseau historique permettant de reconstituer les voyages.
- Les tests de parité complet/incrémental couvrent notamment des mutations Santé et le déplacement d'une mesure, pas toutes les combinaisons de baselines et de sources. Certaines lectures de référence et de rapport journalier peuvent encore masquer des erreurs.
- La charge quotidienne et le modèle de sommeil du bracelet n'ont pas été validés ou recalibrés par ce chantier. Les seuils et scores ne démontrent pas une équivalence avec WHOOP ni une précision médicale. Le nombre de cas réels reste limité.
- Le coût des révisions par échantillon et du scan historique FC doit être mesuré sur iPhone ; le benchmark en mémoire sur Mac n'établit pas les performances sur téléphone.
- Le replay repose sur une sauvegarde inactive : copier les trois fichiers SQLite en présence d'une base en cours d'écriture ne constitue pas un instantané atomique.
