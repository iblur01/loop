# Analyse de style — app de référence « Century »

Statut : document d'analyse. Les tokens de la section 11 sont une **proposition à valider**.
Convention : **[O]** = observé sur capture ; **[D]** = déduit ; toute valeur hex est **estimée** (capture
compressée, rendu P3 converti, transparences composées sur fond noir). Échelle : captures 1206 × 2622 px
à 3x, soit ~402 pt de large ; les tailles en pt sont des conversions estimées (px ÷ 3).

## 0. Corpus et tri des captures

| Fichier | App | Contenu |
|---|---|---|
| 37e91f5c | Century | Accueil : FC repos, bloc longévité (âge biologique, espérance de vie) |
| d83a5528 | Century | Accueil : charge cardio (sparkline), carte coaching, VO2 max, FC repos |
| 4bc23ec5 | Century | Accueil : carte coaching, liste des activités sur fond de carte |
| fbeac86c | Century | Accueil : batterie corporelle, VFC, température, SpO2 |
| 9a7882da | Century | Feuille Effort : jauge à deux arcs, coaching, courbe effort/récupération 7 j |
| fa7b5ce0 | Century | Feuille Effort : détail activités, kcal, pas, zones FC |
| a005de4c | Century | Feuille Effort : kcal, pas, barre zones, lignes de zone 5→1 |
| 326a3efa | Century | Feuille Récupération : tendance en barres 7/14/30 j, légende d'état |
| f5ec710c | Century | Feuille Récupération : VFC, FC repos, sommeil |
| 163a3ba7 | Century | Feuille Récupération : sommeil, sommeil réparateur, charge d'hier |
| d49a4d39 | Century | Feuille séance : carte en tête, grille 2 × 3 de tuiles |
| 398b1691 | Century | Feuille séance : effort ressenti, zones, temps de récupération, courbe FC |
| 0d042d83 | Century | Feuille séance : lignes de zones 4→0, qualité de l'air, équivalence énergie |
| f7047359 | **Loop** | Détail Stress : jauge circulaire sur photo de fond, tuiles VFC/FC, coaching |
| 6dfd6493 | **Loop** | Détail Stress : courbe 24 h en dégradé, répartition élevé/moyen/faible |
| 0bb0973a | **Ni Century ni Loop identifié avec certitude** [D] | Sommeil principal sur fond bleu nuit, hypnogramme, verrou d'abonnement |

Critères [O] : Century = en-tête avec marque centrée + trois capsules (avatar, date, actions), barre
d'onglets à 3 entrées + bouton rond séparé, bouton flottant « analyser » violet. Loop = barre d'onglets à
4 entrées + bouton « + », libellé de section en capitales présent dans
`Loop/Features/Today/Detail/Stress/Components/StressHero.swift`. 0bb0973a n'a ni l'une ni l'autre
chrome, emploie une palette bleu nuit absente des deux autres et un verrou payant introuvable dans le
code Loop : exclu de l'analyse Century. Il est seulement cité en 5.8 pour l'hypnogramme, faute
d'équivalent Century dans le corpus.

## 1. Palette

### 1.1 Surfaces et texte (Century)

| Rôle | Valeur estimée | Observation |
|---|---|---|
| Fond de l'écran principal | `#000000` | [O] noir pur sous l'en-tête et entre les cartes |
| Fond des feuilles (sheets) | `#0E0E10` | [O] gris quasi noir, légèrement plus clair que l'accueil ; séparateurs horizontaux pleine largeur `#1C1C1E` entre sections |
| Carte niveau 1 | `#18181A` → `#141416` | [O] léger dégradé vertical, plus clair en haut |
| Bordure de carte | blanc ~8 % (`#FFFFFF14`) | [O] filet 1 px visible sur tout le pourtour |
| Carte imbriquée (niveau 2) | `#232325` | [O] blocs « plage optimale », coaching, lignes de zone, règle de vieillissement |
| Bordure carte niveau 2 | blanc ~10 % | [O] |
| Piste vide des barres | `#2C2C2E` (segments) ; hachures `#2A2A2C` sur `#1F1F21` | [O] |
| Texte primaire | `#FFFFFF` | [O] chiffres héros, titres de carte |
| Texte secondaire | `#9A9A9F` | [O] libellés, bornes d'axe, texte de coaching |
| Texte tertiaire | `#6A6A6E` | [O] valeurs « 0 min / 0 % », libellés atténués de zone vide |
| Mise en avant d'un jour (colonne) | `#2E2E30` | [O] rectangle arrondi derrière la date courante dans les graphes 7 j |

