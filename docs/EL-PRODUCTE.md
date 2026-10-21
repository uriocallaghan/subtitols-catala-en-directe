# Subtítol Live, en paraules senzilles

Per al fundador. Es llegeix en deu minuts i serveix per explicar el producte en públic.
Aquí no hi ha codi: si surt una paraula tècnica, és al glossari del final.

---

## En una frase

Subtítol Live posa subtítols en català, en directe, a tot el que es diu al teu voltant. Funciona dins de l'ordinador, sense internet i sense enviar la veu enlloc.

## En trenta segons, per dir-ho en veu alta

> Apple no té subtítols en directe en català, i la majoria d'eines que en fan envien la veu a servidors d'altres empreses.
> Nosaltres agafem el millor model de veu en català, el que ha adaptat el Barcelona Supercomputing Center amb el Projecte Aina, i en fem una app que qualsevol pot fer servir.
> Parles i el text apareix a la pantalla, estable i llegible, i la teva veu no surt mai de l'ordinador.

## Per a qui és

- Persones sordes o amb pèrdua auditiva, que volen seguir una conversa llegint.
- Aules, conferències i actes: el text apareix a la pantalla mentre algú parla.
- Reunions i entrevistes.
- Qualsevol lloc on es parli en català i convingui llegir-ho.

---

## Què el fa diferent: quatre idees

**1. No surt res de l'ordinador.**
La veu es converteix en text al mateix Mac. No hi ha servidor, ni compte, ni subscripció.
No és una promesa de privacitat: simplement, les dades no tenen cap lloc on anar.

**2. És català de veritat.**
El "cervell" ha après escoltant unes 1.800 hores de català real: televisió, el Parlament valencià i veus de voluntaris.
L'aprenentatge es va fer al superordinador MareNostrum 5, dins del Projecte Aina, finançat per la Generalitat.

**3. Es pot llegir mentre passa.**
Els subtítols automàtics habituals "ballen": les paraules canvien mentre les llegeixes.
El nostre editor només treu a la pantalla el que ja és segur. Com a molt, les tres últimes paraules encara poden canviar.

**4. És lleuger.**
El cervell ocupa ara la meitat que abans (0,61 GB) i escriu el mateix. Això és el que ens obre la porta de l'iPhone.

---

## Com funciona, sense tecnicismes

Imagina un intèrpret de plató amb un editor al costat.

1. **El micròfon** escolta i guarda sempre els últims segons.
2. **El cervell** (el model de veu) escolta aquest tros tres vegades per segon i proposa què s'ha dit.
3. **L'editor** compara cada proposta amb les anteriors. Quan una paraula es repeteix prou, la dona per bona i ja no la toca.
4. **La pantalla** mostra el text estable, gran i tranquil, com els subtítols d'una tele.

El text surt amb un segon de retard, més o menys, que és el preu de no fer ballar les paraules.
Si vols el detall de cada pas: [Com funciona](COM-FUNCIONA.md).

---

## Qui ha fet què

Sigues sempre generós amb els crèdits: és la veritat i, a més, dona credibilitat.

| Peça | Qui l'ha feta |
|---|---|
| L'arquitectura del cervell de veu (Conformer-Transducer) | NVIDIA |
| L'adaptació al català | Barcelona Supercomputing Center, Projecte Aina, MareNostrum 5 |
| El motor que el fa funcionar dins del Mac | NVIDIA (codi obert) |
| La base del model de puntuació, que ja entenia el català | Projecte Aina (BSC) |
| **L'app, l'editor de lectura, la compressió, el disseny i l'entrenament del model de puntuació** | **Nosaltres** |

> "NVIDIA va fer la càmera, el BSC hi va posar el català i nosaltres n'hem fet el producte."

Si vols el detall de qui va fer el model i com: [El model i la tecnologia](EL-MODEL.md).

---

## Què hem aconseguit fins ara

**Versió 0.1 (setembre de 2026): primera versió pública per a Mac.**
El cervell ocupava 1,1 GB.

**Versió 0.2: el mateix cervell, a la meitat.**
- El cervell són 1.100 milions de números. Els hem guardat amb menys decimals, com quan passes una foto de RAW a un JPEG de qualitat alta.
- Ara ocupa 0,61 GB i fa servir un 40% menys de memòria. Va igual de ràpid.
- **Ho hem comprovat abans de dir-ho:**
  - Amb la teva veu (llegint, parlant lliurement i amb soroll de fons), de 600 paraules només n'ha canviat una respecte de l'anterior.
  - Amb 1.064 paraules d'una prova pública que el model no havia sentit mai, n'han canviat 5. En algunes ha encertat més la nova versió i en d'altres l'antiga, i en conjunt queda igual.

