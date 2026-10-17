# El model i la tecnologia

Aquesta nota és per explicar Subtítol Live a inversors i institucions.
Frases curtes. Cada fet es pot dir en veu alta.
Al final hi ha el que **no** cal dir.

---

## La frase de 20 segons

El reconeixedor de veu no l’hem entrenat nosaltres.
L’arquitectura la va crear NVIDIA.
El Barcelona Supercomputing Center l’ha ensenyat a escoltar català, i el publica el Projecte Aina, amb còmput de MareNostrum 5.
Nosaltres el fem córrer **al Mac**, sense núvol, i el convertim en subtítol llegible en directe.

---

## Tres capes. Tres autors.

Pensa-ho com una càmera, un LUT i una sala de muntatge.

| Capa | Què és | Qui ho ha fet | Analogia |
|---|---|---|---|
| **1. L’arquitectura** | Conformer-Transducer: com “sent” el so i el converteix en paraules | NVIDIA | La càmera. Un disseny estàndard de transcripció, compacte i ràpid |
| **2. L’adaptació catalana** | El mateix cervell, reentrenat amb milers d’hores de català | Unitat de Tecnologies del Llenguatge del **BSC**, publicat al Projecte **Aina** | El LUT. La càmera ja existia; aquí s’afina a la llum i l’accent del país |
| **3. El producte** | Motor al Mac + editor de lectura en directe | Subtítol Live | La sala de muntatge. Decideix què veu l’espectador |

Si algú pregunta “qui ha fet la IA?”, la resposta honesta és: **NVIDIA la base, el BSC el català, nosaltres el producte.**

---

## Capa 1 — Què és un Conformer-Transducer

És un model de **reconeixement automàtic de la parla** (ASR): de so a text.

No és un xat. No escriu respostes. Només transcriu.

- Uns **120 milions de paràmetres**. És la “mida” del cervell: prou petit per cabre en un mòbil.
- **Conformer** vol dir que barreja dues maneres d’escoltar: la de prop (els sons d’una síl·laba) i la de lluny (el sentit de la frase sencera).
- Descodificador **transductor** (RNNT): va alineant so i paraules alhora, com un estenògraf que escolta i escriu en el mateix temps.
- El punt de partida és el model castellà de NVIDIA, `stt_es_conformer_transducer_large`, entrenat amb **1.340 hores de castellà**. Llicència **CC-BY-4.0**.

---

## Capa 2 — Qui l’ha fet català, i com

Això és **fine-tuning**, no entrenar de zero.
Es parteix del model castellà de NVIDIA i se’l continua entrenant amb àudio català transcrit.
El cervell ja sap “això és parla”; ara aprèn “això és català”.

### Qui

- **Barcelona Supercomputing Center** (BSC), Unitat de Tecnologies del Llenguatge: **Abir Messaoudi** i **Baybars Külebi**, el 2024.
- Publicat pel **Projecte Aina** (Generalitat de Catalunya).
- Finançat pel projecte **ILENIA** (Ministeri per a la Transformació Digital, fons NextGenerationEU). Les dades valencianes, amb la col·laboració del **CENID**.
- Còmput: **MareNostrum 5**.
- Llicència **CC-BY-4.0**: es pot fer servir en un producte comercial, citant-ne l’autor.

### Amb quines dades

**7.426 hores** de català i castellà. La part catalana:

- **Parlament de Catalunya** (ParlamentParla) i **Corts Valencianes** — parla institucional.
- **3Cat** i **IB3** — televisió: plató, reportatge, conversa.
- **Common Voice** — veu de voluntaris, amb un banc de proves d’accents catalans.

Com que va aprendre català i castellà alhora, entén les dues llengües.
Per a nosaltres és una virtut (paraules com “vale” o “bueno” surten com es diuen) i un risc: amb àudio molt difícil, de tant en tant escriu alguna paraula en castellà.

