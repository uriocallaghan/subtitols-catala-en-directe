# Fiabilitat i diagnòstic

Subtítol Live no desa àudio per defecte. Per capturar voluntàriament una sessió de
diagnòstic, cal iniciar l’app amb una carpeta explícita:

```sh
SUBTITOL_DIAGNOSTICS_DIR="$PWD/diagnostics" "/Applications/Subtítol Live.app/Contents/MacOS/SubtitolLive"
```

Cada sessió crea una carpeta nova amb:

- `audio.f32le`: PCM mono Float32 little-endian de la sessió;
- `observations.jsonl`: hipòtesis, timestamps, origen live/final, qualitat del timing,
  latència, RMS, pic, clipping, discontinuïtats i paraules detectades amb energia baixa;
- `session.json`: perfil congelat, format i declaració d’opt-in.

La freqüència de mostreig consta a cada observació. La captura s’ha d’eliminar després
de l’anàlisi si conté conversa sensible.

## Perfils

| Perfil | Hop | Mostrar | Substituir | Edat per consolidar | Paraula indecisa (2,5 s) |
|---|---:|---:|---:|---:|---|
| Fiable (defecte) | 300 ms | 3 observacions | 3 observacions | 3 observacions + 650 ms | mai es consolida; es descarta a la 4a sentida |
| Equilibrat | 300 ms | 2 observacions | 2 observacions | 3 observacions + 650 ms | mai es consolida; es descarta a la 4a sentida |
| Immediat | 180 ms | 1 observació | 1 observació | 2 observacions + 350 ms | la forma més sentida, amb 2 sentides |

La selecció es desa entre obertures, però el coordinador la congela en començar una
sessió. El prefix consolidat no canvia durant la gravació; la descodificació final pot
reemplaçar una sola vegada el tram fiable dels últims set segons.

## Respostes parcials del reconeixedor

Un descodificador RNNT de vegades s’"adorm" durant una part de la finestra, sobretot després d’una pausa.
Aleshores retorna només les paraules posteriors al forat, i les d’abans desapareixen.
Ho vam veure el 25 de setembre de 2026 amb el Conformer i una finestra de 7 s, llegint `lectura.wav`.
Durant uns segons, el model va respondre tres vegades amb el buit i dues només amb "plovia feia fred", sense "quan vam arribar a Montserrat".

Abans, l’editor acceptava aquestes respostes parcials. Consolidava "plovia feia fred", i la frase oblidada quedava darrere del límit consolidat per sempre.
Ara l’editor ho detecta. Si una resposta no té res al lloc d’una paraula que s’havia sentit en dues finestres anteriors, i en canvi sí que té paraules posteriors, és un forat i no una correcció. Una correcció de veritat posa una altra paraula al mateix temps.
- L’editor ignora aquesta resposta, com fa amb les buides, llevat que el forat es repeteixi en tres respostes seguides al perfil Fiable.
- Només compten les paraules que queden ben dins de la finestra, a mig segon o més del principi. Si la finestra ja ha passat de llarg una paraula, que no hi sigui és normal.
- Aquest segon detall el vam haver d’afegir: sense ell, en un fragment del Parlament amb una paraula difícil ("ludopatia"), l’editor ignorava respostes bones i algunes paraules sortien desordenades.

`testPartialObservationDoesNotSkipHeardWords` reprodueix el cas. Sense la protecció, la prova falla ("plovia feia" sense "quan vam arribar").

## Paraules que el model no acaba de decidir

Amb àudio difícil, el reconeixedor pot canviar una paraula a cada finestra: "reaccionària", "redsonària", "reaccionaria".
L'editor només consolida una paraula quan l'ha sentit igual tres vegades seguides. Si això no passa mai, la paraula es queda esperant i fa esperar totes les que vénen darrere.

