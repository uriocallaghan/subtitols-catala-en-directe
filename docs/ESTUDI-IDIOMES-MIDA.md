# Estudi: com fer que l'idioma funcioni sempre sense inflar l'app

7 d'octubre de 2026. Arran del rebuig de la versió de Mac (compilació 6): "no hem pogut fer servir la funció principal, triar un idioma, perquè l'app mostra un error i torna-ho a provar".

## Què va passar

El revisor, en un MacBook Pro amb macOS 27.2 i internet, va intentar baixar l'anglès i la baixada va fallar. L'app agafa els idiomes com a *paquets allotjats per Apple* (Background Assets): el sistema d'Apple els baixa de l'App Store. Als fòrums de desenvolupadors d'Apple hi ha un fil (815174) amb el mateix problema des del febrer: apps que funcionen a TestFlight i als usuaris, però on l'entorn de revisió no pot baixar els paquets, sobretot al Mac. Un enginyer d'Apple hi diu que la revisió desactiva les baixades prèvies i que les baixades sota demanda haurien d'anar; diversos desenvolupadors diuen que al Mac tampoc no van.

Dues preguntes que només tu pots respondre, i que canvien el diagnòstic:

1. Vas provar la versió de Mac a TestFlight i l'anglès es va baixar bé?
2. En enviar el Mac a revisió, l'apartat *Asset Packs* portava els cinc paquets? (Al pas 6 de PUBLICAR deia "si no et deixa triar-los, envia'l igualment".) Si el Mac va anar sense paquets, el revisor va rebre "not found" i la causa és aquesta, no la xarxa.

## Per què no hi ha un model petit que funcioni "perfecte"

He mirat els models oberts de reconeixement en temps real que han sortit el 2025 i 2026. La qualitat va lligada a la mida: a uns 110–130 milions de paràmetres (uns 120 MB al disc) és on comença la qualitat bona en un sol idioma; per sota, els errors pugen de pressa.

| Model (anglès) | Llicència | Mida al disc | Errors (mitjana de 8 proves estàndard) |
|---|---|---|---|
| Moonshine Streaming Tiny | MIT | ~35 MB | 12,0 % |
| Moonshine Streaming Small | MIT | ~125 MB | 7,8 % |
| Moonshine Streaming Medium | MIT | ~250 MB | 6,7 % |
| **El nostre (NVIDIA FastConformer)** | CC BY 4.0 | 123 MB | 4,7 % a FLEURS (prova diferent; mida igual que Small) |

| Model (castellà) | Llicència | Mida | Errors a FLEURS |
|---|---|---|---|
| Moonshine Streaming Tiny ES | MIT | ~30 MB | no publicat (un quart del Small) |
| Moonshine Streaming Small ES | MIT | ~115 MB | 4,9 % |
| **El nostre (NVIDIA FastConformer)** | CC BY 4.0 | 123 MB | 4,1 % |

Conclusió: Moonshine, el candidat més seriós (MIT en tots els idiomes en les versions streaming), a la mida bona pesa el mateix que el que ja tenim i no ho fa millor. Les versions petites (30–35 MB) fan dos o tres cops més errors: no és "perfecte", i a més vol un segon motor dins l'app (setmanes de feina). Per al català, gallec i basc no hi ha res més petit que el que ja portem.

Comprimir més els nostres: a la meitat de mida (4 bits), el català va passar de 2 paraules diferents a 23 sobre 1.665, amb errors a la teva veu. Descartat.

**El reconeixedor d'Apple (iOS 26 i macOS 26).** Pesa 0 MB dins l'app, va bé en anglès i castellà, però el model de l'idioma també l'ha de baixar el sistema la primera vegada (no està garantit que l'entorn de revisió el tingui), no té català, gallec ni basc, i és un motor diferent que s'hauria d'integrar amb tota la cadena de puntuació i lectura estable. És una opció de futur per a anglès i castellà, no per a aquesta revisió.

## Les opcions

| | Mida de l'app | Funciona el primer cop sense xarxa | Risc a la revisió | Feina |
|---|---|---|---|---|
| A. Res dins l'app; paquets d'Apple + còpia a GitHub si Apple falla | 10 MB | No | Baix si GitHub és accessible des de la revisió; un desenvolupador diu que al Mac el seu recanvi tampoc no va anar | Feta |
| **B. L'anglès dins l'app; la resta com A** | ~135 MB | Sí (anglès) | Gairebé nul: el revisor prova l'anglès, que ja hi és | Feta |
| C. Tots els idiomes dins (Mac) | ~730 MB | Sí | Nul | Descartada per mida |
| D. Un anglès petit (Moonshine Tiny) dins l'app | ~45 MB | Sí, pitjor | Baix, però el revisor veu més errors | Setmanes (segon motor) |
| E. Reconeixedor d'Apple per a anglès i castellà | 10 MB | No (el sistema baixa el model) | Mitjà | Setmanes |

El que hi ha ara a l'app, a tots dos aparells, és la B: l'anglès a dins (124 MB), i els altres quatre idiomes com a paquets d'Apple amb la còpia de GitHub al darrere. Si l'App Store no serveix un paquet, l'app baixa el mateix fitxer de GitHub, en comprova la suma i l'instal·la. L'anglès que ve a dins no es pot esborrar, i la pantalla d'idiomes el marca com a "Inclòs".

Canviar d'opció és una línia (la llista d'idiomes de la fase "Bundle languages" de `project.yml` i de `build-app.sh`): amb la llista buida tornem a l'opció A.

## Decisió (7 d'octubre, tarda)

El fundador tria l'opció A: cap model dins l'app, paquets d'Apple i la còpia de GitHub com a recanvi. L'opció B queda disponible amb la llista `BUNDLED_LANGUAGES` buida als scripts de construcció.

## Recomanació que es va fer

L'opció B. Un revisor que no pot baixar res continua podent fer servir la funció principal, i la resta d'idiomes tenen dues vies de baixada en comptes d'una. 135 MB és la mida normal d'una app amb un model de veu a dins (les apps de dictat amb Whisper van de 150 MB a 1,5 GB), i a l'iPhone queda per sota dels 200 MB a partir dels quals l'App Store demana Wi-Fi.

Si prefereixes l'app de 10 MB (opció A), es pot enviar igualment: el codi del recanvi de GitHub hi és i el risc que queda és només que la revisió no pugui arribar a GitHub.

## Fonts

- Fil dels fòrums d'Apple sobre paquets a la revisió: https://developer.apple.com/forums/thread/815174
- Moonshine (mides, errors, llicència): https://huggingface.co/moonshine-ai/moonshine-streaming-small · https://huggingface.co/moonshine-ai/moonshine-streaming-small-es · https://moonshine-voice.readthedocs.io/en/latest/license/
- Reconeixedor d'Apple: idiomes admesos a `SpeechTranscriber.supportedLocales` (anglès, castellà, francès, alemany, italià, portuguès, japonès, coreà, xinès…; sense català, gallec ni basc) i baixada del model pel sistema (`AssetInventory`).
- Els nostres números: `SubtitolLive/Sources/SubtitolLive/Resources/ModelManifest.json` (apartat `evaluation` de cada model).
