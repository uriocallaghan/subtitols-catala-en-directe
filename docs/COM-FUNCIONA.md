# Com funciona Subtítol Live

Aquesta nota és per a tu: founder i dissenyador.
No cal saber programar. El que cal és entendre què passa entre la veu i la paraula a pantalla, i per què algunes decisions de producte són com són.

Qui ha entrenat el cervell, amb quines dades i com s’explica a inversors i institucions: [EL-MODEL.md](EL-MODEL.md).

---

## Què és, en una frase

Subtítol Live escolta català al Mac i el converteix en text llegible, en directe, sense enviar res al núvol.

El producte no és “un traductor de veu”.
El producte és un editor en directe: decideix què pot veure el lector i què encara no és prou estable.

---

## La idea central

El reconeixedor de veu és com un traductor de plató que revisa la última frase cada pocs instants.

Si ensenyéssim cada esborrany tal com surt, el text ballaria.
Paraules que ja havies llegit canviarien de forma.
Això cansa i trenca la confiança.

Per això l’app té dues feines, no una:

1. **Escoltar i endevinar** — el model català, al Mac.
2. **Editar abans de mostrar** — un filtre que només deixa passar el que ja és prou estable.

La primera feina és intel·ligència.
La segona és el producte.

---

## El recorregut, de la veu a la pantalla

Pensa-ho com una cadena de postproducció en directe.

### 1. Obres l’app

Es carrega el **model català**.
Un model és el “cervell” empaquetat: ha après a convertir so en paraules.
Viu dins l’app, al disc del Mac.
No es descarrega cada vegada. No parla amb internet.

Es posa a punt a la **GPU** del Mac (el xip gràfic, el mateix que serveix per exportar vídeo).
Això és el que vol dir “Metal” a la interfície: la feina pesada la fa el xip, no un servidor.

Fins que això acaba, no pots gravar.
El text diu “Carregant el català…”.

### 2. Dones permís al micròfon

macOS ho demana una vegada.
Sense micròfon, no hi ha producte.

### 3. Comences (clic o espai)

El micròfon omple un **buffer**, com una cinta que sempre guarda els últims 6 segons i va esborrant el que és més vell.
L’àudio no es desa a disc.
Quan atures, la cinta es buida.

### 4. Cada pocs instants, una “presa” nova

El model no escolta paraula a paraula, com un stenògraf.
Agafa els **últims 4 segons** sencers i torna a endevinar tot aquell tros.

És com si, cada 200 o 300 mil·lisegons, reenviessis el mateix pla a un revisor i ell et tornés un subtítol nou de tot el pla.
(Un mil·lisegon és una mil·lèsima de segon. 300 ms és un parpelleig lent.)

Aquest interval s’anomena **hop**.
Més hop = menys esborranys, text més calmat.
Menys hop = més ràpid, però el text pot tremolar més.

### 5. L’editor decideix què es veu

Cada esborrany nou es compara amb els anteriors.

- Una paraula que el model ha dit **diverses vegades seguides**, i que ja té una mica d’edat, es **bloqueja**. Ja no es mourà.
- Les **últimes 3 paraules** (com a molt) queden a la **cua viva**. Encara poden canviar.

El text bloquejat és el que el lector està llegint.
La cua viva és l’equivalent al “draft” vermell d’un teleprompter: existeix, però no t’hi has de fiar del tot.

### 6. Atures

L’app fa **un últim passi** sobre els 6 segons reals del final.
Com un color grade ràpid al tancament: pot corregir la cua una sola vegada.
El text que ja estava bloquejat no es reescriu sencer.

Després torna a “Preparat”.

---

## Dues capes de text

Això és el que veus, encara que no es dibuixi amb dos colors.

| Capa | Què és | Es pot canviar? |
|---|---|---|
| **Text estable** | El que ja has pogut llegir | No, mentre graves |
| **Cua viva** | Les últimes paraules, com a molt 3 | Sí, si el model canvia d’idea |

Per què com a molt 3?
Perquè una cua llarga és un subtítol que encara s’està reescrivint.
El lector no sap on mirar.

Si una paraula estable canviés, seria com si en un SRT ja publicat et reescrivissin una línia que l’espectador ja ha llegit.
Això, l’app intenta no fer-ho mai.

---

## Els tres perfils

Són un únic control de producte: **velocitat contra calma**.
Es trien amb el menú de dalt a la dreta, **només amb la gravació aturada**.
El perfil es desa. No canvia a mitja sessió.