**Fins al 14 d'octubre de 2026**, una paraula que 2,5 segons després d'acabar encara no s'havia decidit es consolidava tal com s'havia sentit l'última vegada, per no perdre les que venien darrere.
Era el camí per on arribaven a la pantalla les paraules inventades: en una sala amb públic, el reconeixedor escriu una paraula diferent a cada finestra, i la del final es fixava com si fos ferma.
Als 87 fragments del Parlament, les paraules fixades així eren 142 vegades errònies i 63 vegades correctes ("gardinet", "avestres", "forzó", "miedo" per "la nostra escola").

**Ara** l'editor compta totes les formes sentides a cada lloc (agrupant les que només difereixen en accents), i:
- Fiable i Equilibrat no consolidien mai una paraula indecisa. Quan porta 2,5 s indecisa i se l'ha sentida almenys 4 vegades, es descarta, i les paraules de darrere continuen. El lloc recorda les sentides: si el reconeixedor hi torna a escriure una altra cosa, es jutja de seguida. Esperar 4 sentides (i no 2) és el que va donar millor resultat al Parlament (7,52% contra 8,49% de WER): sovint la tercera i la quarta finestra acaben coincidint.
- Immediat consolida la forma més sentida quan dues finestres l'han sentida.

`testUndecidedWordWithoutAgreementIsDropped` i `testOverdueUndecidedWordIsCommittedNotLost` ho comproven.

**Resultat** (87 fragments del Parlament, Conformer, rellotge fix, perfil Fiable):

| | Abans | Ara |
|---|---|---|
| WER | 9,66% | 7,52% |
| Paraules equivocades | 288 | 127 |
| Paraules de més | 36 | 18 |
| Paraules que falten | 68 | 151 |
| Tirades de 3 o més paraules perdudes | 5 | 14 |

A la sala amb públic del banc `.work/venue-test` (vegeu `docs/AUDITORIA-PARAULES-INVENTADES.md`), les paraules equivocades passen del 24% al 10% de les paraules dites.

## Paraules inventades quan ningú parla

El Conformer va aprendre català i castellà, i quan no sent ningú de vegades omple el buit amb paraules curtes en castellà.
Ho vam veure el 26 de setembre de 2026:
- amb silenci absolut, escrivia "muy";
- amb soroll constant (un ventilador, per exemple), escrivia "Más. Más. Más." tota l'estona;
- amb el soreig de la sala del micròfon del portàtil, s'inventava frases senceres.

La veu sempre sobresurt de la sala: a les teves gravacions, les vocals queden entre 20 i 35 dB per sobre del soroll de fons, i el soroll de la sala no passa mai de 9 dB.
Ara l'app només deixa passar una paraula si, al seu voltant, hi ha algun tros de 10 ms que quedi almenys 10 dB per sobre del soroll de fons de la finestra.
- Mira una mica més enllà del final de la paraula, perquè el model marca la primera paraula d'una frase entre 60 i 100 ms abans que soni ("la", "a", "que" després d'una pausa). Sense això, se'n perdia alguna.
- 10 dB és el marge més ample que no perd cap paraula real de les teves tres gravacions ni de cinc sessions de diagnòstic. Amb 12 dB se'n perdia una; amb 15, onze.

`SubtitolEngineIntegrationTests` ho comprova amb el motor de veritat: silenci i soroll de -45 a -70 dBFS, amb finestres de 4 a 8 segons, no mostren cap paraula.

No és un detector de veu que talli l'àudio: el model ho continua sentint tot. Només es descarten paraules on el micròfon no ha sentit res.

## Paraules inventades amb públic (14 d'octubre de 2026)

En una sala amb públic, el filtre d'energia no serveix: el "soroll de fons" és el públic, els aplaudiments i el xivarri el superen (tot passa), i la reverberació omple els forats entre paraules, de manera que la veu real sovint no arriba als 10 dB (les paraules bones es perdien: a la sala dura del banc, el 41% d'omissions).

