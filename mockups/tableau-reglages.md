# Tableau des réglages (page Réglages)

Chemins relatifs à `/Users/theo/dev/loop`. « Oui » signifie que la donnée ou la fonction existe dans le code ; l'emplacement de l'UI peut changer.

| Réglage | Existe dans le code (oui/non) | Référence fichier:ligne |
|---|---|---|
| Alarme du bracelet (activée) | oui | `Loop/Core/Preferences/UserPreferences.swift:21` (`alarmEnabled`) ; déclenchement BLE `Loop/Core/Alarm/SmartAlarmController.swift:80` |
| Mode d'alarme (off / régulier / intelligent) | oui | `Loop/Core/Preferences/UserPreferences.swift:25, :185` ; `Loop/Core/Preferences/AlarmMode.swift` |
| Heure d'alarme | oui | `Loop/Core/Preferences/UserPreferences.swift:22-23, :162-163` |
| Jours d'alarme | oui | `Loop/Core/Preferences/UserPreferences.swift:24, :181` ; lu par `Loop/Features/Today/Widgets/AlarmWidget.swift:27` |
| Fenêtre intelligente (5–30 min) | oui | `Loop/Core/Preferences/UserPreferences.swift:26, :164-166` ; lu par `Loop/Features/Today/Widgets/AlarmWidget.swift:29` |
| Notifications de l'app | non | aucune `UNUserNotification` dans `Loop/` |
| Unités (métrique / impérial) | oui | `Loop/Core/Preferences/UserPreferences.swift:20, :144-158` ; UI `Loop/Features/Profile/Components/BodyProfileCard.swift:80-95` (aucun affichage impérial vérifié) |
| Apparence (clair / sombre / système) | non | suit le système : `Loop/Shared/DesignTokens/LoopColor.swift:15-19` |
| Langue | non | langue système, `Loop/Resources/en.lproj/Base.strings`, `Loop/Resources/fr.lproj/Base.strings` ; pas de `LanguageManager` |
| Autorisations Apple Santé | oui | `Loop/Features/Profile/Health/HealthImportView.swift:52-61` (demande, « Revoir les permissions » via `openSettingsURLString` :57) |
| Exporter une sauvegarde (`.loopbackup`) | oui | `Loop/Features/Profile/Backup/BackupView.swift:29-60` ; `Loop/Core/Backup/BackupDocumentPickers.swift` |
| Exporter en CSV | non | aucun export CSV/JSON ; seul import CSV Hevy `Loop/Features/Profile/Backup/BackupView.swift:120, :165-168` |

## Réglages qui restent sur Profil (données de la personne, hors page Réglages)

| Réglage | Existe dans le code (oui/non) | Référence fichier:ligne |
|---|---|---|
| Réveil cible | oui | `Loop/Core/Preferences/UserPreferences.swift:16-17, :80-81` ; `BodyProfileCard.swift:24-48` |
| Objectif de sommeil | oui | `Loop/Core/Preferences/UserPreferences.swift:18, :98-100` ; `BodyProfileCard.swift:52-76` |
| Difficulté d'effort | oui | `Loop/Core/Preferences/UserPreferences.swift:14, :218-220` ; `StrainDifficultyCard.swift` |
| Taille / poids (modification hors onboarding) | non (saisie onboarding seulement) | `UserPreferences.swift:29-30, :121-135` ; `Loop/Features/Onboarding/OnboardingView.swift:289-290` |
| Âge manuel | oui (UI non montée) | `UserPreferences.swift:28, :111, :267-279` ; `MaxHeartRateCard.swift` (seul usage : `#Preview` :181) |
| FC max auto (Tanaka) | oui | `Loop/Core/Preferences/UserMaxHeartRate.swift:40-45` ; résolution `UserPreferences.swift:254-263` |
