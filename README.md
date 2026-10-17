<div align="center">

<img src="assets/hero.jpg" alt="Subtítol Live transcrivint català en directe" width="100%">

# Subtítol Live

**Subtítols en català, en directe, al teu Mac. Sense núvol.**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-black)](#requisits)
[![Llicència MIT](https://img.shields.io/badge/llic%C3%A8ncia-MIT-orange)](LICENSE)
[![Model BSC · Aina](https://img.shields.io/badge/model-BSC%20%C2%B7%20Projecte%20Aina-blue)](docs/EL-MODEL.md)

</div>

---

Subtítol Live escolta català pel micròfon i el converteix en text llegible mentre passa.
Tot el processament és local: el model viu dins l'app i la veu no surt mai de l'ordinador.

No és un bolcat brut de reconeixement de veu. És un **editor en directe**: el model proposa,
l'app decideix què és prou estable perquè el lector el llegeixi. Les paraules que ja has llegit
no es mouen; com a molt, les tres últimes encara poden canviar.

Aquest projecte és una **prova del potencial del català en la nova era de productes amb IA**:
el cervell el va entrenar el Barcelona Supercomputing Center (Projecte Aina, MareNostrum 5)
i el producte demostra que es pot convertir en una experiència real, privada i ben dissenyada.

## Descarrega i prova (2 minuts)

Requisits: **macOS 14 o superior, Apple Silicon** i un micròfon.

1. Baixa **`Subtitol-Live.dmg`** de l'[últim release](../../releases/latest) (~0,3 GB, el model ja va inclòs).
2. Arrossega **Subtítol Live** a Aplicacions.
3. La primera vegada, macOS avisarà que l'app no està notaritzada (va signada ad-hoc).
   A macOS 14, obre-la amb **clic dret → Obrir**. Des de macOS 15, permet-la a
   **Configuració del Sistema › Privadesa i seguretat**. També pots executar:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Subtítol Live.app"
   ```

4. Dóna permís de micròfon, prem **espai** o fes clic, i parla en català.

## Compila des de la font

```sh
git clone https://github.com/uriocallaghan/subtitols-catala-en-directe.git
cd subtitols-catala-en-directe

# 1. Baixa els models de veu i de puntuació (~0,2 GB, verificats per SHA256)
./scripts/download-model.sh

# 2. Executa des de SwiftPM (el runtime ja ve vendorat a SubtitolLive/Vendor)
cd SubtitolLive
SUBTITOL_MODELS_DIR="$PWD/../models" swift run -c release SubtitolLive

# …o genera i instal·la el .app a /Applications
./scripts/build-app.sh
```

Tests:

```sh
xcrun swift run -c debug SubtitolLiveTests
```

## Com funciona

```
veu → cinta de 7 s → Conformer català d'Aina al Mac (Metal)
                                        ↓
                              esborrany de paraules
                                        ↓
                   editor: bloqueja el que és estable,
                   deixa ≤3 paraules vives a la cua
                                        ↓
              puntuació, majúscules, xifres i salts de línia
                                        ↓
                  paper (roll-up)  |  camp decoratiu
```

Tres perfils de lectura — **Fiable / Equilibrat / Immediat** — regulen la calma contra la
rapidesa. I tres maneres de mirar-lo: tema fosc, paper a tota l'amplada, degradat per antiguitat.

<img src="assets/features.jpg" alt="Subtítol Live: tema fosc, mode ample i degradat per antiguitat" width="100%">

Documentació completa:

- [El producte, en paraules senzilles](docs/EL-PRODUCTE.md) — comença per aquí.
- [Com funciona](docs/COM-FUNCIONA.md) — el producte explicat sense codi.
- [El model i la tecnologia](docs/EL-MODEL.md) — NVIDIA → BSC/Aina → GGUF al Mac, i per què és el Conformer.
- [Verificació de latència](docs/LATENCY.md) — harness de mesura i objectius.
- [Fiabilitat i diagnòstic](docs/RELIABILITY.md) — captures de sessió opt-in.
- [Puntuació i normalització](docs/PUNTUACIO-I-NORMALITZACIO.md) — la investigació del model de puntuació propi.

## Tecnologia

| Capa | Què és |
|---|---|
| App | SwiftUI · macOS 14+ · arquitectura modular (`SubtitolCore`, `SubtitolEngine`) |
| Model | Conformer-Transducer català i castellà del BSC (Projecte Aina) → GGUF Q8_0 (131 MB) |
| Runtime | NeMo-Speech.cpp (NVIDIA) + ggml amb Metal — vendorat a `SubtitolLive/Vendor` |
| Privacitat | Zero xarxa. L'àudio viu en un buffer de 7 s en memòria i no es desa |

## Limitacions conegudes

- Sense detecció de veu (VAD): el producte decideix deliberadament no tallar silencis encara.
- El model de veu va aprendre català i castellà alhora: amb àudio molt difícil, de tant en tant
  escriu alguna paraula en castellà.
- L'app es distribueix signada ad-hoc, sense notarització d'Apple.

## Crèdits i llicència

Codi sota **MIT** © Uri O'Callaghan. El model i el runtime tenen llicències pròpies
(Conformer d'Aina CC-BY-4.0, model de puntuació Apache-2.0, Inter OFL) — atribucions completes a
[NOTICE.md](NOTICE.md).
