#ifndef SUBTITOL_LIVE_BRIDGE_H
#define SUBTITOL_LIVE_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct stl_engine stl_engine;
typedef struct stl_result stl_result;

stl_engine* stl_engine_create(const char* model_path, char* error, size_t error_capacity);
void stl_engine_destroy(stl_engine* engine);

int stl_engine_transcribe(
    stl_engine* engine,
    const float* samples,
    size_t sample_count,
    int32_t sample_rate,
    stl_result** result,
    double* inference_ms,
    char* error,
    size_t error_capacity
);

const char* stl_result_transcript(const stl_result* result);
float stl_result_audio_processed(const stl_result* result);
size_t stl_result_word_count(const stl_result* result);
const char* stl_result_word_text(const stl_result* result, size_t index);
int32_t stl_result_word_start_time(const stl_result* result, size_t index);
int32_t stl_result_word_end_time(const stl_result* result, size_t index);
float stl_result_word_confidence(const stl_result* result, size_t index);
void stl_result_destroy(stl_result* result);

#ifdef __cplusplus
}
#endif

#endif