**La demo web** ([asr.uriocallaghan.com](https://asr.uriocallaghan.com)) és per a qui no té Mac.
Compte: aquesta demo encara fa servir un servei al núvol (Deepgram), no el nostre model. Allà la veu sí que viatja a una empresa externa.

---

## Què estem fent ara: un model de puntuació lliure per al català

**El problema.**
El cervell de veu ho escriu tot en minúscules i sense signes:

> bon dia em dic jordi puig i avui faig una prova el vint-i-tres d'abril per sant jordi vam anar a la rambla

Es pot llegir, però cansa. Necessitem això:

> Bon dia. Em dic Jordi Puig i avui faig una prova. El 23 d'abril, per Sant Jordi, vam anar a la Rambla.

**Per què no n'hi ha cap que puguem fer servir.**
- Hi ha tres models de puntuació en català publicats, però cap no té llicència: legalment no els podem fer servir en una app.
- L'únic lliure que inclou el català és d'un autor que el va entrenar amb molt poc català, i s'equivoca molt.
- El castellà i el basc ja tenen models de puntuació lliures. El català, no.
- El BSC té reconeixedors de veu que ja escriuen amb punts i comes. Però són motors sencers, no una peça que es pugui afegir a un altre, i el nostre motor no els pot fer córrer.
- La intel·ligència artificial d'Apple no parla català.

**Què fem.**
Ensenyem a una intel·ligència artificial petita a posar punts, comes, majúscules i noms propis.
- **Com aprèn:** li donem textos sense signes, ella intenta posar-los, compara el resultat amb l'original i es corregeix. Ho fa centenars de milers de vegades.
- **Amb quins textos:** només fem servir text de domini públic (les frases en català del projecte Common Voice, de Mozilla) i una base de Projecte Aina amb llicència lliure. Així el resultat és nostre i el podem regalar.
- **Les xifres ("vint-i-tres" → "23"):** les resolem amb regles, seguint el llibre d'estil de 3Cat (l'ésAdir).
- **Les pauses:** quan algú calla, sovint s'ha acabat la frase. Amb la teva veu ho hem mesurat: al final de frase calles un terç de segon, i entre paraules, gairebé res. El model aprofitarà aquesta pista, que els models que només llegeixen text no tenen.

**On som (25 de setembre de 2026).**
Ja tenim una segona versió, entrenada en dues hores en aquest mateix Mac. Primer va aprendre amb 500.000 frases escrites i després amb discursos del Parlament de Catalunya i de les Corts Valencianes, tot de domini públic.
- **En la prova pública**, puntua millor que qualsevol model català existent: encerta més finals de frase i més comes, i els iguala en noms propis.
- **En converses reals** (podcasts) ha millorat molt, però és on encara té més marge.
- **Comprimit, ocupa 59 MB** i no perd qualitat. Els models existents es publiquen en 500 MB. Comprimits igual, en farien uns 90.
- **Hem comprovat que no ha vist mai les frases de l'examen.**

**Per què és important.**
Si surt bé, el publicarem gratis perquè qualsevol el pugui fer servir: altres apps, escoles, mitjans, investigadors.
Seria, que sapiguem, el primer model d'aquest tipus per al català amb llicència lliure.
No és només una funció de la nostra app: és una peça que falta en la intel·ligència artificial en català.

**Quan el podem anunciar.**
Quan estigui acabat, mesurat i publicat, i no abans. Fins llavors, parla'n com un projecte en marxa.

---

## Cap on anem

1. **Puntuació, majúscules i xifres.** És el que fem ara.
2. **iPhone i iPad.** Serà la mateixa app, i el cervell comprimit ho fa possible.
3. **Una versió en línia amb el model català del BSC**, per a qui fa servir Android o Windows.

---

## Números que pots dir

| Dada | Com dir-ho |
|---|---|
| 0,61 GB | "El cervell ocupa la meitat que a la primera versió, i escriu el mateix." |
| 1.800 hores | "Ha après escoltant 1.800 hores de català real." |
| 3 vegades per segon | "Revisa el que dius tres vegades per segon." |
| Uns 1–1,2 segons | "El text arriba amb un segon de retard, a canvi que no balli." |
| 0 | "La teva veu no surt de l'ordinador. Mai." (Només l'app de Mac, no la demo web.) |

---

## Preguntes difícils, i respostes honestes

**"Quina precisió té?"**
"Llegint en veu alta en una habitació tranquil·la, s'equivoca en una o dues paraules de cada dues-centes. Amb soroll o parla espontània, s'hi equivoca més. Encara no tenim una mesura amb molts accents i veus."

**"És com el dictat de l'iPhone?"**
"El dictat en català de l'iPhone envia la veu als servidors d'Apple, i els Subtítols en Directe d'Apple no fan català. El nostre funciona dins de l'ordinador."

**"Heu fet vosaltres la intel·ligència artificial?"**
"El cervell de veu és de NVIDIA i del BSC. Nosaltres l'hem fet servible, lleuger i llegible. El model de puntuació sí que l'hem entrenat nosaltres, a partir d'una base del Projecte Aina."

**"És el primer model de puntuació en català?"**
"No. N'hi ha tres de publicats, i la Universitat de Múrcia hi va dedicar un article el 2023, però cap no té llicència. El nostre seria el primer lliure, i a la mateixa prova pública és el que encerta més."

**"El BSC ja té models que puntuen, no?"**
"Sí, reconeixedors de veu que escriuen directament amb punts. Són motors sencers. El nostre és una peça petita que es pot afegir a qualsevol transcripció, també a les que ja existeixen."

**"Per què no ho fa el BSC?"**
"El BSC investiga i publica models. Convertir-los en productes per a la gent és una altra feina, la nostra."

**"Quant costa?"**
"L'app de Mac és gratuïta i de codi obert."

**"Funciona a Windows o a Android?"**
"Encara no. La demo web funciona a qualsevol navegador, però fa servir un servei al núvol."

**"Què passa amb les meves dades?"**
"A l'app de Mac, res: ni surten de l'ordinador ni es desen. Només es guarden si algú activa expressament un mode de proves."

**"I els accents valencià, balear, del nord…?"**
"El model s'ha entrenat amb veus de tot el territori, incloent-hi el Parlament valencià. Encara no ho hem mesurat accent per accent."

---

## El que encara no has de dir

- **"Hem creat la IA de veu."** La van fer NVIDIA i el BSC.
- **Un percentatge de precisió com a xifra general.** Només tenim proves petites.
- **"Funciona a l'iPhone."** Encara no.
- **"El primer model de puntuació lliure en català."** Encara no, fins que estigui acabat, mesurat i publicat.
- **"Ningú no havia fet puntuació automàtica en català."** Hi ha tres models sense llicència, un article del 2023 i els reconeixedors del BSC, que ja puntuen.
- **"Vuit vegades més petit que els altres."** Això compara el nostre, comprimit, amb els altres sense comprimir. Comprimits igual, el nostre és un terç més petit.
- **"Sense núvol", parlant de la demo web.** Fa servir Deepgram.
- **"Per a tots els Mac."** Només funciona als Mac amb xip Apple (M1 o posterior).

---

## Glossari

- **Model, o cervell:** un programa que ha après una habilitat a partir d'exemples, en lloc de seguir regles escrites a mà.
- **Pesos:** els milions de números que formen el model. Són el que ha après.
- **Quantitzar (Q8, Q4):** guardar aquests números amb menys decimals perquè ocupin menys. Q8 fa servir 8 bits per número; Q4, uns 4,5.
- **Al dispositiu / al núvol:** "al dispositiu" vol dir que tot passa dins del teu aparell. "Al núvol" vol dir que les dades viatgen a un servidor d'una altra empresa.
- **Entrenar:** ensenyar un model amb exemples fins que ho fa bé.
- **Llicència lliure:** un permís escrit perquè qualsevol pugui fer servir, modificar i compartir una obra. Les llicències Apache i MIT ho permeten.
- **Domini públic (CC0):** una obra que no té drets reservats. En pots fer el que vulguis.
- **Puntuació i normalització:** posar punts, comes i majúscules, i escriure les xifres com a xifres.
- **BSC, Projecte Aina, MareNostrum 5:** el Barcelona Supercomputing Center; el programa de la Generalitat per a la intel·ligència artificial en català; i el superordinador on s'entrenen els models.
- **Metal, GPU i Neural Engine:** les parts del xip d'Apple que fan la feina pesada del model.

---

## Per saber-ne més

- [Com funciona](COM-FUNCIONA.md): la cadena de la veu a la pantalla, pas a pas.
- [El model i la tecnologia](EL-MODEL.md): qui va fer el model, amb quines dades, i què són Q8 i Q4.
- [Puntuació i normalització](PUNTUACIO-I-NORMALITZACIO.md): la investigació completa, amb totes les proves i les fonts.