Ara el detector de veus (pyannote segmentation-3.0, el mateix model que detecta els canvis de veu) guarda on ha sentit una veu (`SpeechPresenceMap`), i allà on ja ha escoltat, la seva decisió mana sobre el filtre d'energia: una paraula on hi ha veu es queda, una paraula on no hi ha ningú es descarta (100 ms de marge per davant i per darrere). On encara no ha escoltat (els últims 0,5 s, i els 2 primers segons de la sessió), decideix el filtre d'energia com abans. Als aplaudiments i al públic del banc no hi sent ningú; al xivarri fort de 10 veus, sí (hi queden 11 paraules inventades en 5 minuts, abans 28).

`testSpeechPresenceMapDropsWordsWhereNobodySpoke` ho comprova. Sense el model de veus, tot passa pel filtre d'energia com abans.

## La confiança del motor (14 d'octubre de 2026)

Fins ara el runtime responia 1,0 de confiança per a totes les paraules: el descodificador RNNT greedy feia l'argmax a la GPU i no en treia cap probabilitat. El pedaç 0004 del runtime (`Vendor/Runtime/patches`) afegeix al mateix graf, al costat de l'argmax, la probabilitat del token triat (softmax i màxim per fila, un número per frame), i cada paraula rep la del seu tros menys segur. L'editor fa la mitjana de les sentides de cada forma.

Amb això, Fiable i Equilibrat no ensenyen ni consoliden una paraula si la seva forma no arriba a 0,5 de confiança mitjana (Immediat, 0,4): la paraula espera sense veure's i, si es fa vella sense arribar-hi, marxa. Calibratge (paraules que el lector acaba veient, alineades amb la referència):

| | Mediana paraules bones | Mediana paraules dolentes | Al llindar 0,5: bones que queden · dolentes que queden |
|---|---|---|---|
| Parlament (87) | 0,80 | 0,64 | 99,5% · 88% |
| Conversa neta | 0,80 | 0,69 | 99,7% · 95% |
| Sala amb públic | 0,72 | 0,59 | 96,6% · 81% |

Resultat (perfil Fiable): Parlament 7,52% → 7,31% de WER (equivocades 127 → 115); sala: paraules equivocades del 9,8% al 8,0% de les dites, omissions +3 punts; esdeveniment 9,6% → 7,5%; públic sol: 11 → 7 paraules inventades. Amb 0,6 es perdia un 3,5% de paraules bones a la conversa neta; amb 0,7, un 20%. La confiança sola no separa: el que fa és sumar-se a la coincidència entre finestres. `testDoubtfulWordsStayUnseenAndGo` i `testCommittedWordsCarryTheRecognisersConfidence` ho comproven; `.work/venue-test/confidence.py` imprimeix la taula.

## Vocabulari de l'acte

Els noms propis són on el model més s'equivoca de manera visible (al Parlament: "Artur Mas", "Rajoy", "Maragall", "Torra", "Renfe"). El runtime admet una llista de paraules a afavorir (context biasing sobre els tokens del SentencePiece incrustat al GGUF), i ara l'app la hi passa: `SubtitleController.vocabulary`, fins a 40 termes, desats entre sessions, aplicats de seguida també mentre escolta. Mac: Vocabulari dins del panell de configuració; iPhone: Vocabulari al panell de l'engranatge. El banc de proves ho reprodueix amb `--boost "nom,terme"`.

## Porta d’entrada per a VAD o un model nou

VAD queda desactivat fins que un replay reproduïble demostri almenys un 80% menys
d’insercions durant no-parla i menys de 0,5 punts percentuals addicionals d’eliminació
de parla suau. Un checkpoint diferent tampoc substitueix el model empaquetat sense
recuperar el checkpoint d’origen i comparar-lo amb FP16 sobre el mateix corpus.

Tornar a quantitzar el mateix checkpoint (com el pas de Q8 a Q4_K amb
`scripts/requantize-model.py`) té una porta més senzilla: cap regressió mesurable
respecte de l’artefacte que substitueix, amb el mateix àudio reproduït amb
`SubtitolLatencyHarness --fixed-clock`, i el silenci i el soroll suau continuen sense
produir paraules (`SubtitolEngineIntegrationTests`). El manifest instal·lat és
`ModelManifest.json`.
