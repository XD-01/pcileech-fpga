CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
CPPFLAGS += -I../driver/linux

all: acap_capture

acap_capture: acap_capture.c ../driver/linux/acap_uapi.h ../driver/linux/acap_ioctl.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ acap_capture.c

clean:
	rm -f acap_capture

.PHONY: all clean
