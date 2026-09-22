# El model i la tecnologia

Aquesta nota és per explicar Subtítol Live a inversors i institucions.
Frases curtes. Cada fet es pot dir en veu alta.
Al final hi ha el que **no** cal dir.

---

## La frase de 20 segons

El reconeixedor de veu no l’hem entrenat nosaltres.
L’arquitectura la va crear NVIDIA.
El Barcelona Supercomputing Center l’ha adaptat al català, dins del Projecte Aina, amb còmput de MareNostrum 5.
Nosaltres el fem córrer **al Mac**, sense núvol, i el convertim en subtítol llegible en directe.

---

## Tres capes. Tres autors.

Pensa-ho com una càmera, un LUT i una sala de muntatge.

| Capa | Què és | Qui ho ha fet | Analogia |
|---|---|---|---|
| **1. L’arquitectura** | Parakeet: com “sent” el so i el converteix en paraules | NVIDIA, amb Suno.ai | La càmera. Un estàndard mundial de transcripció, pensat per ser ràpid |
| **2. L’adaptació catalana** | El mateix cervell, reentrenat amb hores de català | Laboratori de Tecnologies de la Llengua del **BSC**, Projecte **Aina** | El LUT. La càmera ja existia; aquí s’afina a la llum i l’accent del país |
| **3. El producte** | Motor al Mac + editor de lectura en directe | Subtítol Live | La sala de muntatge. Decideix què veu l’espectador |

Si algú pregunta “qui ha fet la IA?”, la resposta honesta és: **NVIDIA la base, el BSC el català, nosaltres el producte.**

---

## Capa 1 — Què és Parakeet

Parakeet és una família de models de **reconeixement automàtic de la parla** (ASR): de so a text.

No és un xat. No escriu respostes. Només transcriu.

L’arquitectura pública de referència és **Parakeet RNNT 1.1B**:

- Uns **1.100 milions de paràmetres**. És la “mida” del cervell: gran, però encara capaç de córrer en un ordinador, no només en un centre de dades.
- Disseny **FastConformer**: una xarxa feta per transcriure de pressa, no per xerrar.
- Descodificador **RNNT** (transductor): va alineant so i paraules alhora, com un stenògraf que escolta i escriu en el mateix temps.
- Entrenat per **NVIDIA NeMo** i **Suno.ai** amb unes **64.000 hores d’anglès** (40.000 privades + 24.000 públiques: LibriSpeech, Common Voice, People’s Speech, etc.).
- Llicència pública **CC-BY-4.0**.

Aquest model de base **no parla català**.
Sap com sona la parla humana. No sap encara les “l·l”, el vocabulari ni els accents del país.

---

## Capa 2 — Qui l’ha fet català, i com

Això és **fine-tuning**, no entrenar de zero.

No es tira la càmera i se’n fabrica una altra.
Es parteix del Parakeet anglès i se’l continua entrenant amb àudio català transcrit.
El cervell ja sap “això és parla”; ara aprèn “això és català”.

### Qui

- **Barcelona Supercomputing Center** (BSC), Laboratori de Tecnologies de la Llengua.
- Dins del **Projecte Aina**, impulsat i finançat per la **Generalitat de Catalunya**.
- Còmput: **MareNostrum 5**, amb accés **EuroHPC**.
- Equip públic de referència (models Parakeet catalans de 2025): **Carlos Daniel Hernández Mena**, supervisió de **Cristina España-Bonet**, validació d’**Abir Messaoudi**. Juny de 2025.

Aina existeix justament perquè el català no depengui de si a Silicon Valley li surt a compte.

### Amb quines dades

Els models Parakeet catalans públics del BSC (sèrie de verificació) es van afinar amb unes **1.800 hores** de català, a partir de:

- **Mozilla Common Voice 17**, part catalana — veu de voluntaris, molts accents.
- **3CatParla** — unes **731 hores** de televisió de 3Cat, transcrita a mà i verificada. Plató, reportatge, conversa de TV. Publicat a IberSPEECH 2024.
- **Corts Valencianes** — parla parlamentària.

No és anglès traduït. És català real: TV, institució i ciutadania.

### Com s’entrena, en una imatge

1. Es carrega el Parakeet anglès de NVIDIA.
2. Se li passen milers d’hores de català amb la transcripció correcta al costat.
3. El model compara el que ha endevinat amb el text bo i es corregeix, milions de vegades.
4. Això passa a MareNostrum 5: moltes GPU en paral·lel, uns 20 cicles complets sobre el corpus.
5. Es publica un **checkpoint**: la “còpia mestra” dels pesos, el negatiu de la pel·lícula.

En condicions de laboratori (Common Voice català, parla llegida), el model A públic del BSC reporta un **WER d’un 3,8%**.
WER és “quantes paraules s’equivoquen de cada 100”.
Un 3,8 en aquest test és fort.
**No és** l’error del directe amb micròfon de sala, overlapping o soroll. Allà el número puja. No el prometis com a mètrica del producte.

---

## Capa 3 — Com entra al Mac (això sí que és nostre)

El checkpoint del BSC no corre sol a una app.

El convertim a **GGUF**, quantitzat a **Q8**.

- GGUF és el format d’entrega: com passar d’un master RAW a un còdec de distribució.
- Q8 vol dir 8 bits per pes: l’arxiu encongeix molt i la qualitat es queda gairebé igual. Com un ProRes respecte el RAW.

