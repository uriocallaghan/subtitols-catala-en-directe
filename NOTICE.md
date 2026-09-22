# Atribucions

Subtítol Live combina components de tercers. Aquest fitxer recull les
atribucions exigides per les seves llicències.

## Model de veu

- **Parakeet RNNT 1.1B** — NVIDIA i Suno.ai. Arquitectura i pesos de base,
  entrenats amb ~64.000 hores d'anglès. Llicència **CC-BY-4.0**.
  <https://huggingface.co/nvidia/parakeet-rnnt-1.1b>
- **Adaptació catalana** — Language Technologies Laboratory, Barcelona
  Supercomputing Center (BSC-CNS), dins del **Projecte Aina** (Generalitat de
  Catalunya), amb còmput de **MareNostrum 5** (EuroHPC). Fine-tuning amb
  ~1.800 hores de català (Mozilla Common Voice 17, 3CatParla, Corts
  Valencianes). Llicència **Apache-2.0**.
  <https://huggingface.co/BSC-LT/catalan-verification-model-pkt-b>
- La conversió a GGUF Q8 (`catalan-parakeet-q8.gguf`) es distribueix com a
  asset del release, derivada dels checkpoints anteriors.

## Runtime d'inferència

- **NeMo-Speech.cpp** — NVIDIA. Runtime natiu C++ amb Metal (ggml).
  Llicència **Apache-2.0**. <https://github.com/NVIDIA/NeMo-Speech.cpp>
- **ggml** — ggml-org. Llicència **MIT**.
  <https://github.com/ggml-org/ggml>
- **SentencePiece** — Google. Enllaçat estàticament dins del runtime.
  Llicència **Apache-2.0**. <https://github.com/google/sentencepiece>

## Tipografia

- **Inter** — Rasmus Andersson. Llicència **SIL Open Font License 1.1**.
  <https://rsms.me/inter/>
