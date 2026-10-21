# Deepgram Streaming STT Research — Catalan Live Transcription

Compiled from primary sources (developers.deepgram.com, deepgram.com, Deepgram GitHub repos). Anything not verifiable from a primary source is marked **[UNVERIFIED]**.

## 1. Catalan (`language=ca`) streaming support

### Models that accept `ca`

| Model param | `ca` support | Streaming? | Source |
|---|---|---|---|
| `nova-3` / `nova-3-general` | ✅ `ca` listed explicitly | ✅ batch **and** streaming | https://developers.deepgram.com/docs/models-languages-overview — the nova-3 row lists "Catalan: `ca`". Changelog 2025-11-24: Nova-3 added 10 languages incl. "Catalan (`ca`)". Changelog 2026-07-16: "improved Nova-3 monolingual models … enhance transcription quality and accuracy for **both batch and streaming** workloads" listing Catalan (`ca`) under "Streaming models". (https://developers.deepgram.com/changelog/2025/11/24.md, https://developers.deepgram.com/changelog/2026/7/16.md) |
| `nova-2` / `nova-2-general` | ✅ `ca` listed explicitly | ✅ (nova-2 is a streaming-capable model; the language table does not mark `ca` as batch-only) | https://developers.deepgram.com/docs/models-languages-overview — the `nova-2`/`nova-2-general` row lists "Catalan: `ca`" alongside `multi` (Spanish+English codeswitching) |
| `flux-general-en` / `flux-general-multi` | ❌ | — | https://developers.deepgram.com/docs/flux/feature-overview — flux-general-multi covers only en, es, fr, de, hi, ru, pt, ja, it, nl |
| `nova-2-meeting`, `-phonecall`, `-finance`, `-conversationalai`, `-voicemail`, `-video`, `-medical` | ❌ English (en, en-US) only, except nova-2-medical = es/en | — | https://developers.deepgram.com/docs/models-languages-overview |
| Legacy `enhanced`/`base`, `whisper` | [UNVERIFIED] for `ca` | — | not checked in the overview table |

**Recommendation: `model=nova-3&language=ca`.** Nova-3 is the flagship, got a dedicated improved Catalan monolingual model (July 2026 changelog), and is the default recommendation for streaming. Nova-2 is the fallback.

### Feature availability for Catalan streaming

| Feature | `ca` support | Notes / Source |
|---|---|---|
| `interim_results` | ✅ all languages | https://developers.deepgram.com/docs/interim-results (badge: "All available languages") |
| `endpointing` | ✅ (VAD-based, language-agnostic; default `10` ms) | https://developers.deepgram.com/docs/endpointing |
| `vad_events` (SpeechStarted) | ✅ (VAD events; shown with nova-3 examples) | https://developers.deepgram.com/docs/speech-started |
| `utterance_end_ms` (UtteranceEnd) | ✅ all languages; requires `interim_results=true` | https://developers.deepgram.com/docs/utterance-end |
| `punctuate` | ✅ all available languages | https://developers.deepgram.com/docs/stt-streaming-feature-overview |
| `smart_format` | ✅ all languages, but non-English models get only **punctuation + paragraphs** (no NER-style entity formatting like dates/currency) | https://developers.deepgram.com/docs/smart-format, https://developers.deepgram.com/docs/self-hosted-smart-formatting ("Nova-3 | Non-English → Punctuation and paragraphs only") |
| `numerals` | ❌ **Catalan not in the supported list** (da, nl, en, fr, de, de-CH, it, no, pl, pt, es, sv, ru, he, ro) | https://developers.deepgram.com/docs/numerals |
| `diarize` | ✅ "All available" per streaming feature overview (adds per-minute surcharge) | https://developers.deepgram.com/docs/stt-streaming-feature-overview |
| `profanity_filter` | ✅ `ca` is in the list | https://developers.deepgram.com/docs/profanity-filter |
| `redact` | Specific languages only; `ca` not confirmed [UNVERIFIED] | https://developers.deepgram.com/docs/stt-streaming-feature-overview |
| `detect_language` | `ca` supported for **pre-recorded only**; "Language Detection is not currently supported for streaming" | https://developers.deepgram.com/docs/language-detection |

## 2. WebSocket endpoint & audio format

