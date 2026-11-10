#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include "cs_compat.h"

#define MAX_WORDS 100000
#define HASH_SIZE 131072
#define MAX_WORD_LEN 64

typedef struct word_freq {
    char word[MAX_WORD_LEN];
    int doc_count;
    struct word_freq* next;
} word_freq_t;

static word_freq_t* hash_table[HASH_SIZE] = {0};
static int total_docs = 0;
static int unique_words = 0;

static void word_freq_reset(void) {
    for (int i = 0; i < HASH_SIZE; i++) {
        word_freq_t* e = hash_table[i];
        while (e) {
            word_freq_t* next = e->next;
            free(e);
            e = next;
        }
        hash_table[i] = NULL;
    }
    total_docs = 0;
    unique_words = 0;
}

static unsigned int hash_word(const char* word) {
    unsigned int h = 5381;
    while (*word) {
        h = ((h << 5) + h) + *word++;
    }
    return h % HASH_SIZE;
}

static void add_word_doc(const char* word) {
    if (strlen(word) < 2) return;
    
    unsigned int h = hash_word(word);
    word_freq_t* entry = hash_table[h];
    
    while (entry) {
        if (strcmp(entry->word, word) == 0) {
            entry->doc_count++;
            return;
        }
        entry = entry->next;
    }
    
    if (unique_words >= MAX_WORDS) return;

    entry = calloc(1, sizeof(word_freq_t));
    if (entry) {
        strncpy(entry->word, word, MAX_WORD_LEN - 1);
        entry->word[MAX_WORD_LEN - 1] = '\0';
        entry->doc_count = 1;
        entry->next = hash_table[h];
        hash_table[h] = entry;
        unique_words++;
    }
}

static void process_line(const char* line) {
    char word[MAX_WORD_LEN];
    int i = 0;
    
    for (const char* p = line; *p; p++) {
        if (isalnum((unsigned char)*p) || *p == '_') {
            if (i < MAX_WORD_LEN - 1) {
                word[i++] = tolower((unsigned char)*p);
            }
        } else {
            if (i > 0) {
                word[i] = '\0';
                add_word_doc(word);
                i = 0;
            }
        }
    }
    if (i > 0) {
        word[i] = '\0';
        add_word_doc(word);
    }
}

int lite_cs_word_freq_main(int argc, char** argv) {
    if (argc < 2) {
        printf("Word Frequency Analyzer for TF-IDF\n");
        printf("Usage: %s <cache_dir>\n", argv[0]);
        return 1;
    }
    
    const char* cache_dir = argv[1];
    char text_file[512], out_file[512];
    snprintf(text_file, sizeof(text_file), "%s/chunks_text.txt", cache_dir);
    snprintf(out_file, sizeof(out_file), "%s/word_freq.json", cache_dir);
    
    printf("Analyzing %s...\n", text_file);

    // 文件级全局表：同进程二次调用必须清零，否则 doc_count 累加、IDF 漂移。
    word_freq_reset();
    
    FILE* fp = fopen(text_file, "r");
    if (!fp) {
        fprintf(stderr, "Failed to open %s\n", text_file);
        return 1;
    }
    
    char* line = NULL;
    size_t line_len = 0;
    
    while (getline(&line, &line_len, fp) != -1) {
        total_docs++;
        process_line(line);
    }
    fclose(fp);
    
    printf("Total chunks: %d\n", total_docs);
    
    // 唯一词计数（唯一词在 add_word_doc 里累计，超过 MAX_WORDS 后不再新增）
    printf("Unique words: %d%s\n", unique_words,
           unique_words >= MAX_WORDS ? " (capped at MAX_WORDS)" : "");
    
    // Save to JSON
    FILE* out = fopen(out_file, "w");
    if (!out) {
        fprintf(stderr, "Failed to create %s\n", out_file);
        return 1;
    }
    
    fprintf(out, "{\n");
    fprintf(out, "  \"_total_docs\": %d,\n", total_docs);
    
    int first = 1;
    for (int i = 0; i < HASH_SIZE; i++) {
        word_freq_t* entry = hash_table[i];
        while (entry) {
            if (entry->doc_count >= 3) { // Only save words appearing in 3+ docs
                if (!first) fprintf(out, ",\n");
                first = 0;
                double idf = log((double)total_docs / (entry->doc_count + 1)) + 1.0;
                fprintf(out, "  \"%s\": {\"df\": %d, \"idf\": %.4f}",
                       entry->word, entry->doc_count, idf);
            }
            entry = entry->next;
        }
    }
    
    fprintf(out, "\n}\n");
    fclose(out);
    
    printf("Saved word frequencies to %s\n", out_file);
    
    // Cleanup
    for (int i = 0; i < HASH_SIZE; i++) {
        word_freq_t* entry = hash_table[i];
        while (entry) {
            word_freq_t* next = entry->next;
            free(entry);
            entry = next;
        }
    }
    free(line);
    
    return 0;
}