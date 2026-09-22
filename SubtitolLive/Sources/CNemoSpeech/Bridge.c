#include "Bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../../../.work/NeMo-Speech.cpp/include/nemo_speech/asr.h"

struct stl_engine {
    nemo_speech_asr_recognizer* recognizer;
};

struct stl_result {
    nemo_speech_asr_result* result;
};

static void copy_string(char* destination, size_t capacity, const char* source) {
    if (!destination || capacity == 0) {
        return;
    }
    snprintf(destination, capacity, "%s", source ? source : "");
}

static double monotonic_milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec * 1000.0 + (double)now.tv_nsec / 1000000.0;
}

stl_engine* stl_engine_create(const char* model_path, char* error, size_t error_capacity) {
    if (!model_path || model_path[0] == '\0') {
        copy_string(error, error_capacity, "No s'ha trobat el model de català.");
        return NULL;
    }

    stl_engine* engine = (stl_engine*)calloc(1, sizeof(stl_engine));
    if (!engine) {
        copy_string(error, error_capacity, "No hi ha prou memòria per iniciar el model.");
        return NULL;
    }

    nemo_speech_asr_backend_config backend = {0};
    backend.size = sizeof(backend);
    backend.gpu = 0;

    nemo_speech_asr_model_config model = {0};
    model.size = sizeof(model);
    model.path = model_path;

    nemo_speech_asr_recognizer_config config = {0};
    config.size = sizeof(config);
    config.backend = &backend;
    config.model = &model;

    const nemo_speech_asr_status status = nemo_speech_asr_create(&config, &engine->recognizer);
    if (status != NEMO_SPEECH_ASR_OK) {
        copy_string(error, error_capacity, nemo_speech_asr_last_error());
        free(engine);
        return NULL;
    }

    copy_string(error, error_capacity, "");
    return engine;
}

void stl_engine_destroy(stl_engine* engine) {
    if (!engine) {
        return;
    }
    nemo_speech_asr_destroy(engine->recognizer);
    free(engine);
}

int stl_engine_transcribe(
    stl_engine* engine,
    const float* samples,
    size_t sample_count,
    int32_t sample_rate,
    stl_result** out_result,
    double* inference_ms,
    char* error,
    size_t error_capacity
) {
    if (out_result) {
        *out_result = NULL;
    }
    if (!engine || !engine->recognizer || !samples || sample_count == 0 || sample_rate <= 0 ||
        !out_result) {
        copy_string(error, error_capacity, "La gravació és buida o no és vàlida.");
        return 1;
    }

    nemo_speech_asr_recognition_options options =
        nemo_speech_asr_recognition_options_default();
    options.interim_results = false;
    options.enable_word_time_offsets = true;
    options.enable_automatic_punctuation = false;

    nemo_speech_asr_result* result = NULL;
    const double started = monotonic_milliseconds();
    const nemo_speech_asr_status status = nemo_speech_asr_recognize_f32(
        engine->recognizer,
        &options,
        samples,
        sample_count,
        sample_rate,
        &result
    );
    const double finished = monotonic_milliseconds();

    if (inference_ms) {
        *inference_ms = finished - started;
    }

    if (status != NEMO_SPEECH_ASR_OK || !result) {
        copy_string(error, error_capacity, nemo_speech_asr_last_error());
        return 2;
    }

    stl_result* wrapped = (stl_result*)calloc(1, sizeof(stl_result));
    if (!wrapped) {
        copy_string(error, error_capacity, "No hi ha prou memòria per retornar la transcripció.");
        nemo_speech_asr_result_destroy(result);
        return 3;
    }

    wrapped->result = result;
    *out_result = wrapped;
    copy_string(error, error_capacity, "");
    return 0;
}

const char* stl_result_transcript(const stl_result* result) {
    if (!result || !result->result) {
        return "";
    }
    const char* text = nemo_speech_asr_result_transcript(result->result, 0);
    return text ? text : "";
}

float stl_result_audio_processed(const stl_result* result) {
    return result && result->result ? nemo_speech_asr_result_audio_processed(result->result) : 0.0f;
}

size_t stl_result_word_count(const stl_result* result) {
    return result && result->result ? nemo_speech_asr_result_word_count(result->result, 0) : 0;
}

const char* stl_result_word_text(const stl_result* result, size_t index) {
    if (!result || !result->result || index >= stl_result_word_count(result)) {
        return "";
    }
    const char* text = nemo_speech_asr_result_word_text(result->result, 0, index);
    return text ? text : "";
}

int32_t stl_result_word_start_time(const stl_result* result, size_t index) {
    if (!result || !result->result || index >= stl_result_word_count(result)) {
        return 0;
    }
    return nemo_speech_asr_result_word_start_time(result->result, 0, index);
}

int32_t stl_result_word_end_time(const stl_result* result, size_t index) {
    if (!result || !result->result || index >= stl_result_word_count(result)) {
        return 0;
    }
    return nemo_speech_asr_result_word_end_time(result->result, 0, index);
}

float stl_result_word_confidence(const stl_result* result, size_t index) {
    if (!result || !result->result || index >= stl_result_word_count(result)) {
        return 0.0f;
    }
    return nemo_speech_asr_result_word_confidence(result->result, 0, index);
}

void stl_result_destroy(stl_result* result) {
    if (!result) {
        return;
    }
    nemo_speech_asr_result_destroy(result->result);
    free(result);
}
