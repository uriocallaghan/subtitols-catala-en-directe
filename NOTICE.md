# Atribucions

Subtítol Live combina components de tercers. Aquest fitxer recull les
atribucions exigides per les seves llicències.

## Model de veu

- **Conformer-Transducer català i castellà** (`catalan-conformer-q8.gguf`) —
  `stt_ca-es_conformer_transducer_large`, Language Technologies Unit del
  Barcelona Supercomputing Center (Abir Messaoudi, Baybars Külebi), dins del
  **Projecte Aina** (Generalitat de Catalunya), finançat pel projecte **ILENIA**,
  amb còmput de **MareNostrum 5**. Afinat amb 7.426 hores de català i castellà.
  Llicència **CC-BY-4.0**.
  <https://huggingface.co/projecte-aina/stt_ca-es_conformer_transducer_large>
- **Model de base** — `nvidia/stt_es_conformer_transducer_large`, NVIDIA.
  Llicència **CC-BY-4.0**.
  <https://huggingface.co/nvidia/stt_es_conformer_transducer_large>
- La conversió a GGUF Q8_0 la fem nosaltres amb NeMo-Speech.cpp i els pedaços de
  `SubtitolLive/Vendor/Runtime/patches`, i es distribueix com a asset del release.
  Els pesos no es modifiquen: només canvia el format i la precisió numèrica.

## Models de veu dels altres idiomes

Cada idioma es baixa a part, com a paquet allotjat per Apple. Les conversions a
GGUF Q8_0 les fem nosaltres amb la mateixa recepta que el català (comandes i
SHA-256 a `ModelManifest.json`); els pesos no es modifiquen.

- **Castellà** (`spanish-fastconformer-q8.gguf`) —
  `nvidia/stt_es_fastconformer_hybrid_large_pc`, NVIDIA. Llicència **CC-BY-4.0**.
  <https://huggingface.co/nvidia/stt_es_fastconformer_hybrid_large_pc>
- **Anglès** (`english-fastconformer-q8.gguf`) —
  `nvidia/stt_en_fastconformer_hybrid_large_pc`, NVIDIA. Llicència **CC-BY-4.0**.
  <https://huggingface.co/nvidia/stt_en_fastconformer_hybrid_large_pc>
  En tots dos s'omet el capçal CTC auxiliar, que el descodificador RNNT no fa servir.
- **Gallec** (`galician-los-q8.gguf`) —
  `BSC-LT/stt_los_conformer_transducer_large_punctuated`, Language Technologies
  Unit del Barcelona Supercomputing Center (Abir Messaoudi, Sarah Solito, Carlos
  Hernández Mena, Cristina España-Bonet). Llicència **Apache-2.0**.
  <https://huggingface.co/BSC-LT/stt_los_conformer_transducer_large_punctuated>
- **Basc** (`basque-conformer-q8.gguf`) —
  `HiTZ/stt_eu_conformer_transducer_large_v2`, HiTZ (Centre Basc de Tecnologia
  de la Llengua, UPV/EHU). Llicència **Apache-2.0**.
  <https://huggingface.co/HiTZ/stt_eu_conformer_transducer_large_v2>

## Model de puntuació i majúscules

- **Model de puntuació català** (`catala-puntuacio`) — entrenat per nosaltres a
  partir de **`projecte-aina/distilroberta-base-ca-v2`** (Projecte Aina, BSC),
  llicència **Apache-2.0**
  <https://huggingface.co/projecte-aina/distilroberta-base-ca-v2>. Dades
  d'entrenament de domini públic (**CC0**): les frases catalanes de **Mozilla
  Common Voice** i les transcripcions del Parlament de Catalunya i de les Corts
  Valencianes recollides a **CATalog** (Projecte Aina). Convertit a Core ML i
  comprimit a 6 bits.

- **Model de puntuació basc** (`euskara-puntuacio`) — entrenat per nosaltres a
  partir de **`HiTZ/BERnaT-medium`** (HiTZ, UPV/EHU), llicència **Apache-2.0**
  <https://huggingface.co/HiTZ/BERnaT-medium>. Dades d'entrenament:
  **ParlaMint-ES-PV 5.0** (Erjavec et al., CLARIN.SI, hdl 11356/2004), llicència
  **CC BY 4.0**; les frases basques de **Mozilla Common Voice** (**CC0**); i, del
  corpus **ZelaiHandi** (orai-nlp), només els documents de domini públic (diaris
  del Parlament Basc) i els subtítols en basc d'**Open Data Euskadi**
  ("Euskarazko azpitituluak", **CC BY 4.0**). Convertit a Core ML i comprimit a 6 bits.

## Detector de canvis de veu

- **pyannote segmentation-3.0** (`veus-segmentacio`) — CNRS (Hervé Bredin i
  col·laboradors, projecte pyannote.audio). Llicència **MIT**; el text de la
  llicència viatja amb el model dins l'app.
  <https://huggingface.co/pyannote/segmentation-3.0>. Els pesos s'agafen de
  l'exportació ONNX `onnx-community/pyannote-segmentation-3.0` i els convertim
  nosaltres a Core ML amb `scripts/convert-speaker-model.py`, sense modificar-los.

## Runtime d'inferència

- **NeMo-Speech.cpp** — NVIDIA. Runtime natiu C++ amb Metal (ggml).
  Llicència **Apache-2.0**. <https://github.com/NVIDIA/NeMo-Speech.cpp>
  Els pedaços propis que hi apliquem (Conformer clàssic, taula de posicions
  calculada en carregar) són a `SubtitolLive/Vendor/Runtime/patches`.
- **ggml** — ggml-org. Llicència **MIT**.
  <https://github.com/ggml-org/ggml>
- **SentencePiece** — Google. Enllaçat estàticament dins del runtime.
  Llicència **Apache-2.0**. <https://github.com/google/sentencepiece>

## Tipografia

- **Inter** — Rasmus Andersson. Llicència **SIL Open Font License 1.1**.
  <https://rsms.me/inter/>
- **Atkinson Hyperlegible Next** — Braille Institute of America (disseny d'Applied
  Design Works). Llicència **SIL Open Font License 1.1**.
  <https://github.com/googlefonts/atkinson-hyperlegible-next>
- **Atkinson Hyperlegible Mono** — Braille Institute of America (disseny d'Applied
  Design Works). Llicència **SIL Open Font License 1.1**.
  <https://github.com/googlefonts/atkinson-hyperlegible-next-mono>

Braille Institute i Atkinson Hyperlegible són marques de Braille Institute of
America, Inc., registrades als Estats Units; aquesta app no n'és afiliada ni avalada.

**SF Pro** és la font del sistema de macOS: l'app la demana al sistema i no n'inclou
cap fitxer.

Els textos de les llicències viatgen amb l'app a `Contents/Resources/Fonts/OFL-*.txt`.
