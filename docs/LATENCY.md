# Verificació de latència

`SubtitolLatencyHarness` reprodueix el mateix PCM amb les dues polítiques:

- baseline: timer de 350 ms i finestra de 6 s;
- nova: perfil seleccionable (`reliable`, `balanced` o `immediate`), latest-wins,
  context fix de 7 s (el del Conformer), evidència i histèresi pròpies del perfil, i cua visible
  màxima de 3 paraules.

El harness escalfa 7 s i mesura snapshot, inferència, CPU de procés, paraula
acabada fins al següent frame i paraula estabilitzada fins al frame. També
compta mutacions del prefix estable, revisions de la cua i la seva mida màxima.
L'app mesura en viu captura→snapshot, inferència, cua MainActor, P95 de paraula
i discontinuïtats del sample clock (`drop`). Instruments o `powermetrics` són
necessaris per obtenir un percentatge fiable d'ocupació GPU.

```sh
xcrun swift run -c release SubtitolLatencyHarness \
  ../models/catalan-conformer-q8.gguf \
  /ruta/corpus-catala.wav \
  --profile reliable \
  --reference-file /ruta/corpus-catala.txt \
  --max-seconds 6 \
  --refresh-hz 60 \
  --enforce
```

Amb `--enforce`, el procés retorna codi 2 si es muta el prefix estable, la cua
supera 3 paraules, hi ha alternances visibles A/B/A en `reliable`, la latència P95
visible supera l'objectiu del perfil (1.200/800/500 ms), no es
redueix almenys un 30% el P50 i un 40% el P95 brut, o la WER provisional
empitjora més de 2 punts absoluts respecte de la correcció final de 7 s. Sense
`--enforce`, imprimeix avisos però permet usar àudio no català com a smoke test
mecànic.

La referència WER ha de descriure un únic segment de 6 s o menys (el límit del camí de referència). Per provar
parla contínua més llarga, executeu el harness sense referència i valideu WER
en un corpus segmentat per separat.

Per comparar dos models sobre la mateixa gravació:

- `--transcript-out FITXER` desa el text complet de la sessió, no només les
  últimes paraules que l'estabilitzador conserva en memòria.
- `--fixed-clock` avança sempre un hop, per lenta que vagi la inferència. Així
  tots dos models reben exactament les mateixes finestres, i la càrrega del Mac
  no pot fer perdre àudio a un i no a l'altre. Les latències que imprimeix ja no
  representen el directe.
- `--skip-baseline` omet la passada de referència de 350 ms / 6 s, que no cal
  per comparar models i doblava el temps d'execució.

La validació d'overruns a 44,1/48 kHz, aturada durant inferència, reinici ràpid
i una prova prolongada s'ha de fer amb l'app i un micròfon real; la injecció PCM
del harness és determinista i no pot provocar discontinuïtats de CoreAudio.
