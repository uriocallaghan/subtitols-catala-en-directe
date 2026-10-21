# L'app d'iPhone

Aquesta nota explica què hi ha fet de l'app d'iPhone, com es prova i què falta per publicar-la a l'App Store. No cal saber programar per seguir-la.

Estat a 26 de setembre de 2026: l'app funciona al simulador d'iPhone i transcriu català de veritat. **Encara no s'ha provat en un iPhone de veritat, ni s'ha pujat a l'App Store.**

---

## Què fa

- **S'instal·la sense cap idioma.** A la primera obertura proposa l'idioma del telèfon i en mostra la mida (el català fa uns 190 MB). No baixa res fins que la persona toca "Baixa". Si l'App Store no pot servir el paquet (la revisió d'Apple sovint no pot, i va rebutjar el Mac per això el 6 d'octubre de 2026), l'app baixa el mateix fitxer d'una còpia a GitHub i en comprova la suma abans d'instal·lar-lo. A partir d'aquí funciona sense connexió.
- **Segueix el disseny "Versió final" de pen.dev:**
  - a dalt, l'orbe Seda;
  - al mig, el text que puja;
  - a baix, la barra flotant (fiabilitat, mida, tipografia, visualització i gravar).
- **L'orbe reacciona a la veu.**
  - La forma és sempre un cercle perfecte, que no es deforma mai. Tota la vida és a dins.
  - En silenci es mou poc a poc, com lava que reposa.
  - Quan algú parla, brolla: el líquid remou fins a 6 vegades més de pressa i més a fons, amb una empenta a cada síl·laba.
  - Fa servir els colors exactes del projecte (#FF6400 a #FFC200).
  - El gra és fi i suau, i es redibuixa 24 vegades per segon. Està fet amb els colors del mateix orbe. Un gra més fort (1,4) i els modes de fusió es van provar i descartar el 27 de setembre.
- **Tocar la pantalla comença o atura la transcripció**, com al Mac, i el missatge inicial ho diu. Si hi ha un ajustament obert, el primer toc només el tanca.
- **El text puja i s'esvaeix cap a l'orbe.** Arriba fins a 6 punts de la vora de baix de l'orbe, i no se n'atura a la franja on es dibuixa:
  - les línies que s'estan llegint queden amb tot el contrast;
  - les de més amunt es van apagant de manera suau;
  - a dalt de tot el text es dissol en una franja d'una línia i mitja, en comptes de tallar-se sec contra l'orbe.
  Al Mac no canvia res d'això.
- **Tot passa dins la barra, com al Mac.** En tocar un ajustament:
  - el pou tocat creix fins a omplir la barra i hi apareix el control, peça a peça;
  - els altres pous s'esvaeixen i s'encongeixen allà on són;
  - el botó vermell es converteix en el botó de tancar (✕), al mateix lloc.

  Reacciona en el moment que el dit toca (no quan s'aixeca), tot segueix una sola molla i el primer fotograma és exactament la barra tancada, així que res no apareix de cop ni fa esperar. Els marges són els mateixos oberta i tancada: 6 punts al voltant, 6 entre pous i 3 dins de cada pou.

  Visualització hi posa en una fila el tema (Auto, Clar i Fosc, un toc canvia al següent), Degradat, Orbe, Idioma i Info. Tots els botons fan com a mínim 44 punts, la mida que Apple recomana per als dits.
- **La mida del text es nota als dits.** En arrossegar la barra de mida es noten uns clics molt fins. Cada mida fa un "toc" suau, una mica més ple com més gran és la lletra, i els extrems fan un cop esmorteït. La vibració també funciona mentre escolta.
- **Es pot tornar enrere al text** arrossegant-lo avall, sense barra de desplaçament. El text que arriba no mou el que estàs llegint. Un botó "Al directe" hi torna. Es guarden unes 1.500 paraules.
- **Exportar el text.** Quan hi ha text, a dalt a la dreta apareix una icona de compartir, gris clar i sense fons. Obre un panell amb tres formats, amb una mostra del principi del fitxer:
  - **Text** (.txt): només el text, en paràgrafs;
  - **Markdown** (.md): amb títol, data i durada;
  - **Subtítols** (.srt): una paraula per subtítol, cadascuna amb el seu temps.

  "Envia" obre el full de compartir amb el fitxer: AirDrop surt el primer, i al Mac el fitxer arriba a Baixades. "Notes" obre el mateix full amb el text (amb la data com a títol), i Notes hi surt entre les apps; iOS no deixa que una app escrigui directament a Notes sense aquest pas. Només s'exporta la sessió actual: la que va de "Comença" a "Atura", sencera encara que la pantalla ja només en guardi una part.
- **Mode fosc.** La visualització pot ser automàtica (la del telèfon), clara o fosca, i el canvi és animat.
- **Primera obertura: un joc de tres passos.** L'app s'obre en l'idioma del telèfon (català, gallec, basc, castellà o anglès; si no, en anglès) i passa per:
  1. benvinguda, amb la salutació escrivint-se, i l'idioma de l'app (els textos canvien al moment);
  2. la llengua que es baixarà (comença a baixar i es pot continuar; una píndola a dalt en mostra el progrés);
  3. el permís del micròfon. En donar-lo surt confeti sobre l'orbe; el text s'esvaeix, l'orbe puja fins al lloc que ocupa a la pantalla de lectura i l'app hi entra. Si la llengua encara baixa, s'espera mostrant el percentatge.

  No es pregunta la tipografia: per defecte és Inter, i es canvia després des de la barra. A dalt, tres punts es pinten de taronja en completar cada pas. Els textos són a `OnboardingCopy.swift`; el gallec i el basc els hauria de revisar algú nadiu. De moment, la resta de l'app continua només en català. El logotip del Braille Institute no s'hi posa sense el seu permís: la llicència de la tipografia no dona drets sobre la marca.
- **Idiomes i informació.** Des de la roda dentada s'obren:
  - "Idioma", per baixar, triar o esborrar idiomes;
  - "Informació i privacitat", amb la privacitat, l'avís que la transcripció pot tenir errors i els crèdits de models i tipografies, que les llicències obliguen a mostrar.

## Revisió de disseny i usabilitat

Tot això s'ha comprovat amb captures al simulador, en iPhone 17 Pro, 17 Pro Max i 17e, en clar i en fosc:

| Punt | Estat |
|---|---|
| Res surt de la pantalla (menús, fulls, textos) | Comprovat a les tres mides |
| Botons de 44 punts o més | Sí |
| Contrast del text secundari | Pujat al 64 % de tinta: 5:1 o més sobre la targeta i els pous (abans 3,4:1) |
| Text gran del sistema (Dynamic Type) | Comprovat a la mida més gran (AX5). El text llegit es multiplica per la mida del sistema, fins al doble i mai per sobre de 96 punts (`PhoneMetrics.readingSize`). A la mida per defecte no canvia res. Una paraula més ampla que la línia s'encongeix per cabre-hi. La barra queda fixa, i mantenir premut un control el mostra en gran (visor de contingut gran). A les mides d'accessibilitat, l'onboarding, la pantalla d'idiomes i el full d'exportar apilen el que no cap de costat, i el full d'exportar es desplaça |
| VoiceOver | Tots els controls tenen nom, estat ("Activat", "seleccionat") i pista. El text transcrit es llegeix sencer. Mentre escolta, `TranscriptAnnouncer` anuncia el text nou per frases, només paraules ja fixades i en cua, sense tallar-se (també arriba a una línia braille) |
| Control per veu | Cada botó respon al que es veu escrit ("Auto", "Info", "Català", "Inter") i a sinònims ("Comença", "Atura", "Tanca", "Exporta") amb `accessibilityInputLabels` |
| Diferenciar sense color | L'opció triada, a més de ser més clara, porta una vora de tinta (`outlinedWithoutColour`). Els punts de l'onboarding canvien de forma: el pas actual és una barra i els pendents són anelles |
| Reducció de moviment | L'orbe deixa de sacsejar-se amb la veu. Els menús, el botó d'exportar, l'orbe i la llista de micròfons apareixen amb un fos, sense zoom ni desplaçament |
| Més contrast (ajustament del sistema) | Treu el degradat del text |
| Animacions | Menús, tema, orbe, idiomes i text: res salta. Captures fetes a mitja animació |
| Pantalla sempre encesa mentre escolta | Sí |
| Trucades i interrupcions | Aturen la transcripció i tanquen la frase |
| Sortir de l'app | Atura la transcripció (l'app no grava en segon pla) |

## Com es prova al simulador

```bash
cd SubtitolLive && ./scripts/build-ios-app.sh
```

L'script prepara el que cal:

- el motor per a iPhone, amb `scripts/build-ios-runtime.sh`;
- els models, amb `scripts/stage-ios-resources.sh`.

Després compila l'app i l'obre al simulador. Al simulador, "baixar" el català vol dir copiar-lo de `.work/ios-packs/ca`.

Les versions de proves que Xcode instal·la a un iPhone porten el català dins de l'app (carpeta `DevPacks`, uns 185 MB). Així "Baixa" funciona al telèfon abans que el paquet sigui a App Store Connect. Les versions per a l'App Store no el porten.

Dues limitacions del simulador, que un iPhone real no té:

- **El motor fa servir el processador, no la GPU.** El Metal del simulador no permet el que fa el motor, i s'aturava.
- **El simulador no pot fer servir el micròfon del Mac** sense un permís de sistema que no es pot donar des de la línia d'ordres. Per provar la transcripció, les versions de proves poden llegir un fitxer d'àudio com si fos el micròfon, al ritme real. Es fa amb la variable `SUBTITOL_REPLAY_AUDIO`.

Paràmetres d'arrencada per fer captures (només en versions de proves):

- `-autoInstall ca`: baixa el català sense tocar res.
- `-onboarding.done NO`: torna a mostrar la primera obertura; `-onboardingStep 0…2` hi obre un pas concret (amb `-onboarding.done NO` l'app no pot marcar-lo com a fet i s'hi queda al final).
- `-autoRecord YES`: comença a escoltar sol.
- `-openPanel profile|size|typeface|display`: obre un menú.
- A l'editor, "Aa" obre l'estil dels subtítols dins el mateix full: les frases marxen, el vídeo creix i les opcions queden a baix. Només allà s'arrossega el subtítol (amb un toc del Taptic Engine quan s'alinea al mig, de través o d'alt a baix); la mida va amb − i +.
- L'editor de subtítols s'obre sol quan el vídeo s'acaba de transcriure; `-editorSteps "play@1;edit 2@5;draft text@7;commit@9;export@12;style@14;drag 0.5,0.8>0.5,0.5@16"` hi fa passos (segons des que s'obre). `-debugSnapshots "10,20"` desa captures de la pròpia app a Documents (per al telèfon, que no té eina de captures).
- `-openSheet languages|about|export`: obre la fulla d'idiomes, la d'informació o la d'exportar (aquesta espera que hi hagi text; va amb `-autoRecord YES`).
- `-exportFormatTour YES`: el panell d'exportar passa per cada format, per gravar-ne l'animació.
- `-importFile CAMÍ`: obre un vídeo com si l'haguessin compartit amb l'app (el simulador llegeix els camins del Mac). La transcripció al simulador va per CPU i és lenta; en un iPhone va per GPU.
- `-app.interfaceLanguage ca|gl|eu|es|en`: la llengua de la interfície (la de la primera pantalla de la benvinguda). Com a paràmetre d'arrencada mana sobre la que es triï dins l'app.
- `-interfaceLanguageTour YES`: a la primera pantalla de la benvinguda, tria cada llengua de la interfície per torns, com un toc, per gravar-ne el canvi. Cal posar la llengua inicial amb `defaults write` i no amb `-app.interfaceLanguage`.
- `-phone.theme dark`: força el mode fosc.
- `-orbFreeze YES`, `-orbGrainAmount 1.4`, `-orbGrainMode 1…7`, `-orbGrainMix 0.25`: congela l'orbe i prova altres grans (1 multiply, 2 screen, 3 overlay, 4 soft light, 5 linear light, 6 color burn, 7 color dodge). La comparativa és a `.work/iphone-report/gra-orbe.png`.