### 1.2 Couleur par métrique

Règle [O] : chaque métrique a **une teinte propre**, portée par l'icône de la carte et par l'**unité**
accolée au chiffre (le chiffre reste blanc). La même teinte colore le segment actif de la barre quand
la valeur est « hors norme » dans le sens défavorable.

| Métrique | Famille | Hex estimé | Usages observés |
|---|---|---|---|
| Charge cardio / effort court terme | magenta-rose | `#EC3A7E` | icône, unité, sparkline (fin de courbe), segment actif, point final lumineux |
| FC (repos, moyenne, max) | magenta-rose | `#EC3A7E` (variante plus vive `#FF2D8A` sur la courbe FC de séance) | icône cœur, unité « bpm », courbe FC avec aire dégradée rose → transparent |
| VO2 max | magenta-rose | `#EC3A7E` | icône poumons, unité, segment actif |
| VFC | vert | `#4CC46A` (unité), `#98F2A4` (segment) | icône, unité « ms », segment d'écart à la moyenne |
| Récupération | vert / jaune / rouge selon état | voir §2 | barres de tendance, points de la courbe récupération |
| Effort (feuille) | rouge-orangé | `#F0604A` | arcs de jauge (avec halo), courbe effort, icône haltère |
| Énergie active (kcal) | rouge-orangé | `#B8402F` → `#FF6347` | barre de progression en dégradé horizontal, icône flamme, unité « kcal » |
| Pas | vert franc | `#2EA05A` → `#4CFA90` | barre de progression en dégradé horizontal, icône |
| Sommeil / sommeil réparateur | violet | `#8E6CF6` | icône lune, unités « h » et « min » |
| Température cutanée | orange ambré | `#E8A04C` | icône thermomètre, unité « °C » |
| SpO2 | bleu ciel | `#6CB4F0` | icône, unité « % », segment actif, libellé d'état |
| Longévité (âge, espérance de vie) | bleu acier | `#3D8FCC` ; barre `#2F7FB8` → `#5AAFE0` | icône, unité « ans », barre de progression |
| Batterie corporelle | gris + orange-rouge | `#E8603A` | graduations remplies dans une jauge à traits ; valeur % en orange |
| Qualité de l'air | vert-jaune | `#9BE070` | valeur et segment actif |
| Pictogramme d'activité | vert-jaune fluo | `#B4F03C` | pictogramme dans une tuile carrée grise |

[D] La palette métrique reprend la logique des anneaux Apple (rose/rouge = cardio-effort, vert =
mouvement/récupération, bleu = respiration) sans en copier les valeurs exactes.

## 2. Système de couleur par état

### 2.1 Libellé d'état (à droite du chiffre héros)

| État observé | Couleur | Hex estimé |
|---|---|---|
| Très bon / excellent / charge légère / plus jeune | vert clair | `#7EE88E` |
| Normal | gris clair neutre | `#C8C8CC` |
| Moyen (sommeil « passable ») | rouge saumon | `#F2665A` |
| Sous la moyenne | rouge-orangé | `#EE6650` |
| Hors norme défavorable (FC haute, VO2 basse, surcharge) | **teinte de la métrique** (rose) | `#EC3A7E` |
| Hors norme mais non pénalisant (SpO2 haute) | teinte de la métrique (bleu) | `#6CB4F0` |

