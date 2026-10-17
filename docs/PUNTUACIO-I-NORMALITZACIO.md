# Puntuació, majúscules i normalització

Investigació del 24 de setembre de 2026: com convertir el text del reconeixedor en text ben escrit, al Mac i a l'iPhone, ocupant el mínim.
Tot el que no té font és una mesura nostra, feta amb les eines de `.work/tools/`.

---

## El problema

El model de veu escriu així:

> el vint-i-tres d'abril per sant jordi vam anar a la rambla

I el lector necessita això:

> El 23 d'abril, per Sant Jordi, vam anar a la Rambla.

Hi ha quatre feines diferents, i cadascuna té una solució diferent:

| Feina | Exemple | Solució |
|---|---|---|
| Xifres | vint-i-tres → 23 | Regles (0 MB) |
| Majúscula d'inici | el → El | Regla: després de punt, majúscula |
| Noms propis | sant jordi → Sant Jordi | Model + llista de noms + vocabulari personal |
| Puntuació | … abril, per … Jordi. | Model + pauses de la veu |

---

## 1. Xifres: regles, no cal cap model

Els nombres són una gramàtica tancada.
Hem fet un prototip (`itn_ca.py`, unes 120 línies) que segueix les convencions de subtitulació de l'**ésAdir** (3Cat):
de l'u al dinou amb lletres, a partir del 20 amb xifres, i els percentatges amb el signe ([ésAdir, subtitulació](https://esadir.cat/entrades/fitxa/id/5128); [norma general](https://esadir.cat/entrades/fitxa/id/5040)).

| Entrada | Sortida |
|---|---|
| el vint-i-tres d'abril | el 23 d'abril |
| l'any mil nou-cents noranta-dos | l'any 1992 |
| només un quinze per cent | només un 15 % |
| fa uns deu mil anys | fa uns 10.000 anys |
| el cinc de maig de dos mil vint-i-sis | el 5 de maig de 2026 |
| mil gràcies · un home i una dona | sense canvis |