Les captures per a l'App Store, en la mida que demana Apple (1320 × 2868), són a `.work/app-store-screenshots/`.

## Com es baixen els idiomes

Els idiomes són **paquets allotjats per Apple** (Apple-hosted Background Assets, iOS 26):

- Apple els guarda als seus servidors i els revisa juntament amb l'app.
- Cada app pot tenir fins a 200 GB en paquets.
- Tenen la política "on demand": no es baixen fins que la persona els demana.
- L'app necessita iOS 26 o posterior.

Per preparar-los:

```bash
cd SubtitolLive && ./scripts/stage-ios-resources.sh --asset-packs
```

Això crea `.work/ios-asset-packs/lang-ca.aar` (192 MB): el model de veu i el de puntuació ja compilat. Aquest fitxer es puja a App Store Connect amb l'app **Transporter** d'Apple.

La llista d'idiomes és a `ModelManifest.json` (`languages`). Cada idioma hi té el nom, l'estat ("stable" o "beta"), el paquet i el model. Posar `"stage": "beta"` fa que l'app mostri l'etiqueta "Beta" i l'avís que pot tenir més errors.

El castellà, l'anglès, el gallec i el basc ja hi són i es veuen com qualsevol altre idioma, a punt per baixar a la primera versió. Porten `"packStaged": false` perquè els seus fitxers encara no són a `models/`: `stage-ios-resources.sh` se'ls salta i no cal que el seu model sigui a `models`. Quan un paquet estigui fet, es treu aquesta línia. A les versions de proves, "baixar" un idioma sense paquet fa la mateixa animació i el deixa instal·lat com a mostra, sense model, per veure com queda la pantalla d'idiomes amb ell.