El motor és **NeMo-Speech.cpp**: una versió nativa (C++) de l’ecosistema de veu de NVIDIA, amb **Metal** (el xip gràfic del Mac).

El model viu **dins l’app**.
No hi ha OpenAI, ni Google, ni un servidor nostre escoltant.
La veu no surt de l’ordinador.

El descodificador treballa en **finestra completa** (els últims 4 segons), no paraula a paraula com un stenògraf de pel·lícula.
Per això el producte té un editor a sobre: el model revisa el pla sencer cada pocs instants; l’app decideix què és prou estable per llegir-ho.

---

## Quina és la tesi de país (per a institucions)

1. **Soberania lingüística.** El català de l’app no depèn d’un model genèric que “també fa català”. Parteix d’un adaptació feta a Barcelona, amb dades catalanes i supercomputació pública.
2. **Privacitat per disseny.** L’àudio no viatja. Serveix per a educació, administració, salut, plató: llocs on el núvol és un problema, no una comoditat.
3. **Infraestructura que ja s’ha pagat.** Aina i MareNostrum han fet la feina cara (entrenar). El producte amortitza aquesta inversió pública en una experiència que la gent pot usar.
4. **El valor no és “tenir un model”.** El valor és fer-lo **llegible en directe**. Whisper i companyia transcriuen; poques coses protegeixen el lector mentre el model canvia d’idea.

---

## Quina és la tesi de negoci (per a inversors)

- El model de base és **obert** i de primer nivell (NVIDIA).
- L’adaptació catalana és **institucional** (BSC / Aina), no un experiment intern de dues setmanes.
- El moat no són els pesos: són el **runtime on-device** + l’**editor de lectura** + el **disseny de directe**.
- Es pot canviar de checkpoint (un Parakeet millor, un altre idioma) sense reescriure el producte. El producte és la capa 3.

---

## pkt-a i pkt-b: per què n’hi ha dos, i quin porta l’app

El BSC no va publicar “el model català” i “el recanvi”.
Va publicar **una parella de verificació**: dos cervells bessons, mateixa arquitectura, mateix català, entrenats amb **meitats diferents** del mateix corpus (enregistraments parells per a l’A, senars per al B).

Per a què:
si els dos escriuen el **mateix** text per al mateix àudio, el BSC es fia més de la transcripció.
Serveix per netejar corpus quan no hi ha un humà que ho revisi.
És com dos coloristes independents sobre el mateix pla: si coincideixen, el grau és creïble.

No són “el bo i el dolent”.
Tots dos transcriuen català.
En el test públic de Common Voice, el B surt una mica millor (un 3,74% d’error contra un 3,85% de l’A). La diferència és petita.

**L’app n’usa un de sol**, no els dos.
El directe necessita una veu, un text.
Fer córrer A i B alhora duplicaria la feina del Mac i no milloraria la lectura.

**Quin dels dos és el de l’app: no està escrit al fitxer.**
El que corre es diu `catalan-parakeet-q8.gguf`.
Dins només hi diu aquest nom. Ni “pkt-a” ni “pkt-b”.
Són tan semblants que, sense reconvertir les còpies mestres del BSC i comparar-les, no es distingeixen.

Pots dir: “un Parakeet català del BSC, de la línia de verificació Aina”.
No pots dir encara “pkt-a” o “pkt-b” com a fet.

Pregunta d’una línia, a `bsc-lt@bsc.es` o al contacte d’Aina:

> Quin checkpoint Parakeet català correspon als pesos que corre Subtítol Live (pkt-a, pkt-b o un altre), i quina llicència té per a ús comercial i institucional?

---

## Frases llestes per dir

**A un inversor**

> “No competim a entrenar el model més gran. Agafem el Parakeet de NVIDIA, adaptat al català pel BSC amb Aina, i el fem córrer al Mac amb una capa de lectura que el converteix en subtítol de veritat, no en un esborrany que balla.”

**A una institució**

> “La veu no surt de l’ordinador. El català l’ha treballat el Barcelona Supercomputing Center, amb dades del país i MareNostrum 5. Nosaltres hi posem el producte: directe, privat, llegible.”

**Si pregunten per Whisper o ChatGPT**

> “Whisper és un transcriptor de propòsit general, sovint al núvol o pesat. ChatGPT no transcriu en directe. Parakeet està fet per transcriure de pressa. El català l’ha posat el BSC. La diferència nostra és que el text es pot llegir mentre passa, no només descarregar-lo després.”

---

## El que no has de dir

- “Hem entrenat Parakeet.” No. L’hem empaquetat i productitzat.
- “Té un 3,8% d’error en directe.” Això és un test de laboratori del BSC, parla llegida.
- “És intel·ligència artificial generativa.” No genera text lliure. Només transcriu.
- Un nom concret de checkpoint (pkt-a, una revisió) fins que estigui confirmat.
- Que 3CatParla ja és un dataset obert al 100%. El paper el descriu; la publicació completa a Hugging Face encara es marcava com a pendent.

---

## En una imatge

```
NVIDIA + Suno     64.000 h d’anglès     →  Parakeet (la càmera)
        ↓
BSC / Aina        ~1.800 h de català    →  el mateix cervell, en català
                  MareNostrum 5            (Common Voice, 3Cat, Corts)
        ↓
Subtítol Live     GGUF Q8 + Metal       →  corre al Mac, sense núvol
                  + editor de lectura      →  el que veu la persona
```