[O] Pas de couleur unique « mauvais » : le défavorable prend soit le rouge saumon, soit la teinte de la
métrique. [D] Il en résulte une ambiguïté (rose = « métrique cardio » ou « alerte » ?) à ne pas
reproduire telle quelle.

### 2.2 Trois niveaux de récupération (barres de tendance, points de courbe)

| Niveau | Haut de barre | Bas de barre |
|---|---|---|
| Prêt | `#88F5A0` | `#3FA45E` |
| Modéré | `#F8F050` | `#C8A020` |
| Repos | `#EE6A60` (barre courte, tête arrondie) | — |

[O] Le pourcentage au-dessus de chaque barre prend la couleur de la barre. Une légende en pastilles
(rond plein ~12 pt + libellé) est placée dans une carte au-dessus du graphe.

### 2.3 Badge de variation

[O] Capsule ~8 pt de rayon, fond = couleur de sens à ~20 % d'opacité, texte + flèche diagonale dans
la couleur pleine. Vert (`#3E7A4C` fond / `#86E596` texte) quand la variation est favorable, rose ou
rouge (`#4A1F2E` / `#EC5A8A`) quand elle est défavorable — **le sens favorable dépend de la métrique**
(baisse de température = vert ; hausse de FC repos = rouge).

### 2.4 Zones FC : 6 couleurs

| Zone | Couleur | Hex estimé |
|---|---|---|
| 0 (sous seuil) | gris | `#8E8E93` |
| 1 | violet lavande | `#9B7CF8` |
| 2 | bleu ciel | `#64BEFA` |
| 3 | vert | `#3FE07A` |
| 4 | rouge-orangé (variante brun-rouge `#9A4030` dans la barre compacte) | `#FF5A40` |
| 5 | bordeaux | `#8C1A4A` |

[O] Barre de répartition : segments arrondis (~6 pt) séparés de ~3 pt, largeur proportionnelle au
temps, les zones à 0 % gardent un segment minimal. Lignes de détail : une carte niveau 2 par zone,
de la plus haute à la plus basse, barre colorée sur piste hachurée ; texte de zone grisé quand vide.

## 3. Typographie

[O] Police : sans-serif grotesque géométrique non système (chiffres larges, « 1 » à empattement de
tête, « a » à deux étages, tracking serré sur les grands chiffres). [D] Proche d'une famille type
Inter / General Sans ; non identifiable avec certitude.

| Niveau | Taille estimée | Graisse | Casse | Couleur |
|---|---|---|---|---|
| Chiffre héros de carte | 44–48 pt | semibold | — | blanc |
| Unité accolée | ~0,55 × héros (24–26 pt), alignée sur la ligne de base | regular/medium | minuscule | teinte métrique |
| Chiffre de tuile (grille 2 colonnes) | 30–32 pt | semibold | — | blanc ; unité ~16 pt collée sans espace |
| Libellé d'état (droite) | 20–22 pt | regular | casse phrase | couleur d'état |
| Titre de carte (avec icône 24 pt) | 20 pt | regular/medium | casse phrase | blanc |
| Titre de section (hors carte) | 22 pt | medium | casse phrase | blanc |
| Titre de feuille (centré) | 20 pt | medium | casse phrase | blanc |
| Texte de coaching | 17 pt, interligne ~1,45 | regular | phrase | secondaire |
| Sur-titre de bloc coaching | 15 pt, interlettrage +0,5 | semibold | **CAPITALES** | secondaire |
| Date de l'en-tête | 15 pt | semibold | **CAPITALES** abrégées | blanc |
| Bornes d'axe / légendes | 13–15 pt | regular | — | secondaire |
| Pourcentage au-dessus d'une barre | 13 pt | medium | — | couleur de la barre |