- **URL:** `wss://api.deepgram.com/v1/listen` (Nova models; Flux uses `/v2/listen`). Source: https://developers.deepgram.com/reference/speech-to-text/listen-streaming
- **Raw PCM query params:** `encoding=linear16`, `sample_rate=<Hz>` (e.g. `16000`), `channels=1` (default `'1'`). Both `encoding` and `sample_rate` are **required** for raw/headerless audio; for containerized audio (e.g. `audio/webm` from MediaRecorder) omit them so Deepgram reads the container header. Sources: https://developers.deepgram.com/docs/determining-your-audio-format-for-live-streaming-audio, https://developers.deepgram.com/docs/encoding
- **`linear16` byte format:** "16-bit, little endian, signed PCM WAV data" — i.e. int16 LE samples. Source: https://developers.deepgram.com/docs/encoding
- **Binary frames = audio.** Send raw audio as WebSocket *binary* frames. JSON *text* frames are reserved for control messages (`KeepAlive`, `Finalize`, `CloseStream`). Undecodable payloads → close code `1008` / `DATA-0000`. Sources: https://developers.deepgram.com/docs/stt-troubleshooting-websocket-data-and-net-errors, https://developers.deepgram.com/docs/audio-keep-alive (KeepAlive must be a *text* frame)
- **Chunk size:** "Streaming buffer sizes should be between 20 and 100 milliseconds of audio." Source: https://developers.deepgram.com/docs/measuring-streaming-latency
- Browser caveat: MediaRecorder produces `webm/opus` chunks → omit `encoding`/`sample_rate`. For `linear16` in a browser you must capture PCM via AudioWorklet/ScriptProcessor and `Int16Array` buffers. [Pattern inferred from https://deepgram.com/learn/live-transcription-mic-browser which uses MediaRecorder + containerized audio]

Example minimal URL:
```
wss://api.deepgram.com/v1/listen?model=nova-3&language=ca&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&smart_format=true
```

## 3. Token-based auth for browsers

- **Endpoint exists:** `POST https://api.deepgram.com/v1/auth/grant`. Auth: `Authorization: Token <API_KEY>` (key needs Member+ scope). Optional JSON body `{"ttl_seconds": <n>}`. Default TTL **30 s**, **max 3600 s (1 h)**. Response: `{ "access_token": "<jwt>", "expires_in": 30 }`. Grants `usage::write` for `/listen` REST+WS, `/speak` REST+WS, `/read` REST, `/agent` WS — **not** Manage APIs. Sources: https://developers.deepgram.com/reference/auth/tokens/grant, https://developers.deepgram.com/guides/fundamentals/token-based-authentication
- **Using the JWT:** `Authorization: Bearer <jwt>` (Bearer, *not* Token) on any supported API, including the `/v1/listen` WebSocket upgrade for clients that can set headers. Source: token-based-authentication doc above.
- **Browser WebSocket auth** (browsers cannot set `Authorization` on `new WebSocket`): pass credentials as **subprotocols** — `new WebSocket(url, ['token', <API_KEY>])` for a raw key. Docs example: `Sec-WebSocket-Protocol: token, YOUR_DEEPGRAM_API_KEY`. Source: https://developers.deepgram.com/docs/using-the-sec-websocket-protocol
  - For a **grant-token JWT**, Deepgram's own SDK sends `['bearer', <jwt>]` (Bearer scheme → `bearer` subprotocol; API key → `token` subprotocol). Source: official SDK commit message — https://github.com/deepgram/agent/commit/427599fcea5e70fe97b7fa5b20a4800db0d0ada2 ("converts these to Sec-WebSocket-Protocol headers in browsers: `['bearer', token]` or `['token', key]`") and https://github.com/deepgram/deepgram-js-sdk/pull/398. The docs page itself only shows the `token, <key>` variant; treat `['bearer', jwt]` as SDK-verified, docs-light.
- **Token only needs to be valid at handshake:** "You only need the temporary token to be valid during the initial websocket connection… The websocket connection will then stay open." Source: https://developers.deepgram.com/guides/fundamentals/token-based-authentication
- **`?token=` query param:** not documented anywhere. **[UNVERIFIED / probably unsupported]** — use the subprotocol or header.
- Recommended pattern: backend endpoint mints JWT via `/v1/auth/grant` → returns `access_token` → browser opens `new WebSocket(url, ['bearer', jwt])` (or `['token', jwt]`; SDK uses `bearer`).

## 4. Billing model for streaming

- **Billed per second of audio processed, not connection time.** "Deepgram bills per-second on actual audio duration." Source: https://deepgram.com/learn/deepgram-vs-google-vs-assemblyai. Contrast: only the **Voice Agent API** is "calculated based on websocket connection time" — STT `/v1/listen` is not. Source: https://deepgram.com/pricing
- **Minimum billed duration per request:** not found in Deepgram primary docs/pricing. Deepgram advertises "No minimums" (credits) and per-second granularity; a third-party tutorial claims "billed per second, minimum 15 seconds" — **[UNVERIFIED]**. Sources: https://deepgram.com/pricing ("No minimums"), https://theneuralbase.com/deepgram/learn/beginner/request-id-for-debugging/ (third-party claim).
- **`KeepAlive` cost:** it's a JSON text control message carrying no audio → no billable audio seconds. Docs frame it as "preventing timeouts and **optimizing costs**" — i.e., the cheap way to hold an idle connection vs. streaming silent audio (which *is* billed as audio duration). Sources: https://developers.deepgram.com/docs/audio-keep-alive, https://developers.deepgram.com/docs/stt-troubleshooting-websocket-data-and-net-errors ("You can send silent audio to keep the connection alive"). "KeepAlive is free" is a strong inference, not an explicit statement — **[INFERRED]**.
- **Idle timeout:** "If no audio data or `KeepAlive` messages are sent within a 10-second window, the connection will close with a `NET-0001` error." Send KeepAlive every **3–5 s** as a text frame; server does not reply. Also `NET-0002`/`no_audio_timeout`: "Send audio, or a `KeepAlive` message, to keep the stream open." You must send audio within 10 s of opening a (re)connection. Sources: https://developers.deepgram.com/docs/audio-keep-alive, https://developers.deepgram.com/docs/stt-troubleshooting-websocket-data-and-net-errors, https://developers.deepgram.com/docs/recovering-from-connection-errors-and-timeouts-when-live-streaming-audio
- **`CloseStream`:** `{"type":"CloseStream"}` (text frame) tells the server to "finish processing any cached data, send the response to the client, send a summary metadata object, and then terminate the WebSocket connection." You get final Results + a `Metadata` message with `request_id`, `sha256`, `duration`, `channels`. Source: https://developers.deepgram.com/docs/close-stream
- **Limits:** Concurrency is per **project**: Pay-As-You-Go = **150 concurrent streaming STT requests** (was 50; Growth = 225). No request-rate cap — "Deepgram doesn't restrict the number of requests… only the number of concurrent requests." Sources: https://developers.deepgram.com/reference/api-rate-limits, https://developers.deepgram.com/docs/working-with-concurrency-rate-limits, https://deepgram.com/learn/tripling-default-concurrency-to-power-the-voice-ai-economy
- **Session length cap for `/v1/listen`:** no documented maximum found for STT. A **2-hour session limit is documented only for the Voice Agent API** (`/v1/agent`). **[UNVERIFIED for listen]** Sources: https://developers.deepgram.com/docs/voice-agent-feature-overview, https://developers.deepgram.com/docs/agent-keep-alive
- **Multichannel:** billed per channel processed. Source: https://deepgram.com/pricing FAQ ("How do you calculate costs for multichannel audio?")

## 5. Lowest-latency configuration

- **Chunking:** send 20–100 ms of audio per frame. Source: https://developers.deepgram.com/docs/measuring-streaming-latency (Deepgram targets ≤300 ms transcript latency)
- **`interim_results=true`** — interims arrive ~every 1 s with `is_final:false`; latest interim = lowest latency, final = most accurate. Source: https://developers.deepgram.com/docs/using-interim-results
- **`endpointing=<ms>`** — VAD silence threshold that finalizes with `speech_final:true`. Default `10` (ms); `false` disables. For lowest latency keep it small (10–300 ms); larger values (e.g. 500–1000+) reduce mid-utterance splits at the cost of later finals. Docs' own example uses `endpointing=300`. Sources: https://developers.deepgram.com/docs/endpointing, https://developers.deepgram.com/docs/speech-started
- **`vad_events=true`** → emits `SpeechStarted` messages (useful for barge-in/UI). Source: https://developers.deepgram.com/docs/speech-started
- **`utterance_end_ms=1000+`** → emits `UtteranceEnd` after N ms gap *after last finalized word*; **requires `interim_results=true`**; values <1000 pointless since interims are ~1 s cadence. Source: https://developers.deepgram.com/docs/utterance-end
- **`smart_format` latency cost:** streaming Smart Format may **wait up to 3 s** to complete entities before finalizing. `no_delay=true` forces immediate finalization but "will result in skipping formatting altogether in many cases." For a captioning app, either omit `smart_format` or accept it (Catalan gets only punct/paragraphs anyway). Sources: https://developers.deepgram.com/docs/smart-format, https://developers.deepgram.com/changelog/2025/4/2.md
- **`Finalize` control message:** `{"type":"Finalize"}` flushes buffered audio → final result marked `from_finalize:true`. Useful to force a final on demand. Source: https://developers.deepgram.com/docs/finalize

### Server → client message types (JSON text frames)

| `type` | Trigger | Key fields | Source |
|---|---|---|---|
| `Results` | transcription | `channel.alternatives[0].{transcript,confidence,words[]}`, `channel_index:[i,n]`, `start`, `duration`, `is_final`, `speech_final`, optional `from_finalize` | https://developers.deepgram.com/reference/speech-to-text/listen-streaming, https://developers.deepgram.com/docs/live-streaming-audio |
| `SpeechStarted` | `vad_events=true` | `{type, channel:[i,n], timestamp}` | https://developers.deepgram.com/docs/speech-started |
| `UtteranceEnd` | `utterance_end_ms` + interims | `{type, channel:[i,n], last_word_end}`; `last_word_end:-1` = already finalized, ignore | https://developers.deepgram.com/docs/utterance-end |
| `Metadata` | on open / after `CloseStream` | `{type, transaction_key:"deprecated", request_id, sha256, created, duration, channels, models[], model_info{uuid:{name,version,arch}}}` | https://developers.deepgram.com/docs/close-stream |

- **`is_final`** = transcript segment finalized (won't change; interim results are `false` and may be revised).
- **`speech_final`** = endpointing VAD decided the speaker stopped — marks end of an utterance. Build utterances by concatenating `is_final:true` transcripts until `speech_final:true`, then reset the buffer. Source: https://developers.deepgram.com/docs/understand-endpointing-interim-results

## 6. Send-rate & silence handling

- **Max 1.25× realtime:** "Deepgram allows audio to be streamed at a maximum of 1.25x realtime; if you send a large buffer of audio, the stream may wind up being significantly delayed." Source: https://developers.deepgram.com/docs/recovering-from-connection-errors-and-timeouts-when-live-streaming-audio
- **Slower than realtime:** no documented penalty — the stream is just processed as it arrives; latency metric X−Y will grow on your side. [INFERRED from the same doc's cursor model]
- **Silence:** silence sent as audio bytes is billable audio; if you stop sending frames entirely for >10 s → `NET-0001` close. Keep the socket open with `{"type":"KeepAlive"}` text frames every 3–5 s (free of audio billing) or send silent audio (billed). Sources: https://developers.deepgram.com/docs/audio-keep-alive, https://developers.deepgram.com/docs/stt-troubleshooting-websocket-data-and-net-errors
- **Reconnect:** any new connection must receive audio within 10 s or it closes; buffer audio client-side during reconnects (drain at ≤1.25× realtime). Source: https://developers.deepgram.com/docs/recovering-from-connection-errors-and-timeouts-when-live-streaming-audio

## TL;DR for the Catalan app

```
wss://api.deepgram.com/v1/listen
  ?model=nova-3&language=ca
  &encoding=linear16&sample_rate=16000&channels=1
  &interim_results=true&endpointing=300&vad_events=true
  &utterance_end_ms=1000   # opcional; smart_format ometut per latència
```
Auth: `new WebSocket(url, ['bearer', jwt])` where `jwt` comes from your backend calling `POST /v1/auth/grant` (default 30 s TTL — mint right before connecting). Send 16-bit LE PCM in 20–100 ms binary chunks; keep alive with `{"type":"KeepAlive"}` text frames every ~3 s; close with `{"type":"CloseStream"}`. Billed per audio-second only; idle-but-kept-alive connections cost ~nothing. Skip `numerals` (unsupported for `ca`) and `detect_language` (pre-recorded only).
