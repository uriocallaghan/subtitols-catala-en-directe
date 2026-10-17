# Auditoria: paraules inventades en un esdeveniment públic (2026-10-14)

En una prova en un esdeveniment públic, els usuaris es van queixar que l'app
s'inventava paraules, fins al punt d'haver-la de deixar d'utilitzar. Aquest document
explica per on entraven, què s'ha canviat i com s'ha mesurat.

## Què vol dir "s'inventa paraules"

El reconeixedor (el Conformer català-castellà) no sap callar. Quan sent qualsevol
cosa que no és una veu clara (aplaudiments, el xivarri del públic, el soroll d'una
sala, una veu llunyana per megafonia), escriu igualment: paraules curtes en
castellà, trossos de frase plausibles, o una paraula diferent a cada finestra. I
quan la veu arriba dolenta (lluny de l'altaveu, amb reverberació i públic), al lloc
de cada paraula real n'escriu una d'inventada: a la prova de sala dura d'aquest
document, una de cada quatre paraules que sortien a pantalla era un invent
("forcel·lar", "la tenalina", "gardinet", "avestres", "miedo").

Fins ara l'app tenia dues defenses, i cap de les dues servia en una sala amb públic:

1. El **filtre d'energia** (`SilentWordFilter`): descarta una paraula si al seu
   voltant no hi ha cap tros de 10 ms que superi en 10 dB el soroll de fons de la
   finestra. Funciona en una habitació tranquil·la (silenci digital, soroll constant,
   soroll de sala del portàtil). En una sala amb públic, el "soroll de fons" és el
   públic mateix: els aplaudiments i el xivarri el superen de sobres (tot passa), i a
   la vegada la reverberació omple els forats entre paraules i la veu real sovint no
   arriba als 10 dB (les paraules bones es perden).
2. L'**editor** (`ReadableTranscriptStabilizer`): només mostra una paraula quan l'ha
   sentit igual 3 finestres seguides (perfil Fiable), i només la fixa amb 3 sentides
   i 0,65 s de marge. Això atura les al·lucinacions que canvien a cada finestra...
   excepte per una regla afegida el setembre: una paraula que **2,5 s després
   d'acabar encara no s'ha decidit es fixava "tal com s'ha sentit l'última vegada"**.
   Es va afegir per no perdre paraules difícils ("reaccionària", "redsonària",
   "reaccionaria") que bloquejaven tot el que venia darrere. Però és exactament el
   camí per on arriba a la pantalla una paraula que cap finestra ha sentit igual:
   als 87 fragments del Parlament, les paraules fixades així eren **142 vegades
   errònies i 63 vegades correctes**; en una sala amb públic eren la major part
   del que es llegia.

A més, el motor no dona cap mesura de confiança per paraula (el descodificador RNNT
del runtime retorna sempre 1,0), així que l'editor no pot distingir una paraula
dubtosa d'una de clara per cap altra via que la coincidència entre finestres.

## El banc de proves nou: `.work/venue-test`

No teníem cap gravació de l'esdeveniment, i mai no fem servir vídeos personals, així
que el banc és sintètic sobre parla real (`make.py`, determinista):

- **Parla**: 30 fragments d'EMpodcat (conversa, 18–30 s, amb referència humana), que
  cap dels dos models havia vist mai.
- **`net`**: els fragments tal qual, a −22 dBFS.
- **`sala_lleu`**: el telèfon a uns metres de l'altaveu en una sala petita: reverberació
  de 0,7 s amb el so directe per sobre de la sala, xivarri 18 dB per sota de la veu.
- **`sala`**: el fons d'una sala gran: reverberació d'1,4 s amb el so directe 10 dB per
  sota de la sala, filtre a 5 kHz, i un **xivarri** (10 frases de FLEURS alhora,
  reverberades, no se n'entén cap) 12 dB per sota de la veu.
- **`sala_sorollosa`**: el mateix amb el xivarri a 5 dB.
- **`esdeveniment`**: 5 s d'aplaudiments, el fragment de `sala`, i 8 s de públic
  (xivarri més aplaudiments): el presentador acaba, el públic aplaudeix, i l'app
  continua escoltant.
- **`sense_veu`**: 30 clips de 10–12 s sense cap veu: aplaudiments, xivarri a diversos
  nivells, xivarri amb aplaudiments, i sala buida. **Qualsevol paraula escrita aquí
  és inventada.**

`run.sh TAG [perfil] [opcions]` el reprodueix pel camí del directe (finestra de 7 s,
rellotge fix, puntuació i detector de veus com a l'app) i `score.py` el puntua amb
insercions, substitucions i omissions per separat. `run-parla.sh` fa el mateix amb els
87 fragments del Parlament (`score_parla.py`), que és el control de paraules perdudes.
El banc de proves (`SubtitolLatencyHarness`) ara desa les respostes del reconeixedor i
del detector de veus per conjunt (`--recognition-cache DIR`), de manera que una variant
de l'editor es puntua en un minut, sense GPU, i `--policy` prova llindars sense tocar
l'app.

## Resultats (perfil Fiable, abans → ara)

| Conjunt | WER abans → ara | Paraules errònies (subst.) | Insercions | Omissions |
|---|---|---|---|---|
| net | 16,1% → 16,3% | 6,2% → 5,8% | 4,9% → 4,3% | 5,1% → 6,2% |
| sala_lleu | 17,6% → 17,3% | 7,1% → 5,9% | 3,9% → 3,9% | 6,7% → 7,4% |
| sala | 65,5% → 62,9% | **24,0% → 9,8%** | 0,6% → 0,5% | 40,9% → 52,6% |
| sala_sorollosa | 85,3% → 81,3% | **19,1% → 6,6%** | 0,2% → 0,2% | 66,0% → 74,5% |
| esdeveniment | 65,0% → 60,2% | **25,6% → 9,6%** | 1,4% → 0,8% | 38,0% → 49,8% |
| sense_veu | 28 paraules inventades en 7 clips → **11 en 2 clips** (totes al xivarri de 10 veus; aplaudiments i sala buida: cap) |
| Parlament (87) | 9,66% → **7,52%** | 288 → 127 | 36 → 18 | 68 → 151 (tirades de ≥3 perdudes 5 → 14) |

(Les insercions de `net` són gairebé totes de parla espontània davant d'una referència
neta: "sí sí", "hi ha hi ha", "val", "pues". No són invents.)

Equilibrat: Parlament 7,39%, net 15,0%, sala_lleu 15,8%, sala 11,3% de substitucions,
sense_veu 15 paraules.

La lliçó: **en una sala dolenta, el model no reconeix; inventa.** L'editor no pot
tornar bones les paraules dolentes, però sí que pot callar: ara, allà on abans sortia
una paraula errònia de cada quatre, en surt una de cada deu, i a canvi hi ha més forats.
En una sala raonable (`sala_lleu`) no es perd res i es guanya una mica.

## Què s'ha canviat

### 1. Una paraula indecisa no es fixa mai (Fiable i Equilibrat)

L'editor compta ara, per a cada lloc, **totes les formes que hi ha sentit** (no només
les seguides, i agrupant les que només difereixen en accents). Fiable i Equilibrat
**no fixen mai** una paraula que no ha estat sentida igual tres finestres seguides:
quan porta 2,5 s indecisa i se l'ha sentida almenys 4 vegades, es descarta i les
paraules de darrere continuen (abans es fixava "tal com s'ha sentit l'última vegada").
Un lloc on s'ha descartat una paraula recorda les sentides: si el reconeixedor hi
torna a escriure una altra cosa, es jutja de seguida, sense fer esperar la resta.
Esperar 4 sentides abans de descartar (i no 2) és el que va donar millor resultat al
Parlament (7,52% contra 8,49%): sovint la tercera i la quarta finestra acaben
coincidint.

Immediat fixa la forma més sentida quan dues finestres l'han sentida (abans, una).

### 2. El detector de veus mana sobre el filtre d'energia

El model de segmentació de veus (pyannote segmentation-3.0) ja corria a l'app per
detectar canvis de veu. Classifica cada 17 ms d'àudio com a silenci, una veu o dues
veus alhora, i està entrenat per distingir una veu de música i soroll: als
aplaudiments i al públic de `esdeveniment` no hi sent ningú; a la veu per megafonia,
sí. Ara `SpeakerTurnTracker` guarda també **on ha sentit una veu** (`SpeechPresenceMap`),
i allà on el detector ja ha escoltat, la seva decisió mana: una paraula on hi ha veu
es queda encara que no passi el filtre d'energia (és el que es perdia a la sala), i una
paraula on no hi ha ningú es descarta encara que el passi (aplaudiments, xivarri).
Hi ha 100 ms de marge per davant i per darrere, perquè el Conformer marca la primera
paraula d'una frase fins a 100 ms abans que soni. On el detector encara no ha
escoltat (els últims 0,5 s, abans del primer anàlisi als 2 s), decideix el filtre
d'energia, com abans; la finestra següent torna a sentir la paraula i aleshores es
jutja.

El que queda a `sense_veu` (11 paraules en 5 minuts) és el xivarri fort de 10 veus,
que el detector sent com una veu. Sense el model de veus (si mai faltés), tot passa
pel filtre d'energia com abans.

### 3. Els perfils

| Perfil | Hop | Mostrar | Fixar | Paraula indecisa |
|---|---:|---:|---:|---|
| Fiable (defecte) | 300 ms | 3 sentides seguides | 3 sentides + 0,65 s | mai; es descarta a la 4a sentida |
| Equilibrat | 300 ms (abans 240) | 2 | 3 + 0,65 s (abans 2 + 0,35 s) | mai; es descarta a la 4a sentida |
| Immediat | 180 ms | 1 | 2 + 0,35 s | la forma més sentida, amb 2 sentides |

Equilibrat ara fixa amb la mateixa calma que Fiable i només es diferencia en com
d'aviat mostra la cua. Les proves amb més evidència (4 o 5 sentides, 1–1,3 s de marge)
no van reduir les paraules errònies i sí les bones: el que importa és no fixar mai
una paraula indecisa.

## Segona tanda (mateix dia): confiança del motor i vocabulari de l'acte

**Confiança.** El pedaç 0004 del runtime fa que el descodificador RNNT greedy retorni,
per a cada paraula, la probabilitat del seu tros menys segur (softmax i màxim per fila
al mateix graf de la GPU, un número per frame). Calibrada sobre les paraules que el
lector acaba veient: les bones tenen una mediana de 0,80 (parla neta i Parlament) i
0,72 (sala); les dolentes, 0,64–0,69 i 0,59. No separa del tot, però se suma a la
coincidència entre finestres. Fiable i Equilibrat no ensenyen ni fixen una paraula
que no arribi a 0,5 de mitjana (Immediat, 0,4); la paraula espera sense veure's i,
si es fa vella sense arribar-hi, marxa.

| Llindar | Parlament (WER · equivocades · omeses) | Conversa neta (equivocades · omeses) | Sala (equivocades · omeses) | Públic sol |
|---|---|---|---|---|
| cap | 7,52% · 127 · 151 | 5,8% · 6,2% | 9,8% · 52,6% | 11 |
| **0,5** | **7,31% · 115 · 156** | 5,6% · 6,5% | **8,0% · 55,6%** | **7** |
| 0,55 | 7,63% · 108 · 176 | 5,3% · 7,6% | 6,8% · 57,5% | 7 |
| 0,6 | 8,78% · 89 · 241 | 4,9% · 9,7% | 5,0% · 61,9% | 5 |

Amb 0,5 es guanya a tot arreu sense perdre paraules bones (a la sala, una de cada cinc
paraules equivocades menys); de 0,6 en amunt, el preu en paraules bones ja no compensa.
Equilibrat queda a 7,33% al Parlament i 15,0% a la conversa neta.

**Vocabulari de l'acte.** Noms, llocs i sigles que el motor afavoreix (context biasing
del runtime sobre els tokens del SentencePiece incrustat). Comprovat amb un nom que el
model escriu malament: "sorolls de **khorodkovkov**" → amb "Korotkoff" al vocabulari,
"sorolls de **korotkoff**" (a qualsevol força, 2 a 5). El motor només escriu en
minúscula, així que (1) les frases hi van en minúscula (en majúscula les trossejava en
peces que no escriu mai: "khorod kovolls") i (2) el text que es llegeix s'escriu com
l'usuari va donar el terme (`VocabularyCasing`: "Korotkoff,", "Artur Mas"; un "mas" sol
no es toca). Als 87 fragments del Parlament els noms propis ja sortien bé en mode
fitxer sense ajuda (Maragall, Torra, Sud-amèrica), així que el guany és en noms que el
model no coneix. Mac: pill "Vocabulari" dins del panell de configuració, amb el compte;
iPhone: "Vocabulari" al panell de l'engranatge. Fins a 40 termes, desats, aplicats de
seguida també mentre escolta. El banc: `--boost "nom,terme"` (`--boost-strength N`).

## Què no s'ha fet (i caldria)

- **Una gravació real d'un esdeveniment** (amb el consentiment de qui hi parla) per
  calibrar el banc sintètic: la `sala` d'aquí és dura a propòsit (so directe 10 dB
  per sota de la sala), i la `sala_lleu` quasi no costa res al model. L'esdeveniment de
  la queixa devia estar entre totes dues.
- **La importació de vídeo** (`FileTranscriber`) continua amb el filtre d'energia sol.

## Com reproduir-ho

```sh
cd .work/venue-test
python3 -I make.py 30 && python3 -I make.py 30 --mild     # genera el banc (dos minuts)
./run.sh abans reliable --no-speech-gate --policy 0.3,3,3,0.65,3,0.65,1   # comportament anterior (omple la memòria cau: una hora)
./run.sh fiable reliable                                   # ara (un minut des de la memòria cau)
./run.sh equilibrat balanced
python3 -I score.py runs/abans runs/fiable runs/equilibrat --verbose
./run-parla.sh fiable reliable                             # paraules perdudes (87 fragments del Parlament)
```
