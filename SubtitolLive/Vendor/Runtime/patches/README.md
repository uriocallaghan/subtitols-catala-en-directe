# Runtime patches

The dylibs in `Vendor/Runtime` are built from [NVIDIA NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp) at commit `4f9676226f667d14608487df744f375db87127f8`, with these patches applied in order:

1. `0001-apple-static-sentencepiece-build.patch`: links SentencePiece statically with hidden symbols on Apple and sets the macOS 14 deployment target for the `metal-asr` preset.
2. `0002-classic-conformer-and-runtime-pe.patch`:
   - **Classic Conformer.** Adds the `striding` subsampling front end (log2(factor) full Conv2d(k3, s2) + ReLU stages). It is selected by the GGUF key `asr.encoder.subsampling`. GGUFs without the key keep `dw_striding`, so existing FastConformer models load unchanged. The converter emits the key, maps `subsampling_conv_channels: -1` to `d_model`, and treats a null `conv_context_size` as symmetric.
   - **Exact mel filterbank.** The converter copies `preprocessor.featurizer.fb` from the checkpoint when present, instead of reconstructing it with librosa.
   - **Runtime positional encoding.** `convert_model.py --no-embed-pe` omits `encoder.pos_enc.pe`. The runtime then rebuilds the table at load time with NeMo's float32 recipe (20 MB less for a 512-wide model, 41 MB for a 1024-wide one).
3. `0003-static-asr-library-for-ios.patch`: lets the ASR library and its C API build as STATIC (`-DNEMO_SPEECH_ASR_LIBRARY_TYPE=STATIC`; SHARED stays the default), because an iPhone app cannot carry bare dylibs. `SubtitolLive/scripts/build-ios-runtime.sh` uses it to build `Vendor/RuntimeiOS/NemoSpeechRuntime.xcframework` (iPhone slice with Metal, simulator slice on the CPU).

4. `0004-rnnt-greedy-token-posterior.patch` (2026-10-14): the greedy RNNT decoder reports each word's confidence. The joint graph's argmax-only branch also emits, per frame, the posterior of the chosen token (softmax over the vocabulary, then a max-pool across the row: one float per frame, computed on the device beside the argmax), the batcher reads it as a second output, and the decoder gives each word the posterior of its least sure piece. Before, `nemo_speech_asr_result_word_confidence` answered 1.0 for every word. TDT models are unchanged.

To rebuild:

```bash
git clone https://github.com/NVIDIA/NeMo-Speech.cpp.git .work/NeMo-Speech.cpp
git -C .work/NeMo-Speech.cpp checkout 4f9676226f667d14608487df744f375db87127f8
for patch in SubtitolLive/Vendor/Runtime/patches/*.patch; do git -C .work/NeMo-Speech.cpp apply "$PWD/$patch"; done
cd SubtitolLive && ./scripts/build-app.sh
```

`build-app.sh` builds the runtime when `.work/NeMo-Speech.cpp` exists and copies the dylibs here.

## Verification of patch 0002 (2026-09-25)

- **Conformer parity.** `projecte-aina/stt_ca-es_conformer_transducer_large` in F16, against the FP32 ONNX export run with onnx-asr: 72 of 74 fragments identical, 6 of 1665 words differ.
- **Positional table.** Rebuilding the table at runtime, instead of embedding it, gives identical transcripts on all 74 fragments.
- **Parakeet.** The Q4_K model gives transcripts identical to the previous runtime on 45 FLEURS utterances, and `SubtitolEngineIntegrationTests` passes.
