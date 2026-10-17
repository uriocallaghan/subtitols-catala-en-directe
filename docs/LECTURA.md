# Lectura còmoda: text que no es mou i paràgrafs a les pauses

Treball del 25 de setembre de 2026. Tot el que no té font és una mesura nostra, feta amb les eines de `.work/tools/` i amb `SubtitolLatencyHarness`.

---

## El problema

Amb la puntuació activada, el text que ja s'havia llegit saltava.
Una paraula quedava fixa i sortia a la pantalla tal com s'havia sentit. Un segon després, el model de puntuació hi afegia una coma o una majúscula ("jordi" passava a "Jordi,").
La paraula canviava d'amplada, i la pantalla havia de tornar a col·locar tot el bloc: línies senceres ja llegides saltaven a la línia de sota.

## Com ho mesurem

Hem ensenyat al banc de proves a fer el mateix que la pantalla, actualització per actualització.
Compta cada canvi que un lector podria notar en una paraula que ja és a la pantalla:
- una paraula que canvia de línia;
- una paraula que es desplaça dins la línia;
- una paraula que es reescriu;
- una paraula que desapareix.

Ho separem entre el **text fix** (el que ja s'ha llegit) i la **cua viva** (les últimes paraules, que encara es poden corregir).

Per repetir-ho:

```bash
SubtitolLatencyHarness MODEL.gguf AUDIO.wav --fixed-clock --skip-baseline --punctuation models/catala-puntuacio --max-seconds 200
```

La línia `lectura (34 car.)` dona els comptadors, amb una columna de 34 caràcters.

## Abans i després

Tres gravacions teves (lectura, parla lliure i soroll), amb els dos motors:

| | Salts de línia del text ja llegit | Recol·locacions de tot el bloc |
|---|---|---|
| Abans (puntuació de la v0.2 en proves) | **821 a 2.643** per gravació | **16 a 29** per gravació |
| Ara | **0** | **0** |
| Sense puntuació (referència) | 0 | 0 |

A la cua viva hi ha uns 5 salts de línia per gravació. Els provoquen els paràgrafs nous i alguna coma que no hi cap.
Una paraula de la cua es reescriu una sola vegada, quan rep el signe o la majúscula.

**Com s'ha arreglat.** Ara una paraula només passa al text fix quan ja té la forma definitiva: el signe, la majúscula i, si és un número, les xifres.
Fins aleshores és a la cua viva, on un canvi no mou res del que ja s'ha llegit.
La pantalla col·loca cada paraula una sola vegada, ja puntuada.

## Paràgrafs: quan fas una pausa i comences una frase nova

Quan acabes una frase i fas una pausa, la frase següent comença en una línia nova, a l'esquerra.

### Les pauses es mesuren amb el micròfon, no amb el model

Els models de veu no coincideixen en on acaba una paraula. En la teva lectura, la pausa mitjana entre dues frases era:
- de 0,34 s segons el Parakeet, el motor que portava l'app fins al 26 de setembre;
- de 0,55 s segons el Conformer, el d'ara.

Per això mesurem el silenci directament a l'àudio, en trossos de 10 ms. Un tros és silenci si no supera en 12 dB el soroll de fons de la sala, que s'actualitza contínuament. És igual per a qualsevol model de veu.

Pausa típica mesurada a l'àudio (la mediana):

| On | La teva lectura | Parla lliure |
|---|---|---|
| Final de frase | 0,65 s | 0,34 s |
| Coma | 0,21 s | 0,09 s |
| Entre paraules sense signe | 0 s | 0 s |

Dels 176 llocs entre paraules sense signe de la lectura, cap no té una pausa de mig segon.

### Com es decideix

1. El model de puntuació diu com de probable és que la frase s'acabi.
2. La pausa hi suma o hi resta: com més llarga, més probable és el final de frase. Si no hi ha cap pausa, en resta una mica.
3. Si la frase s'acaba i la pausa és de mig segon o més, la frase següent comença en una línia nova.
4. Quan deixes de parlar, en mig segon de silenci les últimes paraules ja reben el punt, sense esperar que diguis res més.
5. Les paraules que vénen després d'una pausa llarga es posen a la línia nova des del primer moment. Així no hi salten un segon més tard.
6. Si calles un segon o més, hi ha línia nova encara que la frase no s'hagi acabat. No hi posem punt ni majúscula: només es veu que t'has aturat. Passa molt poc: en 4.500 paraules de parla espontània del Parlament, 4 vegades.

Per posar el punt, la pausa mai no decideix sola, perquè en parla espontània també parem per pensar.

### Quant pesa la pausa: calibrat amb dades

Hem ajustat quant hi ha de sumar la pausa amb 148 finals de frase: els de les tres gravacions teves i els de 87 fragments de parla espontània del Parlament.
Els fragments són de [ParlamentParla v3 puntuat](https://huggingface.co/datasets/Ugiat/parlament_parla_v3_punctuated) (CC-BY-4.0). Els hem fet servir només per mesurar, no per entrenar.

| F1 final de frase (0–100), amb el model de puntuació v3 | Només el model | Model + pausa |
|---|---|---|
| Totes les dades (148 finals de frase) | 62 | **67** |
| La teva veu (44) | 77 | **83** |
| Parlament (104) | 56 | **60** |

Qualsevol valor raonable dels paràmetres dona entre 65 i 68. Hem triat el del mig, no el millor per un punt, perquè no depengui de la sort d'aquestes dades.

El 26 de setembre ho vam tornar a comprovar amb el Conformer, el model de l'app d'ara, i afegint-hi 245 finals de frase de 60 fragments de converses d'EMpodcat. Els valors de sempre continuen entre els millors: cap altra combinació no guanya a totes les gravacions alhora. No els hem canviat.

## Sessions llargues: el text llegit no canvia mai

L'editor només guarda a la memòria les 160 paraules més recents. En un episodi sencer de podcast (15 minuts) vam veure que, quan la primera paraula d'un número sortia de la memòria, la resta del número es tornava a llegir sola: "dos mil vint" passava a dir "2020 1020 20", i la pantalla es reconstruïa.

Ara la pantalla recorda el text exacte de cada paraula que ja ha mostrat com a fixa, i les paraules que un número s'ha menjat continuen amagades. Una paraula fixa no canvia mai, duri el que duri la sessió.

## Algunes paraules no porten mai majúscula enmig de frase

El model de vegades escriu una majúscula com si comencés una frase ("els instruments Avui mateix").
Ara tenim una llista de 4.539 paraules corrents que no porten mai majúscula a mitja frase. La vam treure de les frases de Common Voice: han d'aparèixer com a mínim 100 vegades i dur majúscula com a molt el 0,5% de les vegades.
Si una d'aquestes paraules surt amb majúscula després d'una coma o sense signe, passa a minúscula.
Els noms propis no hi són mai: Rambla, Sant Jordi, Girona, Universitat o Parlament mantenen la majúscula.