En condicions de laboratori, el BSC reporta un **2,5% d’error** amb diversos accents catalans i un **3,9%** amb Common Voice català.
L’error és “quantes paraules s’equivoquen de cada 100”.
**No és** l’error del directe amb micròfon de sala, gent que parla alhora o soroll. Allà el número puja. No el prometis com a mètrica del producte.

---

## Capa 3 — Com entra al Mac (això sí que és nostre)

El model del BSC no corre sol dins d’una app.

1. **El convertim a GGUF**, el format que llegeix el motor, amb una precisió de 8 bits per número (**Q8**). El cervell ocupa **131 MB**.
2. **Ensenyem al motor la porta d’entrada del Conformer clàssic.** El motor de NVIDIA que fem servir (NeMo-Speech.cpp) només coneixia la del FastConformer. És un canvi petit, desat a `SubtitolLive/Vendor/Runtime/patches`.
3. **Demostrem que escolta igual que l’original.** Contra una versió de referència independent, 72 de 74 fragments surten idèntics i només canvien 6 paraules de 1.665. En l’única diferència de fons, el nostre encerta.
4. **No el comprimim més del que aguanta.** Q8 és la compressió més petita que no canvia el que escriu. Amb 6 bits ja s’inventava un “vale”, i amb 4 bits escrivia “dinou” per “mil nou-cents”. Un cervell petit aguanta menys la compressió que un de gran.
5. **Traiem pes mort.** El fitxer portava una taula de 20 MB que es pot calcular amb una fórmula. Ara el motor la calcula en arrencar, i les transcripcions surten idèntiques.
6. **Arreglem els apòstrofs.** De vegades escriu “l acordió” o “se n va”, perquè part dels textos amb què va aprendre no els tenien. Una regla del català ho arregla: una “l”, “d”, “m”, “n”, “s” o “t” soles no són mai una paraula.
7. **Li donem context.** Va aprendre amb frases llargues: amb 4 segons d’àudio s’equivoca el doble que amb 6. L’app li dona **7 segons** cada vegada, i el text no arriba més tard.

El motor és **NeMo-Speech.cpp**: una versió nativa (C++) de l’ecosistema de veu de NVIDIA, amb **Metal** (el xip gràfic del Mac). Revisar els 7 segons li costa unes **0,12 s** en un MacBook Air M3.

El model viu **dins l’app**.
No hi ha OpenAI, ni Google, ni un servidor nostre escoltant.
La veu no surt de l’ordinador.

El model revisa el pla sencer cada pocs instants. Per això el producte té un editor a sobre: l’app decideix què és prou estable per llegir-ho, hi posa la puntuació, les majúscules i les xifres, i salta de línia quan fas una pausa.

---

## Per què aquest model i no un altre (26 de setembre de 2026)

Fins al 25 de setembre, l’app portava el **Parakeet** català del BSC (1.100 milions de paràmetres, 612 MB). Els vam comparar amb àudio públic que **cap dels dos havia sentit mai**, escoltant com a l’app, en directe:

| Àudio | Parakeet | **Conformer** |
|---|---|---|
| FLEURS: 150 frases llegides per persones diferents | 4,0 errors per cada 100 paraules | **3,8** |
| EMpodcat: 60 fragments de conversa de 10 episodis | 14,6 | **12,8** |
| Podcast de Softcatalà: 2 episodis sencers, 35 minuts, 3–6 veus | 8,5 | **7,3** |

- En lectura queden empatats. En conversa, el Conformer fa 1 error menys cada 60 paraules, i la diferència no és sort.
- Pesa **cinc vegades menys** (131 MB contra 612 MB).
- Té una **llicència clara** per a ús comercial.
- **Cap en un iPhone.**

Per això és l’únic model de l’app. Les dades i els programes de la prova són a `.work/clean-test`, per repetir-la amb qualsevol model nou.

Una advertència: el Conformer es va entrenar amb gravacions del Parlament. Una prova amb el Parlament el fa semblar millor del que és. Per comparar models, cal àudio que cap dels dos hagi sentit.

---