[O] Hiérarchie par **taille et couleur**, très peu par graisse. Les capitales sont réservées à deux
usages (date, sur-titre de bloc analytique). Valeurs composées « 1284 / 400 kcal » : chiffre primaire
blanc 24 pt, objectif en secondaire 20 pt. Les durées « 5 h 28 min » alternent chiffre blanc héros et
unités colorées.

## 4. Cartes

| Propriété | Valeur estimée | Statut |
|---|---|---|
| Rayon carte niveau 1 | ~30 pt, coin continu | [O] |
| Rayon carte niveau 2 (imbriquée) | ~22 pt | [O] |
| Rayon tuile de grille | ~28 pt | [O] |
| Bordure | 1 px blanc 8–10 % | [O] |
| Ombre | aucune visible sur fond noir | [O] |
| Marge interne | 15–16 pt horizontal, ~18 pt vertical | [O] |
| Marge écran → carte | ~9 pt sur l'accueil, ~16 pt dans les feuilles | [O] |
| Espacement entre cartes | ~8 pt | [O] |
| Espacement section → titre de section | ~36–40 pt au-dessus, ~14 pt dessous | [O] |
| Fond | opaque, dégradé subtil haut clair → bas sombre | [O] |

[O] Structure fixe d'une carte métrique : ligne 1 icône + titre + chevron ; ligne 2 chiffre héros +
unité + badge, état aligné à droite ; ligne 3 barre ; éventuellement ligne 4 bornes min / moyenne /
max. Densité élevée : 3 à 4 cartes métriques par écran.

[O] Plat : toutes les cartes de contenu. Verre / flou : chrome uniquement (§8).

[O] Carte d'activité : fond = carte géographique sombre teintée vert-bleu (`#1F3A3A` estimé) avec le
tracé en blanc, texte posé directement dessus, rangée de trois statistiques en bas.

## 5. Graphiques

### 5.1 Barre segmentée avec curseur [O]
5 ou 6 segments gris `#3A3A3C`, hauteur ~7 pt, écart ~2 pt, extrémités arrondies uniquement aux deux
bouts. Le segment correspondant à la valeur prend la couleur d'état/métrique. Curseur : triangle blanc
plein ~14 pt pointant vers le bas, posé au-dessus de la barre à la position exacte.

### 5.2 Barre de plage hachurée [O]
Capsule ~16 pt de haut, piste à hachures diagonales fines. Deux variantes : progression (remplissage
depuis la gauche, couleur d'état, bord droit droit) ; écart à la moyenne (bande colorée entre la
moyenne 7 j et la valeur, triangle blanc sur la valeur, bornes min / moyenne / max en dessous).

### 5.3 Barre de progression dégradée [O]
Capsule ~16 pt, remplissage en dégradé horizontal sombre → vif de la même teinte (kcal, pas,
espérance de vie). Pas de piste visible quand l'objectif est dépassé.

### 5.4 Règle à graduations [O]
Traits verticaux serrés (~1,5 pt, pas ~3 pt), graduations majeures plus claires, poignée blanche en
capsule verticale. Variante « jauge batterie » : traits dans une capsule bordée, les traits remplis
passent en orange-rouge.

### 5.5 Courbe avec points [O]
Deux séries sur 7 jours, trait ~2,5 pt, points creux (cercle ~10 pt, contour 2,5 pt, centre = fond).
Grille horizontale en pointillés `#3A3A3C`, pas d'axe vertical ni de valeurs Y. Les points de la série
récupération sont colorés par état (vert / jaune / rouge) alors que la ligne reste grise. Jour courant :
colonne arrondie `#2E2E30` sur toute la hauteur, libellé en blanc ; autres jours en secondaire.
Légende en pastilles dans une capsule niveau 2 sous le graphe.

### 5.6 Barres arrondies avec pourcentage au-dessus [O]
Barres ~18 pt de large, sommet en demi-cercle, base droite, dégradé vertical de la couleur d'état.
Valeur au-dessus en couleur de la barre. Jour sans donnée : tiret court gris. 3 lignes de grille
pleines discrètes. Sélecteur 7 / 14 / 30 jours au-dessus, à droite du titre de section.

