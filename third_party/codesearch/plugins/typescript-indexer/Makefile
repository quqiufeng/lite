CC = gcc
CFLAGS = -Wall -Wextra -O2 -g \
    -I/opt/tree-sitter/lib/include \
    -I/opt/tree-sitter-typescript/typescript/src \
    -I/opt/tree-sitter-typescript/tsx/src \
    -I./include

LDFLAGS = /opt/tree-sitter/libtree-sitter.a -ljansson -lm

SRC_DIR = src
BIN_DIR = bin
OBJ_DIR = obj

SOURCES = $(wildcard $(SRC_DIR)/*.c)
OBJECTS = $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(SOURCES))

TS_PARSER_DIR = /opt/tree-sitter-typescript
TS_PARSER_OBJS = $(OBJ_DIR)/ts_parser.o $(OBJ_DIR)/tsx_parser.o $(OBJ_DIR)/ts_scanner.o $(OBJ_DIR)/tsx_scanner.o

TARGET = $(BIN_DIR)/typescript-indexer

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJECTS) $(TS_PARSER_OBJS) | $(BIN_DIR)
	$(CC) $(OBJECTS) $(TS_PARSER_OBJS) -o $@ $(LDFLAGS)

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR)/ts_parser.o: $(TS_PARSER_DIR)/typescript/src/parser.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR)/tsx_parser.o: $(TS_PARSER_DIR)/tsx/src/parser.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR)/ts_scanner.o: $(TS_PARSER_DIR)/typescript/src/scanner.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR)/tsx_scanner.o: $(TS_PARSER_DIR)/tsx/src/scanner.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

clean:
	rm -rf $(OBJ_DIR) $(TARGET)
