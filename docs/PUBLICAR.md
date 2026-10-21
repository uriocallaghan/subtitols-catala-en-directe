# Publicar duna a l'App Store (iPhone i Mac)

Passos per publicar duna, a 30 de setembre de 2026, en l'ordre en què s'han de fer.

Tot el que has de pujar és a l'Escriptori, a la carpeta **`duna - per pujar`**:
- `1 Apps`: l'app d'iPhone (`duna-iPhone.ipa`) i la de Mac (`duna-Mac.pkg`), signades per a l'App Store;
- `2 Idiomes`: els cinc paquets d'idioma;
- `3 Captures`: les captures de pantalla;
- els textos per copiar (`APP-STORE-FITXA.md`, també a `docs/`) i aquests passos.

**Llegenda:** ✅ fet · 👤 ho has de fer tu (necessita el teu compte o la teva decisió)

---

## Versió 1.1 (21 d'octubre): enviada a revisió

La 1.0 ja és a la venda (iPhone i Mac). La 1.1 (compilació 8) es va pujar i enviar a revisió el 21 d'octubre, amb textos, notes i les 30 captures noves. Es publica sola quan Apple l'aprovi.

## Compilació 8 (20 d'octubre): editor, transcripcions desades i vocabulari

L'auditoria del 20 d'octubre (`.app-store-audit/`) va trobar el que calia arreglar abans d'enviar aquesta versió, i ja està fet:
- el número de compilació passa a **8** (la 7 ja està pujada);
- les notes per al revisor i les descripcions de la fitxa expliquen l'app d'avui (`APP-STORE-FITXA.md`);
- la política de privacitat, el suport i les condicions d'ús diuen que les transcripcions i les correccions es guarden a l'aparell, i que els vídeos amb subtítols es desen a Fotos;
- a l'iPhone, la baixada de GitHub continua una estona si surts de l'app, i si s'atura, es reprèn on era quan tornes.
- ✅ la web nova és publicada (21 d'octubre) i ja no porta l'script de la insígnia de Netlify;
- ✅ les compilacions 8 són a `duna - per pujar/1 Apps` (la 7 es conserva a `.work/store-archives/export-7`) i a l'Organizer de Xcode ("duna iPhone 1.0 (8)", "duna Mac 1.0 (8)");
- ✅ les notes ja no porten cap telèfon: el revisor té el correu.

Els teus passos:
1. 👤 **Mira a App Store Connect com està la 1.0 (7).** Si encara és en revisió, treu-la de revisió (*Remove from Review*). Si ja l'han aprovada i publicada, avisa'm: la nova ha de ser la 1.0.1, amb un text de novetats.
2. 👤 **Posa el teu telèfon a App Review Information** (camp obligatori i privat: només el veu Apple). Les notes ja no el demanen.
3. 👤 **Valida abans de pujar:** Xcode › Window › Organizer › arxiu "duna" 1.0 (8) › **Validate App**.
4. 👤 **Puja les dues compilacions 8**. Tria la 8 a iOS i a macOS, enganxa les notes noves i les descripcions, i **afegeix els cinc paquets d'idioma a tots dos enviaments**.
5. 👤 A **Pricing and Availability**, desactiva "iPhone and iPad apps on Apple silicon Macs" (ja hi ha l'app de Mac) i Apple Vision Pro.
6. 👤 **Prova la 8 a TestFlight al Mac, partint de zero:** esborra l'app → baixa un idioma → dona el micròfon → parla. Prova també a dir que no al micròfon.

---

## Rebuig del Mac (6 d'octubre) i compilació 7

Apple va rebutjar la versió de Mac (compilació 6, norma 2.1a): en triar un idioma, la baixada fallava i l'app deia "torna-ho a provar". La causa és coneguda als fòrums d'Apple (fil 815174): l'entorn de revisió sovint no pot baixar els paquets allotjats per Apple, sobretot al Mac. L'estudi de les opcions és a `docs/ESTUDI-IDIOMES-MIDA.md`; la decisió va ser no ficar cap model dins l'app.

Què canvia a la compilació 7 (iPhone i Mac):
- **Recanvi de GitHub.** Si l'App Store no serveix el paquet (no el troba, falla, o no avança en 20 segons), l'app baixa el mateix fitxer `.aar` d'una publicació del repositori públic (`packs-1.0`), en comprova la suma SHA-256 (gravada dins l'app) i l'instal·la. La persona veu una sola barra de progrés. Al Mac, l'app porta el permís de sandbox de connexions sortints només per això.
- Un inici fallit (micròfon denegat, cap entrada) ja no deixa l'app clavada: un clic o un toc ho torna a provar.
- Els diàlegs d'obrir i desar del Mac surten encara que la finestra no sigui la principal.
- Les notes per al revisor expliquen el recanvi i demanen que ens truquin abans de decidir.

Passos (fets el 7 d'octubre a les 14:43: les dues compilacions 7 pujades, l'iPhone enviat amb els cinc paquets i el Mac amb la compilació sola, tots dos "Pendiente de revisión"; els paquets no es podien afegir al Mac mentre eren en revisió amb l'iPhone):
1. ✅ **Puja les dues compilacions 7** (`1 Apps`: `duna-iPhone.ipa` i `duna-Mac.pkg`), amb Transporter o des de l'Organizer de Xcode. Els paquets d'idioma no canvien: són els mateixos cinc que ja tens a App Store Connect.
2. ✅ **iPhone:** la compilació 6 encara és en revisió. A App Store Connect › iOS › versió 1.0, treu-la de revisió (*Remove from Review*), tria la compilació 7, enganxa les notes noves de `APP-STORE-FITXA.md` (apartat Notes) i torna a enviar.
3. ✅ **Mac:** a macOS › versió 1.0, tria la compilació 7, enganxa les mateixes notes, comprova que a *Asset Packs* hi ha els cinc paquets, i envia. No cal respondre el missatge del rebuig: enviar una compilació nova ja és la resposta.
4. 👤 **Abans d'enviar, prova la 7 a TestFlight al Mac** (10 minuts): esborra `/Applications/duna.app`, instal·la duna des de TestFlight, baixa l'anglès i parla. Si la baixada d'Apple falla, l'app passa sola al recanvi: has de veure la barra reprendre des de zero i acabar.

---

## Què ja està fet

- ✅ **Nom nou.** L'app es diu **duna** (en minúscules) a tot arreu:
  - sota la icona, als menús, als textos de l'app en cinc idiomes, al permís del micròfon i al menú Compartir;
  - l'identificador és `com.uriocallaghan.duna`, i el grup d'apps és `group.com.uriocallaghan.duna`.
- ✅ **Web legal publicada**, en català, castellà i anglès, amb l'estil de Norah Studio:
  - inici;
  - política de privacitat;
  - condicions d'ús, amb l'EULA estàndard d'Apple i les clàusules que Apple exigeix;
  - avís legal (LSSI);
  - suport, amb preguntes freqüents.

  Avui és a `https://duna-uriocallaghan.netlify.app`. Passa a `duna.uriocallaghan.com` quan facis el pas 1.
- ✅ **Enllaços a la web dins l'app.** A l'iPhone són a Informació (privacitat, condicions, suport). Al Mac són al menú Ajuda. La finestra "Sobre l'app duna" del Mac té els crèdits i les llicències de tots els models.
- ✅ **Correccions per evitar rebuigs**, trobades revisant el codi:
  - l'app d'iPhone es construïa també com a app d'iPad només vertical, cosa que Apple rebutja. Ara és només d'iPhone (a l'iPad funciona en mode de compatibilitat).
  - el manifest de privacitat no declarava dos usos d'API que Apple revisa (rellotge del sistema i dates de fitxers). Ara sí, també a l'extensió de compartir.
  - el botó abans del permís del micròfon deia "Dona accés al micròfon". Apple demana un text neutre, i ara diu "Continua".
  - el codi privat d'AppKit que arrodoneix la finestra ja no entra a la versió del Mac App Store.
  - "duna" al menú Compartir ara només surt per a vídeos i àudios. Abans sortia per a qualsevol fitxer, i amb un PDF fallava.
  - s'ha afegit el permís de memòria ampliada a l'iPhone, perquè els models tinguin marge en telèfons de 6 GB.
- ✅ **Segona auditoria (30 de setembre, tarda).** Tres revisions independents (paquets, traduccions i normes d'Apple), més proves de la versió final a l'iPhone, a l'iPad i al Mac. Correccions:
  - **error greu:** a la versió final, l'app deia "English ready ✓" sense haver baixat res. Ara pregunta al sistema si el paquet hi és de debò i comprova el fitxer del model;
  - **bloqueig al Mac:** si la baixada fallava després de donar el micròfon, no hi havia cap botó per sortir-ne. Ara, a l'iPhone i al Mac, surten "Torna-ho a provar" i "Continua sense idioma". Si la baixada s'encalla, apareixen al cap de 20 segons;
  - l'etiqueta "Beta" del gallec i el basc ara és **"Nou"** (New, Nuevo, Novo, Berria), a l'app, a la web i a la fitxa;
  - l'extensió de compartir de l'iPhone ja no obre l'app amb una tècnica no documentada. Desa el vídeo i diu "Desat. Obre duna per fer-ne els subtítols", i duna el recull quan l'obres;
  - l'extensió de compartir del Mac no tenia perfil de signatura, i TestFlight hauria refusat la compilació del Mac. Ara el té;
  - el nom en anglès passa a ser "duna: live transcription", perquè "Live Captions" és el nom d'una funció d'Apple;
  - la fitxa ja no diu "sense connexió" sense matisos (primer cal baixar l'idioma), i les notes per al revisor expliquen què fer si la baixada falla i demanen que ens contactin abans de rebutjar.
  - He comprovat que res bloqueja la validació automàtica: icones, versions, signatures, sandbox, manifests de privacitat, traduccions (cap text en català per al revisor anglès) i cap API privada.
- ✅ **Error corregit: paraules repetides al final d'una frase.** Quan algú acabava de parlar, el castellà i l'anglès podien repetir l'última paraula ("para para todos", "along? Along?"). Ara no passa.
  - He comprovat que la correcció no canvia res més. Les transcripcions de 87 clips del Parlament en català, de 60 frases en castellà i de 60 en anglès surten idèntiques, paraula per paraula.
- ✅ **Proves i instal·lació:**
  - les proves de l'app passen;
  - l'app de Mac és instal·lada a `/Applications/duna.app`. L'antiga "Subtítol Live" s'ha enviat a la Paperera;
  - l'app d'iPhone funciona al simulador i transcriu de veritat.
- ✅ **Fitxa de l'App Store** en anglès, català i castellà: noms, descripcions, paraules clau, notes per al revisor, edat i privacitat.
- ✅ **Captures**, fetes amb l'app real transcrivint una veu sintètica:
  - iPhone 6,9": 6 en anglès, 6 en castellà i 5 en català;
  - Mac (2880 × 1800): 4 per idioma.
- ✅ **Apps compilades i signades per a l'App Store** (versió 1.0, compilació 1):
  - l'iPhone, signada amb el teu certificat de distribució, només per a iPhone, amb els permisos correctes i sense cap idioma de proves a dins;
  - el Mac, en sandbox, amb hardened runtime, sense codi privat, i amb el paquet signat amb el certificat d'instal·lador de Mac.
  - Aquest Mac ja és registrat al teu compte, i Xcode ha creat els identificadors i els perfils.
  - Els arxius també són a l'Organizer de Xcode, per si hi prefereixes pujar-los.
- ✅ **Els cinc paquets d'idioma** (`lang-ca/es/en/gl/eu.aar`), per a iOS i macOS, amb baixada a demanda.

---

## Els teus passos

### 1. 👤 Apunta el domini de la web (2 minuts)
Entra a **Hostinger › Dominis › uriocallaghan.com › DNS** i afegeix aquest registre:

| Tipus | Nom | Apunta a | TTL |
|---|---|---|---|
| CNAME | `duna` | `duna-uriocallaghan.netlify.app` | per defecte |

És el mateix que vas fer per a `norahstudio`. En uns minuts, Netlify posarà el certificat HTTPS sol.

✅ Ja funciona. Comprova-ho obrint https://duna.uriocallaghan.com/privacitat. Fes-ho **abans** d'enviar l'app a revisió: el revisor obrirà aquests enllaços.

### 2. 👤 Crea la fitxa a App Store Connect
1. Obre [appstoreconnect.apple.com](https://appstoreconnect.apple.com) › **Apps** › **+** › **New App**.
2. Omple el formulari:
   - **Platforms:** marca **iOS** i **macOS**, les dues. Així és una sola fitxa i una compra universal.
   - **Name:** `duna: live transcription`
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** `com.uriocallaghan.duna`. Surt a la llista quan Xcode l'ha registrat, i ja ho ha fet en compilar.
   - **SKU:** `duna`
   - **User Access:** Full Access
3. A **App Information**:
   - afegeix les localitzacions **Catalan** i **Spanish (Spain)**;
   - posa la categoria **Utilities** (secundària: **Productivity**);
   - omple **Content Rights** i **Age Rating** com diu la fitxa.
4. A **App Privacy**:
   - enganxa l'URL de privacitat;
   - respon "No, we do not collect data";
   - prem **Publish**.
5. A **Pricing and Availability**, posa **Free**, a tots els països.
6. **Estatus de comerciant (DSA de la UE):** és del compte, no de l'app. Si ja el vas declarar per a Norah Studio, no cal fer res.

### 3. 👤 Puja les apps i els idiomes amb Transporter
1. Instal·la **Transporter** des de l'App Store del Mac i entra amb el teu compte de desenvolupador.
2. Des de la carpeta `duna - per pujar` de l'Escriptori, arrossega a la finestra de Transporter:
   - els dos fitxers de `1 Apps`;
   - els cinc fitxers de `2 Idiomes`.
3. Prem **Deliver** a cadascun. Si et pregunta a quina app van els idiomes, tria **duna**.
4. Espera els correus d'Apple. Per a cada idioma arriba un "processing complete".
5. A App Store Connect › duna, comprova:
   - que a **Asset Packs** els cinc paquets surten com a *Ready for Internal Testing*;
   - que a **TestFlight** surten les dues compilacions (iOS i macOS).

(Alternativa per a les apps: Xcode › Window › Organizer › tria l'arxiu "duna iPhone" o "duna Mac" › **Distribute App** › App Store Connect.)

### 4. 👤 Prova-ho amb TestFlight abans d'enviar (molt recomanat)
Aquest pas és el que evita el rebuig més probable: que l'idioma no es baixi.

1. A **TestFlight**, afegeix-te com a provador intern.
2. Al teu iPhone, instal·la duna des de l'app TestFlight i fes el que farà el revisor:
   - sense cap idioma instal·lat, baixa l'anglès;
   - dona el permís del micròfon;
   - parla.
3. Al Mac, fes el mateix. Abans:
   - arrossega `/Applications/duna.app` (la versió local que hem anat provant) a la Paperera, perquè la de TestFlight s'instal·la al mateix lloc;
   - reinicia el Mac: Apple diu que una còpia antiga pot bloquejar la baixada dels idiomes.

Si l'idioma no es baixa a TestFlight, **no enviïs l'app**: avisa'm.

### 5. 👤 Omple la versió 1.0 i envia-la a revisió
Per a **iOS** i per a **macOS**, cadascuna a la seva pestanya:

1. Enganxa els textos de la fitxa: descripció, paraules clau, text promocional i URL de suport i de màrqueting. Afegeix les versions en català i castellà.
2. Puja les captures des de `3 Captures`, en l'ordre dels números:
   - iPhone, a la mida "6.9-inch Display": carpeta `iPhone 6,9/en`, `ca` o `es`, segons l'idioma de la fitxa;
   - Mac: carpeta `Mac/en`, `ca` o `es`.
3. A **Build**, tria la que has pujat.
4. A **App Review Information**:
   - desmarca *Sign-in required*;
   - posa el teu nom, telèfon i correu;
   - enganxa les notes en anglès de la fitxa, amb el teu telèfon on diu `+34 XXX XXX XXX`.
5. A **Copyright**, escriu `2026 Oriol O'Callaghan`.
6. A **Asset Packs** › **Select Asset Pack Version**, afegeix els **cinc paquets** a l'enviament. Apple exigeix que la primera versió de l'app porti els paquets al mateix enviament. Si no hi van, el revisor no podrà baixar cap idioma.
7. Prem **Add for Review** i després **Submit for Review**.

Apple revisa l'iPhone i el Mac per separat. Si al Mac no et deixa tornar a triar els paquets perquè ja van amb l'iPhone, envia'l igualment: comparteixen els paquets.

**Publicació:** tria "Manually release this version" si vols decidir tu el dia, o "Automatically" perquè surti tan bon punt l'aprovin.

---

## Riscos que queden, i què fer-hi

- **Que el revisor no pugui baixar l'idioma.** Als fòrums d'Apple d'aquest estiu hi ha casos, sobretot al Mac.
  - Com ho reduïm:
    - la prova a TestFlight del pas 4;
    - els paquets inclosos a l'enviament;
    - les notes, que expliquen exactament què ha de fer el revisor.
  - Si tot i així la rebutgen per això, la solució ràpida és posar l'anglès dins l'app. Són unes hores de feina i tornar-la a enviar.
- **Números en castellà amb una veu sintètica.** Amb la veu sintètica del Mac, a "antes del quince de octubre" el número es va perdre ("antes del de octubre").
  - El model l'escolta a la majoria de finestres, però no a les primeres, i l'app ja havia fixat el text.
  - Amb veu humana no ho he vist passar: en 60 frases de prova en castellà no s'ha perdut cap número.
  - Val la pena que ho provis amb la teva veu en castellà dient dates. Si et passa, és el primer que s'ha de millorar a la versió 1.0.1.
- **El simulador d'iPhone, més lent que un iPhone real,** de vegades parteix un paràgraf enmig d'una frase o s'inventa una paraula al silenci final. Al Mac, que com l'iPhone fa servir la GPU, les mateixes frases surten netes. En un iPhone real no ho he pogut provar (no estava connectat). Mira-ho a TestFlight (pas 4).
- **Textos en gallec i basc.** Encara no els ha revisat cap persona nativa. No és motiu de rebuig, però convé fer-ho aviat.
