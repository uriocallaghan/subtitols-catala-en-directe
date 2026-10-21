# Estat de l'art del reconeixement de veu en català (14 d'octubre de 2026)

Pregunta del fundador: hi ha models més bons que el nostre? Un 16% de WER en conversa
és dolentíssim?

## Resposta curta

- **El nostre model és el primer del rànquing públic de models de català** (Catalan
  ASR Arena, del BSC/Aina, 43 models, juliol de 2026): 3,48% de WER ponderat, per
  davant dels Whisper afinats pel mateix BSC (4,2%, 13 vegades més grans i 5 vegades
  més lents) i molt per davant de Whisper large-v3 (10,7%), Whisper turbo (12,9%),
  GPT-4o-transcribe (12,2%), omniASR de Meta (9,5–16%) i Gemma 4 (21%).
- **No hi ha cap model en temps real que el superi en català.** Els que s'hi acosten
  o el superen en parla llegida són models grans de tipus Whisper (1.550 M de
  paràmetres, no en directe, 3 GB) o APIs al núvol (ElevenLabs Scribe diu 3,1% a
  FLEURS; Deepgram no publica xifres de català).
- **El 16% no és "el model": és la conversa.** En parla llegida el nostre model fa
  3,8%; en un podcast ben gravat, 7,3%; en un podcast de conversa amb veus que
  s'interrompen (EMpodcat), 11,2% transcrivint el fitxer i 15–16% en directe amb
  finestra de 7 s. Uns 4 punts dels 16 són parla espontània que la referència neta
  no té ("sí sí", "hi ha hi ha", "val", "pues"). Whisper large-v3 sense afinar fa
  9,2% als mateixos episodis en mode fitxer, i els Whisper afinats del BSC
  probablement quedarien entre 7 i 9%: en conversa, un model gran amb més "llengua"
  dins guanya 2–4 punts, a canvi de no poder anar en directe ni cabre en un iPhone.

## El rànquing públic (Catalan ASR Arena, BSC-LT, juliol de 2026)

WER en %, ponderat sobre quatre conjunts; `RTFx` és la velocitat (vegades més ràpid
que el temps real, a la GPU del BSC). Selecció dels 43 models:

| # | Model | Mida | WER | FLEURS | Parlament v3 | Corts | CV accents | RTFx |
|---|---|---|---|---|---|---|---|---|
| 1 | **projecte-aina/stt_ca-es_conformer_transducer_large** (el nostre) | 120 M | **3,48** | 3,77 | 4,25 | 6,07 | 2,55 | 44 |
| 2 | BSC-LT/whisper-bsc-large-v3-cat | 1.550 M | 4,17 | 3,59 | 4,58 | 7,38 | 3,41 | 9 |
| 3 | BSC-LT/whisper-3cat-balearic | 1.550 M | 4,37 | 3,59 | 4,71 | 7,52 | 3,68 | 8 |
| 5 | BSC-LT/whisper-large-v3-LoS-punctuated | 1.550 M | 5,31 | 4,41 | 5,68 | 11,64 | 4,06 | 9 |
| 9 | BSC-LT/whisper-large-v3-ca-punctuated-3370h | 1.550 M | 6,12 | 3,16 | 9,04 | 15,70 | 2,89 | 8 |
| 12 | BSC-LT/stt_los_conformer_transducer_large (el del gallec) | 120 M | 7,54 | 8,10 | 7,04 | 12,78 | 6,91 | 15 |
| 15 | nvidia/stt_ca_conformer_transducer_large | 120 M | 8,58 | 5,29 | 14,13 | 25,00 | 2,63 | 64 |
| 16 | microsoft/mai-transcribe-1.5 | ? | 8,65 | 2,78 | 8,77 | 16,76 | 7,53 | 7 |
| 18 | facebook/omniASR-LLM-7B | 7.801 M | 9,46 | 5,63 | 11,19 | 29,64 | 5,19 | 10 |
| 20 | BSC-LT/ConMamba-small-ca | 13 M | 10,18 | 8,43 | 8,07 | 13,05 | 11,05 | 15 |
| 21 | openai/whisper-large-v3 | 1.550 M | 10,72 | 4,40 | 8,95 | 18,10 | 10,89 | 11 |
| 26 | openai/gpt-4o-transcribe | API | 12,23 | 2,39 | 11,24 | 22,21 | 11,67 | 8 |
| 29 | openai/whisper-large-v3-turbo | 809 M | 12,91 | 4,65 | 8,95 | 19,25 | 14,68 | 38 |
| 37 | google/gemma-4-E4B-it | 7.996 M | 21,22 | 10,97 | 20,14 | 32,22 | 20,56 | 7 |

Dues precaucions amb aquesta taula:

- Parlament v3, Corts i Common Voice són **dins de les dades d'entrenament** dels
  models del BSC (el nostre inclòs). Només FLEURS (parla llegida, Wikipedia) és net per
  a tothom, i allà les diferències són petites: 3,8 nostre, 3,6 Whisper BSC, 4,4
  Whisper large-v3, 2,4 GPT-4o.
- Cap conjunt del rànquing és conversa. **A conversa, el nostre model perd avantatge**:
  als cinc episodis segellats d'EMpodcat (53.500 paraules, mai usats per ajustar res),
  Whisper large-v3-turbo sense afinar fa 9,2% i el nostre 11,2% (mode fitxer, 2026-09-30).

