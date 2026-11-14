# Makefile for mkfs.zfs tool
# ZFS filesystem formatting tool

CC := gcc
CFLAGS := -Wall -Wextra -g
TARGET := mkfs.zfs
SRC := mkfs.zfs.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)
