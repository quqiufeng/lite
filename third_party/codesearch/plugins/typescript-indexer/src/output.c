#include <stdlib.h>
#include "plugin.h"

void records_init(record_list_t *records) {
    records->head = NULL;
    records->tail = NULL;
    records->count = 0;
}

void records_push(record_list_t *records, json_t *obj) {
    record_node_t *node = malloc(sizeof(record_node_t));
    if (!node) return;
    node->json = obj;
    node->next = NULL;

    if (records->tail) {
        records->tail->next = node;
    } else {
        records->head = node;
    }
    records->tail = node;
    records->count++;
}

void records_print(record_list_t *records) {
    record_node_t *cur = records->head;
    while (cur) {
        char *s = json_dumps(cur->json, JSON_COMPACT);
        if (s) {
            printf("%s\n", s);
            free(s);
        }
        cur = cur->next;
    }
}

void records_free(record_list_t *records) {
    record_node_t *cur = records->head;
    while (cur) {
        record_node_t *next = cur->next;
        json_decref(cur->json);
        free(cur);
        cur = next;
    }
    records->head = NULL;
    records->tail = NULL;
    records->count = 0;
}
