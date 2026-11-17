# Loop

[English](README.md)

Loop est une application iPhone expérimentale qui rassemble les données de santé et d’activité au même endroit. À terme, son ambition est de proposer une expérience comparable à Bevel, avec la prise en charge d’un bracelet WHOOP en complément d’autres sources comme Apple Santé.

Loop se connecte directement à un **WHOOP 4.0** en Bluetooth et rassemble ses données avec les informations compatibles d’Apple Santé. La prise en charge du **WHOOP 5.0 n’a pas été testée** et n’est pas garantie.

## Ce que fait Loop

- Collecte les données d’un bracelet compatible et les rassemble avec les données Apple Santé disponibles.
- Présente des indicateurs quotidiens : sommeil, récupération, effort, VFC et fréquence cardiaque au repos.
- Calcule les indicateurs et les références personnelles sur l’iPhone, à partir des données accumulées au fil du temps.
- Conserve les données localement et fonctionne hors ligne, sans serveur ni connexion au cloud WHOOP.
- Propose une sauvegarde et une restauration manuelles facultatives via l’application Fichiers.

Loop est conçu comme un projet personnel et reste en cours de développement. Ses fonctionnalités et ses calculs peuvent évoluer.

## Bêta et fiabilité

**Loop est en bêta.** Une grande partie du travail porte sur l’amélioration du moteur de calcul, notamment la détection du sommeil, la récupération, l’effort et les références individuelles. Je porte une Apple Watch en parallèle du bracelet pour comparer les mesures et repérer les incohérences.

Ces comparaisons ne garantissent ni l’exactitude des résultats ni leur équivalence avec ceux de WHOOP ou de l’Apple Watch. Les indicateurs sont des estimations, peuvent être incomplets ou incorrects et ne constituent pas un avis médical.

## Origines et inspirations

Loop est une refonte du prototype **my-whoop / OpenWhoop**. Il s’inspire aussi de projets comme [Noop](https://github.com/app-noop/noop), ainsi que de l’idée d’applications comme Bevel qui rassemblent les données de santé.

Loop est un projet indépendant, sans affiliation avec WHOOP, Noop ou Bevel.

## Prérequis

- Un iPhone sous **iOS 27 ou une version ultérieure**.
- Un bracelet WHOOP 4.0 pour les données du bracelet. La compatibilité avec le WHOOP 5.0 n’a pas été testée.
- Un Mac et une version de Xcode compatible avec iOS 27 pour compiler l’application.
- Un véritable iPhone pour la connexion Bluetooth.

## Installation avec Xcode

1. Clonez le dépôt et ouvrez `Loop.xcodeproj` dans Xcode.
2. Dans **Signing & Capabilities**, sélectionnez votre équipe Apple pour les cibles de l’application et du widget. Définissez des identifiants de bundle uniques et un App Group partagé entre les deux cibles, selon les besoins de votre compte.
3. Connectez votre iPhone, sélectionnez-le comme destination et lancez le schéma **Loop**. Activez le mode développeur sur l’iPhone si nécessaire.
4. Ouvrez Loop, accordez les autorisations que vous souhaitez utiliser et associez votre bracelet dans l’application.

Si vous modifiez `project.yml` ou ajoutez des fichiers source, installez [XcodeGen](https://github.com/yonaskolb/XcodeGen) et lancez `xcodegen generate` pour régénérer le projet Xcode.

Avec une équipe personnelle Apple gratuite, la signature de développement expire généralement après **7 jours** : il faut alors recompiler ou signer à nouveau l’application.

## Signer et installer une IPA

Téléchargez l’IPA non signée depuis les [releases GitHub](https://github.com/iblur01/loop/releases), ou générez la vôtre, puis signez-la et installez-la par sideload avec la méthode de votre choix. Personnellement, j’utilise UDID Registry pour signer une IPA pendant environ un an, généralement pour près de 20 €. Les prix, la disponibilité et la validité du certificat peuvent varier.

## Captures d’écran

Des captures d’écran seront ajoutées au fil de l’évolution de l’interface.