| Perfil | Sensació | Quan té sentit |
|---|---|---|
| **Fiable** (defecte) | El text triga un pèl més, però gairebé no ballen les paraules | Lectura, accessibilitat, prova davant de gent |
| **Equilibrat** | Compromís | Ús de cada dia |
| **Immediat** | Les paraules surten abans, i la cua viva es nota més | Si vols “sentir” el directe i acceptes més correccions |

No són tres models diferents.
És el mateix cervell, amb l’editor més o menys estricte.

Objectius aproximats de retard visible (de la paraula dita a la paraula estable a pantalla):

- Fiable: uns 1,2 segons
- Equilibrat: uns 0,8 segons
- Immediat: uns 0,5 segons

Mig segon extra de calma sovint val més que mig segon de velocitat.
Això és una decisió de lectura, no d’enginyeria.

---

## La pantalla

Dues columnes.

**Esquerra: el paper.**
Text gran, Inter Medium, ancorat a baix.
Les línies noves neixen a la part inferior i el bloc puja, com un teleprompter o un roll-up de subtítols de televisió.
El text que ja és estable **no es desplaça quan la cua viva es corregeix**.
Només puja quan entra una línia nova de veritat.

Tres moviments, i cap més:

- El bloc puja (suau, 0,24 s)
- Una paraula nova apareix (fade ràpid)
- Una correcció a la cua **no s’anima**: es substitueix. Moure-la cridaria l’ull cap a un error, no cap al sentit.

**Dreta: el camp decoratiu.**
Un fons viu que accelera amb el volum de la veu.
No transcriu. No és un equalitzador.
És presència: saps que l’app t’escolta sense mirar números.

Es pot amagar (`⌘ \`).
El text ocupa aleshores tota l’amplada.

El clic (o l’espai) a la zona de contingut comença o atura.
La franja de dalt de la finestra serveix per arrossegar-la, com qualsevol app de Mac.

---

## El que no fa, a propòsit

- **No envia àudio a internet.** Tot passa al Mac.
- **No desa la conversa**, tret que algú encengui expressament un mode de diagnòstic.
- **No talla el silenci** (el que els enginyers en diuen VAD, “detector de veu”). Encara no: primer ha de demostrar que no s’empassa paraules suaus ni inventa text quan no parles.
- **No és un subtítol de YouTube en brut.** YouTube bolca el que diu el model. Aquí el model no té l’última paraula: l’editor sí.

---

## Què pots tocar tu, sense tocar codi

Aquestes són palanques de producte, no de programació.

| Palanca | Què canvia per a la persona |
|---|---|
| Perfil Fiable / Equilibrat / Immediat | Calma contra rapidesa |
| Mida del text (`⌘ +` / `⌘ −`) | Lectura a distància |
| Tema fosc (`⌘ D`) | Com els subtítols de broadcast: clar sobre fosc |
| Degradat per antiguitat (`⌘ G`) | Les paraules velles s’esvaneixen. Apagat per defecte: el lector va 1–3 s per darrere i justament necessita el que això esborraria |
| Panell de la dreta (`⌘ \`) | Presència visual o només paper |

El perfil no es pot canviar mentre graves.
Canviar-lo a mitja frase seria com canviar l’editor a meitat de directe.

---

## Com saber si “funciona”

No miris si cada paraula és perfecta a l’instant.
Mira tres coses, com si fossis espectador:

1. **Puc llegir sense que el text em salti a sota dels ulls?**
2. **Quan una paraula ja ha pujat, es queda?**
3. **El retard em deixa seguir la persona que parla, o em desconnecta?**

Si 1 i 2 fallen, el producte falla, encara que el model “encerti” més.
Si 3 falla, has de baixar de Fiable a Equilibrat o Immediat — o acceptar que aquest ús vol un altre ritme.

La prova de veritat és una conversa real, amb micròfon real, en català.
Un fitxer d’àudio de laboratori no reprodueix ni el clic accidental, ni el silenci, ni el Mac ocupat exportant.

---

## En una imatge mental

```
veu  →  cinta de 6 s  →  presa de 4 s  →  cervell català al Mac
                                              ↓
                                    esborrany de paraules
                                              ↓
                         editor: bloqueja el que és estable,
                         deixa 3 paraules vives com a molt
                                              ↓
                         paper (roll-up)  |  camp decoratiu
```

El cervell endevina.
L’editor protegeix el lector.
La pantalla només mostra el que ja es pot llegir.