### 5.7 Sparkline dans la carte [O]
Courbe à points pleins, trait ~3 pt, **dégradé le long du trait** (violet → rose), dernier point
blanc avec halo rose. Bande de référence verte très sombre (`#1E3A24`) sous la courbe.

### 5.8 Autres
- Jauge d'effort [O] : deux arcs épais symétriques (rouge-orangé, halo flou), graduations grises
  intérieures, chiffre central ; dans la feuille il est flouté par l'effet de bord de défilement.
- Courbe FC de séance [O] : trait rose vif ~3 pt, aire remplie rose → transparent, ligne de seuil en
  pointillés avec valeur à gauche.
- Effort ressenti [O] : 10 barres verticales croissantes grises (échelle vide = non saisi).
- Hypnogramme en escalier : **non observé dans les écrans Century du corpus**. Seul 0bb0973a
  (app non identifiée) en montre un : marches pleines par phase, éveil orange `#F0A878`, paradoxal
  lavande `#A8B8F8`, léger `#6A8CF0`, profond indigo `#5A5CC8`, sur fond bleu nuit, avec anneaux de
  proportion par phase. À traiter comme inspiration secondaire, non comme style Century.

## 6. Composants récurrents

| Composant | Description observée |
|---|---|
| Tuile de métrique | Carte niveau 1 demi-largeur : libellé secondaire 17 pt, chiffre 30 pt + unité colorée collée. Grille 2 colonnes, gouttière ~9 pt. |
| Carte métrique | §4, structure en 3–4 lignes. |
| Carte de tendance | Titre de section + segmented à droite, puis carte avec barres §5.6 et colonne du jour surlignée. |
| Barre segmentée + curseur | §5.1. |
| Badge de variation | §2.3. Flèche diagonale (↗ / ↘), delta signé avec une décimale. |
| Sélecteur de période | Capsule `#1C1C1E`, 3 options, option active en capsule `#4A4A4E` texte blanc ; inactives en blanc régulier. |
| Bloc coaching | Carte niveau 2 légèrement plus claire (`#262628`), bordure plus marquée ; sur-titre en capitales + glyphe de marque à gauche, lien d'action blanc semibold + chevron à droite, texte 2–3 lignes en secondaire. |
| Bouton flottant | Capsule ~64 pt de haut en bas à droite, verre teinté violet (`#3A3550` estimé), glyphe de deux barres verticales + libellé. Sur l'accueil : rond ~60 pt à droite de la barre d'onglets. |
| Barre d'onglets | Capsule verre flottante, 3 entrées icône + libellé, entrée active dans une capsule interne plus sombre ; bouton rond séparé à droite. |
| En-tête de page | Marque centrée ; dessous trois capsules verre : avatar + compteur, navigateur de date (chevrons + date en capitales), groupe partage + réglages séparé par un filet vertical. |
| En-tête de feuille | Poignée grise 46 × 6 pt, titre centré, zone de titre floutée sur le contenu héros qui défile dessous. |
| Ligne de sources / méthode | Libellé secondaire à gauche, valeur blanche à droite, chevron discret. |
| Bouton d'action secondaire | Capsule pleine largeur niveau 2, « + » et libellé centrés blancs. |

## 7. Hiérarchie des écrans

[O] Accueil : en-tête → sections titrées (cardio, longévité, activités, indicateurs, sommeil…) →
dans chaque section une carte maître qui peut contenir des sous-cartes. Le score principal n'est pas
visible dans les captures d'accueil fournies (elles sont défilées) ; [D] il est probablement au-dessus.

[O] Feuilles de détail (effort, récupération) : héros (jauge ou score) → bloc coaching **immédiatement
sous le héros** → tendance 7 j → indicateurs contributeurs → détail.