## Què hi ha a cada família

**Conformer-Transducer (el que fem servir).** 120 M, en directe, cap a un iPhone. El
nostre (ca-es, 7.426 h) és el millor de la família. El "LoS" de quatre llengües
(febrer de 2026, el que fem servir per al gallec) és pitjor en català (7,5%). NVIDIA
té un Conformer català propi (8,6%). Cap model nou d'aquesta família en 2026.

**Whisper afinat pel BSC.** 1.550 M (3 GB en FP16, ~1,6 GB en 8 bits), fins a 4.700 h de
català. És el que més s'acosta i a conversa probablement el superaria. Però és un
model de lots: transcriu trossos de fins a 30 s, no té sortida incremental, i el
flux "en directe" s'imita tornant a transcriure cada pocs segons (3–8 s de retard).
Al Mac M3 pot anar 3–5 vegades més ràpid que el temps real amb WhisperKit o MLX; a
un iPhone 16 va al voltant del temps real i escalfa; no hi ha versió "turbo" afinada
en català, i la turbo genèrica és pitjor que el nostre (12,9%). Llicència Apache 2.0.

**Models nous de 2026.** ConMamba-small-ca (BSC, 13 M, agost de 2026): molt petit però
10,2% i llicència GPL-3 (no apte per a l'App Store). Voxtral Realtime (Mistral,
4.000 M, l'únic model obert de veritat en streaming de 2026): no suporta català i al
benchmark ibèric queda a 48% de mitjana. Parakeet v3 i Canary v2 (NVIDIA): 25
llengües europees, **sense català**. Qwen3-ASR: 52 llengües, català no confirmat, fluix
a l'ibèric. omniASR (Meta, 1.600 llengües): 9–17% en català. Gemma 4 amb àudio: 21%.
Apple SpeechAnalyzer (iOS 26): **sense català**.

**APIs al núvol.** ElevenLabs Scribe v2 (la més ben valorada el 2026 en general; la
seva pàgina diu 3,1% a FLEURS català i 5,5% a Common Voice, xifres pròpies, sense
comparació de conversa). GPT-4o-transcribe: 2,4% a FLEURS però 12,2% ponderat al
rànquing. Deepgram nova-3 (el del nostre demo web): té català, no publica WER.
Totes volen connexió, cobren per minut i envien la veu fora del dispositiu, que és
justament el que l'app promet no fer.

## Què vol dir per a duna

1. **Canviar de model no arregla la conversa en directe.** No hi ha cap model en
   directe millor. El que sí que podria fer el salt és un mode "màxima qualitat" només
   al Mac amb el Whisper afinat del BSC (whisper-bsc-large-v3-cat): 2–4 punts menys
   d'error en conversa, a canvi de 3 GB més, 3–8 s de retard i un camí de codi nou
   (WhisperKit o MLX). Val la pena provar-lo primer al banc (`.work/sealed-test`,
   `.work/venue-test`) abans de decidir res. A l'iPhone no és viable en directe.
2. **El marge més gran en directe és nostre, no del model.** Transcrivint el fitxer
   sencer el mateix model fa 11,2%; en directe 15–16%. Aquests 4 punts són finestra,
   estabilitzador i absència de correcció final, i es poden treballar.
3. **A l'esdeveniment, el problema no era el model.** Era que inventava en lloc de
   callar; això ja està corregit (`docs/AUDITORIA-PARAULES-INVENTADES.md`).
4. **Vigilar el rànquing.** Qualsevol model nou de català apareixerà a
   https://huggingface.co/spaces/BSC-LT/CATALAN-ASR-ARENA. Un Conformer o FastConformer
   del BSC amb les 4.700 h del Whisper afinat seria el candidat ideal; no existeix.

## Fonts

- Catalan ASR Arena (BSC-LT, Aina): https://huggingface.co/spaces/BSC-LT/CATALAN-ASR-ARENA
  i la notícia d'Aina: https://projecteaina.cat/tech/en/aina-impulsa-el-primer-ranquing-collaboratiu-de-models-de-reconeixement-de-veu-en-catala/
- Models del BSC: https://huggingface.co/BSC-LT/whisper-bsc-large-v3-cat ,
  https://huggingface.co/BSC-LT/stt_los_conformer_transducer_large_punctuated ,
  https://huggingface.co/BSC-LT/ConMamba-small-ca , https://langtech-bsc.gitbook.io/aina-kit/models/models-de-parla
- Benchmark ibèric (setembre de 2026): https://arxiv.org/abs/2609.36920
- 3CatParla (IberSpeech 2024): https://www.isca-archive.org/iberspeech_2024/hernandezmena24_iberspeech.pdf
- ElevenLabs Scribe, català: https://elevenlabs.io/speech-to-text/catalan
- Deepgram, llengües: https://developers.deepgram.com/docs/models-languages-overview
- Apple SpeechAnalyzer: https://blog.addpipe.com/apple-speechanalyzer-api/
- WhisperKit: https://arxiv.org/abs/2507.10860
- Prova local (sealed set, 2026-09-30): `.work/sealed-test/score.py whisper after`