## El camí cap a l’iPhone

- **El cervell ja hi cap:** 131 MB és la mida d’una app normal.
- **El motor és el mateix:** ggml amb Metal ja funciona en iPhones (whisper.cpp i llama.cpp ho fan). La part comuna de l’app (`SubtitolCore` i `SubtitolEngine`: l’editor, la puntuació, les xifres, la reparació d’apòstrofs) no depèn de res del Mac.
- **Què falta:**
  1. Compilar el motor per a iOS com a `.xcframework`, sense les parts que no calen (micròfon propi, diarització, veu sintètica).
  2. Fer la pantalla en SwiftUI per a iPhone.
  3. Mesurar-ho en un iPhone de veritat: escalfor, bateria i temps per finestra, i comparar Metal amb Core ML (el Neural Engine d’Apple).

---

## Quina és la tesi de país (per a institucions)

1. **Sobirania lingüística.** El català de l’app no depèn d’un model genèric que “també fa català”. Parteix d’una adaptació feta a Barcelona, amb dades del país i supercomputació pública.
2. **Privacitat per disseny.** L’àudio no viatja. Serveix per a educació, administració, salut, plató: llocs on el núvol és un problema, no una comoditat.
3. **Infraestructura que ja s’ha pagat.** Aina, ILENIA i MareNostrum han fet la feina cara (entrenar). El producte amortitza aquesta inversió pública en una experiència que la gent pot usar.
4. **El valor no és “tenir un model”.** El valor és fer-lo **llegible en directe**. Whisper i companyia transcriuen; poques coses protegeixen el lector mentre el model canvia d’idea.

---

## Quina és la tesi de negoci (per a inversors)

- El model de base és **obert** i de primer nivell (NVIDIA).
- L’adaptació catalana és **institucional** (BSC / Aina), no un experiment intern de dues setmanes.
- La llicència (**CC-BY-4.0**) permet vendre el producte citant els autors.
- El fossat no són els pesos: són el **runtime al dispositiu** + l’**editor de lectura** + el **disseny del directe**.
- Es pot canviar de model (un de millor, un altre idioma) sense reescriure el producte. Ja ho hem fet una vegada: del Parakeet al Conformer. El producte és la capa 3.

---

## Frases llestes per dir

**A un inversor**

> “No competim a entrenar el model més gran. Agafem un model de NVIDIA que el Barcelona Supercomputing Center ha ensenyat a escoltar català, i el fem córrer al Mac amb una capa de lectura que el converteix en subtítol de veritat, no en un esborrany que balla.”

**A una institució**

> “La veu no surt de l’ordinador. El català l’ha treballat el Barcelona Supercomputing Center, amb dades del país i MareNostrum 5, i el publica el Projecte Aina. Nosaltres hi posem el producte: directe, privat, llegible.”

**Si pregunten per Whisper o ChatGPT**

> “Whisper és un transcriptor de propòsit general, sovint al núvol o pesat. ChatGPT no transcriu en directe. El nostre model és petit i està fet per transcriure de pressa, i el català l’ha posat el BSC. La diferència nostra és que el text es pot llegir mentre passa, no només descarregar-lo després.”

---

## El que no has de dir

- “Hem entrenat el model.” No. L’hem convertit, verificat i productitzat.
- “Té un 2,5% d’error en directe.” Això és un test de laboratori del BSC, amb parla llegida.
- “És intel·ligència artificial generativa.” No genera text lliure. Només transcriu.
- “Només entén català.” Va aprendre català i castellà alhora.

---

## En una imatge

```
NVIDIA            1.340 h de castellà    →  Conformer-Transducer (la càmera)
        ↓
BSC / Aina        7.426 h ca + es        →  el mateix cervell, en català
                  MareNostrum 5             (Parlament, Corts, 3Cat, IB3, Common Voice)
        ↓
Subtítol Live     GGUF Q8 + Metal        →  corre al Mac, sense núvol
                  + editor de lectura       →  el que veu la persona
```