- **Pendent:** la regla de coherència de sèrie ("de 10 a 60 minuts"), els ordinals, les hores i les monedes.
- **Codi lliure del qual podem aprofitar lògica i casos de prova:** [ovos-number-parser](https://github.com/OpenVoiceOS/ovos-number-parser) (Apache-2.0, té català) i el `catalan.py` de [text2num legacy](https://github.com/allo-media/text2num/tree/legacy-2.x) (MIT).
- **El que no serveix:** [NeMo-text-processing](https://github.com/NVIDIA/NeMo-text-processing) no té català.
- **Ortografia:** el model de veu de vegades escriu accents anteriors a la reforma de l'IEC, com "dóna". Una llista curta ho pot passar a la norma actual ("dona").

---

## 2. Puntuació i majúscules: el que existeix

**Prova:** 188 paràgrafs de 5 frases de FLEURS (Google, CC-BY-4.0), enganxats sense puntuació com si fossin parla contínua.
Hi ha 1.154 finals de frase, 1.123 comes i 1.190 majúscules a mitja frase.
Els valors són F1 (0–100), un indicador que combina encerts i errors.

| Candidat | Llicència | Mida | Final de frase | Coma | Majúscula inicial | Noms propis |
|---|---|---|---|---|---|---|
| Sense model (majúscula + punt final) | — | 0 | 36 | 1 | 29 | 0 |
| [pcs_romance](https://huggingface.co/1-800-BAD-CODE/punctuation_fullstop_truecase_romance) | Apache-2.0 | 144 MB | 65 | 51 | 92 | 56 |
| [VOCALINLP](https://huggingface.co/VOCALINLP/catalan_capitalization_punctuation_restoration_sanivert) | **cap** | 500 MB | 66 | 50 | 87 | 72 |
| [UMUTeam](https://huggingface.co/UMUTeam/catalan_capitalization_punctuation_restoration) | **cap** | 500 MB | 56 | 54 | 90 | 67 |
| **Pilot propi, 22 min d'entrenament** | **CC0 + Apache-2.0** | 326 MB (~80 MB comprimit) | **75** | 42 | **94** | 61 |

- **Cap model català publicat es pot posar a l'app.** Els de VOCALINLP, UMUTeam i [Softcatalà](https://huggingface.co/softcatala/fullstop-catalan-punctuation-prediction) no declaren llicència, i sense llicència tots els drets queden reservats. El paper d'UMUTeam ([PLN 70, 2023](https://rua.ua.es/handle/10045/133234)) tampoc no en dona cap.
- **L'únic model lliure que inclou el català (pcs_romance) és fluix en català.** Posa punts de més i trenca els guionets ("aixecar-<unk>se"). El seu autor avisa que va entrenar el català amb només 500.000 línies de subtítols.
- **El model d'IA d'Apple que ve amb el sistema (Foundation Models) no admet el català.** Ho hem provat a macOS 26.5: té 23 variants d'idioma, cap de catalana, i retorna `unsupportedLanguageOrLocale` ([documentació d'Apple](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)).
- **El pilot propi guanya en finals de frase i en majúscula inicial.** El vam entrenar amb paràgrafs continus, com la parla, i no amb frases soltes. Perd en comes i noms propis perquè només va veure 120.000 frases escrites.

### Què existeix, comprovat el 25 de setembre de 2026

Hem repassat Hugging Face i la literatura per saber si el nostre model seria realment nou.

- **Models de puntuació fets per al català, tots sense llicència:**
  - [Softcatalà](https://huggingface.co/softcatala/fullstop-catalan-punctuation-prediction) (2022): només signes, sense majúscules. El juliol de 2026 en va aparèixer una còpia idèntica, també sense llicència.
  - [UMUTeam](https://huggingface.co/UMUTeam/catalan_capitalization_punctuation_restoration) (Universitat de Múrcia, 2023), amb l'article [*Evaluation of transformer-based models for punctuation and capitalization restoration in Catalan and Galician*](https://rua.ua.es/handle/10045/133234) a la revista *Procesamiento del Lenguaje Natural*.
  - [VOCALINLP](https://huggingface.co/VOCALINLP/catalan_capitalization_punctuation_restoration_sanivert) (2024).
  - Els dos últims parteixen del RoBERTa català de PlanTL: 12 capes i 125 milions de paràmetres. El nostre en té 6 i 82 milions.
- **Models lliures multilingües:** n'hem revisat nou. Només [pcs_romance](https://huggingface.co/1-800-BAD-CODE/punctuation_fullstop_truecase_romance) inclou el català, i és el que puntua fluix (taula de dalt).
- **Altres llengües de l'Estat sí que en tenen de lliures:** el castellà ([HiTZ/cap-punct-es](https://huggingface.co/HiTZ/cap-punct-es)) i el basc ([HiTZ/cap-punct-eu](https://huggingface.co/HiTZ/cap-punct-eu) i [itzune/txukun-cap-punct-eu](https://huggingface.co/itzune/txukun-cap-punct-eu)), tots amb Apache-2.0.
- **Reconeixedors de veu que ja puntuen, en una sola etapa.** El BSC ha publicat amb Apache-2.0 [whisper-large-v3-ca-punctuated-3370h](https://huggingface.co/BSC-LT/whisper-large-v3-ca-punctuated-3370h) (1.550 milions de paràmetres) i [stt_los_conformer_transducer_large_punctuated](https://huggingface.co/BSC-LT/stt_los_conformer_transducer_large_punctuated) (120 milions; català, castellà, gallec i basc; 2026).
  - No són models de puntuació: són motors de veu sencers que escolten i puntuen alhora.
  - El Whisper és d'una altra família i més gran que el Parakeet (el motor de l'app fins al 26 de setembre), i el nostre motor no el pot fer córrer. Els Conformer clàssics, en canvi, sí: des del 25 de setembre el motor en coneix la capa d'entrada (vegeu [EL-MODEL.md](EL-MODEL.md)). Però aquest Conformer que puntua té un 9,2% d'error a FLEURS, més del doble que el Conformer d'Aina que fem servir.
  - Són la comparació que demanaria qualsevol revisor: dues etapes (Parakeet més el nostre model) contra una.
- **Dades noves:** [Ugiat/parlament_parla_v3_punctuated](https://huggingface.co/datasets/Ugiat/parlament_parla_v3_punctuated) (20 de setembre de 2026, CC-BY-4.0). Són 900 hores de parla del Parlament, amb l'àudio. La puntuació l'ha posada un model d'IA (Claude) i no l'ha revisada cap persona.
  - Serviria per entrenar amb pauses i parla espontània, no per examinar.
  - Si les fem servir, el model ja no s'hauria entrenat només amb text de domini públic. Cal decidir-ho abans.
  - Mostra que altres equips treballen en això ara mateix.

**Conclusió.** Que sapiguem, el nostre seria el primer model lliure fet per al català que posa punts, comes i majúscules.
No és el primer model de puntuació en català: n'hi ha tres sense llicència i un article del 2023. Tampoc no és l'única manera de tenir text català puntuat, perquè els reconeixedors del BSC ja ho fan.

---

## 2b. El nostre model: v1 i v2 (25 de setembre de 2026)

**Com l'hem fet:**
- **v1:** la base de Projecte Aina (Apache-2.0) entrenada amb 500.000 frases de Common Voice (CC0), en paràgrafs continus. Va trigar 87 minuts a la GPU d'un MacBook Air M3.
- **v2:** el v1 reentrenat 17 minuts més amb 311.000 paraules de sessions del Parlament de Catalunya i de les Corts Valencianes (CC0, de [CATalog](https://huggingface.co/datasets/projecte-aina/CATalog)). Abans en vam treure les intervencions en castellà. És parla real: professional i dialectal alhora.
- **Comprovació que no ha vist l'examen:** cap de les 940 frases de FLEURS no és a les dades d'entrenament, ni tan sols un fragment de 8 paraules seguides. Els podcasts de la prova de parla espontània tampoc hi són.

**Resultats** (F1, 0–100). Els podcasts són 150 fragments de converses reals del [corpus de Softcatalà](https://github.com/Softcatala/softcatala-podcast-corpus), amb 961 finals de frase, 1.576 comes i 132 interrogants.

| Model | FLEURS: final de frase | FLEURS: coma | FLEURS: noms propis | Podcasts: final de frase | Podcasts: coma | Podcasts: interrogant |
|---|---|---|---|---|---|---|
| Models catalans existents, sense llicència (el millor de cada columna) | 66 | 54 | 72 | — | — | — |
| Pilot (22 min) | 75 | 42 | 61 | 41 | 44 | 0 |
| v1 | 82 | 62 | 72 | 45 | 54 | 18 |
| **v2** | **83** | **62** | **71** | **51** | **61** | **43** |

- **A la prova pública, el v2 supera tots els models catalans existents** en finals de frase i comes, i els iguala en noms propis.
- **La parla del Parlament és el que més ha ajudat en converses reals:** les comes passen de 54 a 61 i els interrogants, de 18 a 43.
- **Les converses continuen sent el punt feble.** Hi falten més dades parlades: de moment tenim el 2% de les transcripcions del Parlament que existeixen.

**Format i mida.** L'hem convertit a Core ML, el format d'Apple, i n'hem provat quatre compressions:

| Versió | Mida | Qualitat |
|---|---|---|
| fp16 | 156 MB | igual que l'original |
| 8 bits | 78 MB | igual |
| **6 bits** | **59 MB** | **igual** |
| 4 bits | 39 MB | perd fins a 9 punts en comes i 21 en interrogants |

Puntuar un fragment de 64 peces de paraula li costa 3,6 ms a la CPU d'un M3.
Els models catalans existents es publiquen en 500 MB, però sense comprimir. Comprimits igual, en farien uns 90. El nostre és un terç més petit perquè té la meitat de capes.

### v3: aprendre a decidir amb poc context (25 de setembre de 2026, a la tarda)

**El problema que hem trobat.** A l'app, cada paraula es decideix veient-ne com a molt 32 abans i només 3 després. Fins ara només l'havíem avaluat veient el paràgraf sencer.
Mesurat com funciona de veritat a l'app, el v2 perdia molt:

| v2, F1 final de frase | Paràgraf sencer | Com a l'app (3 paraules després) |
|---|---|---|
| FLEURS | 83 | 69 |
| Podcasts | 51 | 38 |

El model s'havia entrenat sempre amb paràgrafs sencers: mai no havia hagut de decidir a prop de la vora del que veu.

**Com l'hem entrenat.**
- **Dades:** hem llegit directament els fitxers de CATalog (el servei de cerca de Hugging Face no responia) i n'hem tret totes les transcripcions del Parlament de Catalunya i de les Corts Valencianes. Són 1.174 documents, CC0.
- **Neteja:** en queden 8,3 milions de paraules en català, 27 vegades més que al v2. Hem arreglat els guionets de final de línia dels PDF ("in-forme" passa a "informe") i hem tret els 36 paràgrafs que compartien 8 paraules seguides amb alguna prova.
- **Mètode:** hem continuat des del v2 durant 105 minuts a la GPU del Mac, amb 56.000 paràgrafs parlats i 60.000 d'escrits. El 60% dels exemples són retalls a l'atzar: comencen i acaben a mitja frase, com el que veu el model a l'app.

**Resultats** (F1, 0–100):

| | v2 com a l'app | **v3 com a l'app** | v2 paràgraf sencer | **v3 paràgraf sencer** |
|---|---|---|---|---|
| FLEURS: final de frase | 69 | **78** | 83 | **83** |
| FLEURS: coma | 59 | **62** | 62 | **65** |
| Podcasts: final de frase | 38 | **54** | 51 | **56** |
| Podcasts: coma | 62 | **64** | 61 | **65** |
| Podcasts: interrogant | 28 | **38** | 43 | **52** |
| Podcasts: majúscula d'inici de frase | 56 | **71** | 69 | **71** |

- **El v3 és millor o igual en tot**, i sobretot en el que compta: com funciona dins de l'app.
- **Veure 4 paraules després en lloc de 3** ja només guanya 1 o 2 punts amb el v3 (abans, 4 a 7). Mantenim 3 paraules, que és més ràpid.
- **Mida:** el mateix, 59 MB en 6 bits. La compressió no perd res (a menys d'un punt de l'original en totes les proves).
- **Fidelitat Swift–Python:** els rètols del v3 són idèntics en 37.254 paraules de 37.254.

---

## 3. La veu dona pistes que el text no té

Amb la lectura del fundador (213 paraules i 16 frases), mesurant el silenci entre paraules:

| On | Pausa mediana |
|---|---|
| Final de frase | 320 ms |
| Coma | 160 ms |
| Entre paraules sense signe | 80 ms |

Amb el llindar de 250 ms es detecten 12 dels 15 finals de frase, amb només 2 falsos positius entre 192 llocs.
Combinat amb un model:

| La teva lectura | Final de frase | Majúscula inicial | Noms propis |
|---|---|---|---|
| UMUTeam, només text | 40 | 40 | 93 |
| UMUTeam + pauses | **85** | **93** | 90 |
| Pilot, només text | 59 | 86 | 84 |
| Pilot + pauses | 70 | 97 | 82 |

Compte: és parla llegida i d'una sola persona. En parla espontània hi ha pauses per dubtar, i la pausa s'ha de combinar amb el model; no n'hi ha prou de sumar-les.

---

## 4. En directe: quant context cal

Hem mesurat la qualitat si cada paraula es decideix veient només *k* paraules posteriors (UMUTeam, 25 paràgrafs):

| Context posterior | Final de frase | Coma |
|---|---|---|
| 1 paraula | 46 | 39 |
| 3 paraules | 51 | 58 |
| 5 paraules | 54 | 56 |
| Tot el text | 56 | 45 |

Amb 3–5 paraules n'hi ha prou. L'editor ja té fins a 3 paraules a la cua viva.
Per tant, es pot puntuar en el moment que una paraula queda fixa, amb un retard d'aproximadament un segon, sense tocar mai el text que ja s'ha llegit.

---

## 5. Noms propis

- **El model** ja n'encerta molts: amb la lectura del fundador, els models catalans arriben a 92–93 i el pilot a 84.
- **Llistes obertes:** Wikidata (CC0) i els nomenclàtors de municipis serveixen per als noms de diverses paraules i les sigles (BSC, UE).
- **Vocabulari personal:** el motor de veu ja accepta una llista de paraules a afavorir.
  - L'hem provat: amb "Machu Picchu" a la llista, "machu pitchu" passa a "machu picchu".
  - Però a força 10 també ha convertit "Hong Kong" en "hong kowloon". Cal una força més baixa i llistes curtes.
  - Ben ajustat, resol els dos problemes alhora: el nom es reconeix i s'escriu bé.

---

## 6. Proposta

1. **Primera versió, sense model (0 MB):**
   - Xifres per regles (ésAdir).
   - Majúscula després de punt.
   - Punt quan hi ha una pausa llarga.
   - Llista de noms propis.
   - Cal validar-la amb parla espontània abans de publicar-la.
2. **Model propi de puntuació i majúscules**, entrenat només amb text de llicència clara:
   - **Base:** [projecte-aina/distilroberta-base-ca-v2](https://huggingface.co/projecte-aina/distilroberta-base-ca-v2) (Apache-2.0, 82 milions de paràmetres, només català).
   - **Dades:**
     - [Frases de Common Voice](https://github.com/common-voice/common-voice/tree/main/server/data/ca) (CC0). N'hem baixat 811.000 i el pilot en va fer servir 120.000.
     - Transcripcions del Parlament i de les Corts de [CATalog](https://huggingface.co/datasets/projecte-aina/CATalog) (fonts CC0, parla real).
     - Per avaluar amb parla espontània: el [corpus de podcasts de Softcatalà](https://github.com/Softcatala/softcatala-podcast-corpus) (CC BY-SA).
   - **Format:** Core ML. El Mac i l'iPhone ja porten el motor, i funciona al Neural Engine.
   - **Mida:** de ~80 MB en la primera versió a ~20–40 MB si en reduïm el vocabulari i les capes o en fem una versió destil·lada (estimació).
   - **Seria, que sapiguem, el primer model lliure fet per al català que posa punts, comes i majúscules** (comprovat el 25 de setembre; vegeu «Què existeix»). Es podria publicar.
3. **Vocabulari personal** amb força ajustada, per als noms de les persones que parlen.

---

## 7. Cap a un article científic

**Quin tipus d'article.** La tècnica no és nova: és l'estàndard des del 2020. Per tant, seria un article de recurs, és a dir, publiquem una eina lliure i la comparem amb honestedat amb totes les existents. És el mateix tipus d'article que va publicar la Universitat de Múrcia el 2023.

**Què hi aportaríem:**
- Llicència lliure.
- Entrenament només amb text de domini públic.
- Adaptació a la parla.
- Una comparació de tots els models catalans a la mateixa prova.
- Una versió de 59 MB per al mòbil.

**Què falta abans de poder-lo enviar:**
1. Repetir l'entrenament tres vegades, per demostrar que el resultat no és sort. Són unes sis hores del Mac, sense ningú al davant.
2. Passar també els models existents per la prova de podcasts.
3. Comparar-lo amb els reconeixedors del BSC que ja puntuen.
4. Analitzar els errors: on falla i per què.
5. Publicar el model, el codi i la fitxa del model.
6. Escriure'l en anglès.

**On i quan** (dates comprovades el 25 de setembre de 2026):

| Lloc | Què és | Termini |
|---|---|---|
| [arXiv](https://arxiv.org) | Dipòsit d'articles sense revisió. Fixa la data i fa l'article citable | Quan vulguem. La primera vegada, normalment cal l'aval d'algú que ja hi publica |
| [SEPLN 2027](https://www.sepln.org/congresos) | Congrés de la Societat Espanyola per al Processament del Llenguatge Natural, on va publicar Múrcia | Encara no s'ha anunciat. El 2025 va ser el 23 de març |
| [Interspeech 2027](https://interspeech2027.org/) (São Paulo) | El congrés de referència en tecnologia de la veu. Més exigent | 9 de febrer de 2027 |
| [IberSPEECH 2026](https://iberspeech.tech/2026/important-dates/) (Madrid) | Congrés ibèric de tecnologies de la parla | Tancat (juny, i agost per a demos). Es fa cada dos anys |

**Autoria.** L'autor és el fundador. Una IA no pot signar un article, i la majoria de congressos demanen declarar si se n'ha fet servir.

## 8. Dins de l'app (25 de setembre de 2026)

La puntuació, les majúscules i les xifres ja són a l'app, sempre activades.
- **Com funciona en directe.** Una paraula es "segella" quan ja és fixa i el model n'ha sentit tres més al darrere. A partir d'aquell moment, el seu signe i la seva majúscula no canvien mai. Els signes arriben, per tant, mig segon o un segon després de la paraula.
- **Xifres.** Segueixen les regles de l'ésAdir i només es converteixen quan tot el número ja està segellat. Per exemple, "mil nou-cents noranta-dos" passa a "1992".
- **Una regla de seguretat.** Si el model posa majúscula a una paraula corrent (la, però, crec…) després d'una coma, aquesta paraula passa a minúscula. Els punts els decideixen només els signes. Provar el contrari (convertir la coma en punt) creava punts falsos, com "va dir. No passa res".
- **Fidelitat de la versió en Swift respecte a Python:** el tokenitzador és idèntic en 24.921 paraules, els rètols en 37.254 paraules i les xifres en 4.354 frases.
- **Cost:** 4 ms per actualització a la CPU d'un M3.
- **Pauses de la veu (des del 25 de setembre, a la tarda).** Ara la pausa es mesura al micròfon i se suma a l'opinió del model (vegeu [LECTURA.md](LECTURA.md)).
  - "…seran el doble. Quan vam arribar" ja surt bé.
  - Quan acabes una frase i fas una pausa de mig segon, la frase següent comença en una línia nova.
  - Quan deixes de parlar, en mig segon les últimes paraules ja reben el punt, sense esperar paraules noves.
- **Xifres dites de maneres poc normatives.** Alguns reconeixedors escriuen "trenta dos" sense guionet, o "l'any dinou noranta dos". Ara totes dues formes passen a xifres (32, 1992). La versió de Swift i la de Python continuen donant el mateix resultat en les 4.354 frases de prova.
- **El que encara falla:** "va dir: «No passa res»" surt com "va dir. No passa res". El model dubta entre coma i punt, i la pausa abans de la cita fa guanyar el punt.

## Com reproduir-ho

Les eines són a `.work/tools/` (fora del git): `itn_ca.py`, `pnc_eval.py`, `pnc_models.py`, `pnc_compare.py`, `pnc_lookahead.py` i `pnc_train.py`.
El pilot es va entrenar amb `pnc_train.py` (120.000 frases, 1 passada, 22 minuts a la GPU d'un M3).
