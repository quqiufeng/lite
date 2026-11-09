#ifndef ONNX_EMBEDDER_H
#define ONNX_EMBEDDER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct onnx_embedder onnx_embedder_t;

// Initialize embedder with ONNX model and vocab file
// model_path: path to model.onnx
// vocab_path: path to vocab.txt
// max_seq_length: maximum sequence length (e.g. 128)
// dim: output embedding dimension (e.g. 384)
onnx_embedder_t* onnx_embedder_init(const char* model_path, const char* vocab_path, 
                                     int max_seq_length, int dim);

// Generate embedding for text
// Returns 0 on success, -1 on error
int onnx_embedder_encode(onnx_embedder_t* embedder, const char* text, float* vector);

// Generate embeddings for a batch of texts
// texts: array of text strings
// count: number of texts (batch size)
// vectors: output buffer, size must be >= count * dim
// Returns 0 on success, -1 on error
int onnx_embedder_encode_batch(onnx_embedder_t* embedder, const char** texts, int count, float* vectors);

// Free embedder resources
void onnx_embedder_free(onnx_embedder_t* embedder);

// Get last error message
const char* onnx_embedder_error(void);

#ifdef __cplusplus
}
#endif

#endif