[O] Coaching : jamais en texte libre sur fond ; toujours dans une carte niveau 2 distinguée par une
teinte plus claire, un sur-titre en capitales et un lien d'action vers l'assistant. Placement : sous le
héros d'une feuille, ou en bas d'une carte métrique (sous la barre). Phrases courtes, 1–2 phrases.
Conseils de séance (récupération restante, nature de la séance) : sous-cartes niveau 2 empilées, la
partie conclusive en vert d'état.

## 8. Verre (Liquid Glass)

| Élément | Traitement | Statut |
|---|---|---|
| Barre d'onglets | verre sombre, reflet spéculaire en bord haut, contenu visible flou dessous | [O] |
| Bouton rond à côté des onglets | verre, légère teinte rose/violette prise du contenu | [O] |
| Bouton flottant « analyser » | verre teinté violet, reflet en bord, contenu flou dessous | [O] |
| Capsules de l'en-tête (avatar, date, actions) | capsules verre sombre sur fond noir | [O] (le flou est peu visible car le fond est noir) |
| Feuilles | coin haut ~40 pt, fond opaque quasi noir ; la zone de titre floute le héros qui passe dessous | [O] |
| Cartes de contenu, barres, graphes | **opaques**, plats | [O] |

[D] Le verre est réservé à la couche de navigation et aux actions flottantes, conformément aux
recommandations iOS 26 ; le contenu reste opaque pour la lisibilité des chiffres.

## 9. Mouvement

Rien d'animé n'est observable sur des captures fixes. Seules déductions défendables :
- [D] Le glyphe du bouton flottant apparaît en deux barres verticales sur certaines captures et en
  deux tirets horizontaux sur d'autres : il est animé (pulsation/morphing de type indicateur vocal).
- [D] Le flou progressif du héros sous le titre de feuille implique un effet lié au défilement.
- [D] Les feuilles sont présentées en modal à poignée (geste de glissement vers le bas).
Aucune autre hypothèse (apparition décalée, ressorts) n'est étayée par le corpus.

## 10. Adapter pour Loop / ne pas copier

### À reprendre (principe, pas exécution)
- Teinte stable par métrique portée par l'icône et l'unité, chiffre toujours blanc.
- Chiffre héros + unité à ~55 %, alignés sur la ligne de base.
- Barre segmentée à curseur triangle et barre de plage avec moyenne 7 j.
- Colonne du jour courant surlignée dans les graphes 7 j.
- Bloc coaching distingué par une surface, placé sous le héros.
- Verre limité au chrome ; contenu opaque.
- Palette de zones FC à 6 teintes distinctes.

### À adapter (conflits avec `DESIGN.md` de Loop)
- `DESIGN.md` demande « une seule teinte accent par page » et bannit l'arc-en-ciel par état. Option
  compatible : sur une page de détail, une seule teinte (celle de la métrique) + les trois couleurs
  d'état sémantiques ; sur l'accueil, la teinte par métrique reste limitée à l'icône et à l'unité.
- Unifier la sémantique d'état : vert / ambre / rouge uniquement pour l'évaluation, jamais la teinte
  métrique comme signal d'alerte (corrige l'ambiguïté rose relevée en §2.1).
- Remplacer la police custom par SF Pro (ou SF Pro Rounded pour les chiffres) avec chiffres
  tabulaires : coût nul, Dynamic Type natif.
- Libellés d'état : la référence mélange anglais et français ; Loop doit tout localiser.
- Ajouter le mode clair (la référence n'est observée qu'en sombre).
- Les cartes répétitives de même gabarit (anti-pattern Loop) : regrouper les indicateurs secondaires
  dans une surface unique.

### À ne pas copier
- Nom, glyphe de marque (fleur à quatre lobes), marque dans l'en-tête et dans le sur-titre coaching.
- Tous les textes : libellés, phrases de coaching, intitulés de sections, noms d'indicateurs propres
  (âge biologique de marque, etc.).