La pantalla d'idiomes (des de la roda dentada) mostra cada idioma en una targeta pròpia, de colors plans, amb un sol botó a la dreta: "En ús", "Tria", "Baixa" (que s'omple de taronja mentre baixa) o "Esborra" en editar. Cada idioma porta l'espai que ocupa i una petita figura geomètrica pròpia dins un marc de cantonades arrodonides, de formes taronges que se superposen (català: quatre barres; castellà: tres cercles; gallec: una flor de sis pètals; basc: una estrella de vuit puntes; anglès: cinc cercles en rombe). La figura és grisa si l'idioma no està baixat i s'omple de color mentre es baixa. Sota el títol hi ha quatre punts: privat per disseny, sense connexió, en directe i adaptat per accessibilitat. "Edita" canvia les opcions dels idiomes instal·lats per botons d'esborrar (amb confirmació, que diu quant espai s'allibera); també es pot esborrar mantenint premut un idioma. Les files no canvien de lloc mentre la pantalla és oberta.

A dalt de tot, la salutació de cada idioma s'escriu i s'esborra, una rere l'altra: "bon dia", "ola", "kaixo", "hola", "hello". Comença per l'idioma que fas servir. Les lletres són una cursiva geomètrica d'un sol traç (cercles i rectes, a l'estil del lettering de referència "liven"), dibuixada per nosaltres a `SubtitolLive/scripts/generate-greetings.py`. Cada lletra té el seu to de taronja i és una mica transparent, i on els traços es creuen el color s'enfosqueix. Per canviar una lletra o afegir un idioma, s'edita allà i es torna a executar (`--svg fitxer.html` en fa una prova). Amb "Reduir moviment", les paraules només es fonen.

## Què falta per publicar

Ho has de fer tu (necessita el teu compte o la teva decisió):

1. **Seleccionar Xcode com a eina per defecte** en aquest Mac, perquè Claude pugui fer servir el simulador integrat:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. **Provar-la en un iPhone de veritat.** Obre `SubtitolLive/iOS/SubtitolLiveiOS.xcodeproj` amb Xcode, connecta l'iPhone i prem ▶︎. El compte de desenvolupador (equip WAV6CC7W94) ja hi és configurat. Cal mirar, amb text de debò i durant una estona, la memòria, l'escalfament, la bateria i el retard.
3. **Crear l'app a App Store Connect** amb l'identificador `cat.subtitollive.ios`, el grup `group.cat.subtitollive` i la capacitat Background Assets.
4. **Pujar el paquet `lang-ca.aar`** amb Transporter i provar-lo per TestFlight (primer intern, després extern).
5. **Publicar la política de privacitat** a `asr.uriocallaghan.com/privacitat`. La pàgina ja és a `web/privacitat/`, però no s'ha publicat.
6. **Decidir l'estatus de comerciant (DSA de la UE).** Si ets "comerciant", l'App Store mostra la teva adreça i el teu telèfon.
7. **Omplir la fitxa de l'App Store:**
   - etiqueta de privacitat: "Dades no recollides";
   - qüestionari d'edat;
   - etiquetes d'accessibilitat (iPhone): VoiceOver, Control per veu, Text més gran, Mode fosc, Diferenciar sense color i Moviment reduït. Contrast suficient, subtítols i audiodescripció no es declaren. Abans cal provar VoiceOver i Control per veu en un iPhone real;
   - descripció;
   - captures;
   - URL de suport.