- Le gabarit exact de l'en-tête (trio avatar-compteur / date / partage-réglages) et l'ordre des
  sections.
- Le bouton flottant violet à deux barres et son libellé.
- La carte d'équivalence alimentaire et ses emoji.

## 11. Tokens cibles proposés (PROPOSITION À VALIDER)

Valeurs sRGB. Sombre = dérivé des observations ; clair = proposition sans référence observée.

| Token | Rôle | Clair | Sombre |
|---|---|---|---|
| `bg.base` | fond d'écran | `#F2F2F7` | `#000000` |
| `bg.sheet` | fond de feuille | `#F7F7FA` | `#0E0E10` |
| `surface.1` | carte | `#FFFFFF` | `#18181A` |
| `surface.2` | carte imbriquée, coaching | `#F0F0F4` | `#232325` |
| `surface.highlight` | colonne jour courant, option active | `#E4E4EA` | `#2E2E30` |
| `stroke.card` | filet de carte | `#0000000F` | `#FFFFFF14` |
| `track.empty` | piste/segments vides | `#E2E2E8` | `#2C2C2E` |
| `grid.line` | grille pointillée | `#D1D1D6` | `#3A3A3C` |
| `text.primary` | chiffres, titres | `#0B0B0C` | `#FFFFFF` |
| `text.secondary` | libellés, coaching | `#6C6C72` | `#9A9A9F` |
| `text.tertiary` | valeurs vides | `#A1A1A6` | `#6A6A6E` |
| `state.good` | bon / prêt | `#1E9E4A` | `#7EE88E` |
| `state.fair` | moyen / modéré | `#C98A00` | `#F5D547` |
| `state.poor` | faible / repos | `#D63B30` | `#F2665A` |
| `state.neutral` | normal | `#6C6C72` | `#C8C8CC` |
| `metric.cardio` | FC, charge, VO2 | `#D81B6A` | `#EC3A7E` |
| `metric.hrv` | VFC | `#20A050` | `#4CC46A` |
| `metric.sleep` | sommeil | `#6A4BE0` | `#8E6CF6` |
| `metric.effort` | effort, kcal | `#E04A30` | `#F0604A` |
| `metric.steps` | pas | `#1F9A50` | `#4CFA90` |
| `metric.temp` | température | `#C77A1E` | `#E8A04C` |
| `metric.spo2` | SpO2 | `#2C86D6` | `#6CB4F0` |
| `metric.stress` | stress | `#C9A000` | `#F5D547` |
| `metric.energy` | batterie / énergie | `#E0602E` | `#E8603A` |
| `zone.0` | zone FC 0 | `#8E8E93` | `#8E8E93` |
| `zone.1` | zone FC 1 | `#7A5AF0` | `#9B7CF8` |
| `zone.2` | zone FC 2 | `#2E9EE8` | `#64BEFA` |
| `zone.3` | zone FC 3 | `#1FB85A` | `#3FE07A` |
| `zone.4` | zone FC 4 | `#E8462E` | `#FF5A40` |
| `zone.5` | zone FC 5 | `#8C1A4A` | `#B0306A` |
| `badge.up.bg` / `badge.down.bg` | fond badge variation | état à 14 % | état à 20 % |

Mesures associées proposées : rayon carte 28 pt, rayon carte imbriquée 20 pt, marge interne 16 pt,
gouttière 8 pt, marge écran 16 pt ; barre segmentée 7 pt de haut, écart 2 pt ; barre de plage 14 pt ;
curseur triangle 12 pt ; chiffre héros 44 pt semibold, unité 24 pt ; titre de carte 17 pt semibold
(SF), titre de section 22 pt bold.

Contrôles à faire avant adoption : contraste AA des teintes claires sur `surface.1` (vert, ambre et
jaune sont les plus à risque), distinction zone 4 / `state.poor` et zone 5 / `metric.cardio` pour les
daltoniens, compatibilité avec la règle d'accent unique de `DESIGN.md`.