Ja està fet dins l'app:

- el text del permís del micròfon;
- el manifest de privacitat (`PrivacyInfo.xcprivacy`: cap seguiment, cap dada recollida, i el motiu CA92.1 per a UserDefaults);
- `ITSAppUsesNonExemptEncryption = NO`;
- la mida de la baixada mostrada abans de demanar permís (norma 4.2.3);
- models tractats com a dades, no com a codi (norma 2.5.2);
- l'avís que no és un aparell auditiu ni substitueix la subtitulació professional (norma 1.4.1);
- els crèdits i les llicències;
- la icona (l'orbe Seda).

## Altres idiomes

El pla és a la planificació del 26 de setembre. El gallec i el basc sortiran com a "Beta". Tots els models han de ser de la mida del Conformer actual.

### Prova dels models (26 de setembre)

Els quatre models candidats:

- es converteixen amb la mateixa recepta que el català;
- funcionen amb el nostre motor;
- ocupen el mateix que el Conformer, entre 123 i 131 MB;
- tenen llicències que permeten l'ús comercial.

Els detalls i les ordres per repetir la prova són a `.work/lang-spike/README.md`.

| Idioma | Model | Errors (de cada 100 paraules) | Observacions |
|---|---|---|---|
| Castellà | NVIDIA FastConformer (CC-BY-4.0) | 4,1 (FLEURS, 150 frases) | Posa punts i majúscules sol. Dins l'app en directe puja a 6,5, perquè repeteix paraules a la costura de cada finestra de 7 s ("del del") |
| Gallec | BSC "los" (Apache 2.0) | 7,7 (FLEURS, 60) | Minúscules, sense puntuació. Es passa al castellà en una de cada 200 paraules, més o menys |
| Basc | HiTZ (Apache 2.0) | 3,2 (Parlament) i 12,3 (lectures de voluntaris) | Minúscules, sense puntuació |
| Anglès | NVIDIA FastConformer (CC-BY-4.0) | 4,7 (FLEURS, 60) | Puntuació i majúscules pròpies, amb el mateix problema de repeticions a la costura |

Resultat inesperat: **el nostre model català ja entén el castellà tan bé com el model castellà de NVIDIA** (4,9 errors contra 4,1, una diferència que no és significativa). En directe dins l'app encara l'entén millor: 3,8 contra 6,5. El model castellà només aportaria la puntuació, les majúscules i una mica més de velocitat.

### Què cal fer a l'app abans d'afegir-los

- **Fixar el text sense el model de puntuació català.** Avui el text només queda fixat a la pantalla quan el model de puntuació ha decidit la puntuació de cada paraula, i aquest model és només català. Un idioma sense model propi no fixaria mai cap paraula. Cal, segons l'idioma:
  - un model de puntuació;
  - o un camí que fixi les paraules amb la puntuació que ja escriu el reconeixedor (castellà i anglès). Avui una coma del model arriba com si fos una paraula a part.
- **Treure les repeticions a la costura de les finestres** dels models FastConformer (castellà i anglès).
- **Aplicar només al català els passos que només tenen sentit en català:**
  - les xifres (`CatalanNumberNormalizer`);
  - els apòstrofs (`CatalanElisionRepair`);
  - la llista de paraules comunes (`CatalanOrdinaryWords`).
