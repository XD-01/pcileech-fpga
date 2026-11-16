/*
 * ACAP-100T example capture program (Windows)
 *
 * Usage:
 *   acap_capture_win.exe [-n frames] [-o output.yuv]
 *
 * The KMDF driver exposes \\.\ACAP0.  Each ReadFile returns one complete
 * buffer: the 128-byte ACAP frame header followed by YUYV 4:2:2 data.
 */
#include <windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "acap_ioctl_win.h"

static void usage(const char *name)
{
    fprintf(stderr,
            "usage: %s [-n frames] [-o output.yuv]\n"
            "  -n  number of frames to capture (default 30, 0 = until Ctrl-C)\n"
            "  -o  write raw YUYV payload to this file\n",
            name);
}

int main(int argc, char **argv)
{
    const char *out_path = NULL;
    int frames = 30;
    int got = 0;
    int i;
    HANDLE h = INVALID_HANDLE_VALUE;
    DWORD bytes = 0;
    struct acap_info info;
    struct acap_frame_hdr *hdr;
    unsigned char *frame = NULL;
    FILE *out = NULL;
    uint64_t first_ts = 0, last_ts = 0;
    double fps;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
            frames = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            out_path = argv[++i];
        } else if (strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 1;
        }
    }

    h = CreateFileA("\\\\.\\ACAP0",
                    GENERIC_READ | GENERIC_WRITE,
                    0, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "CreateFile(\\\\.\\ACAP0) failed: %lu\n",
                (unsigned long)GetLastError());
        return 1;
    }

    memset(&info, 0, sizeof(info));
    if (!DeviceIoControl(h, ACAP_IOCTL_GET_INFO,
                         NULL, 0, &info, sizeof(info), &bytes, NULL)) {
        fprintf(stderr, "GET_INFO failed: %lu\n", (unsigned long)GetLastError());
        goto fail;
    }
    if (info.magic != ACAP_MAGIC) {
        fprintf(stderr, "bad device magic 0x%08x\n", info.magic);
        goto fail;
    }

    printf("ACAP-100T  %ux%u  fmt=%u  stride=%u  frame=%u bytes  buffers=%u\n",
           info.width, info.height, info.format, info.stride,
           info.frame_bytes, info.buffer_count);

    frame = (unsigned char *)malloc(info.frame_bytes);
    if (!frame) {
        fprintf(stderr, "out of memory\n");
        goto fail;
    }

    if (out_path) {
        out = fopen(out_path, "wb");
        if (!out) {
            fprintf(stderr, "cannot open %s\n", out_path);
            goto fail;
        }
    }

    if (!DeviceIoControl(h, ACAP_IOCTL_START, NULL, 0, NULL, 0, &bytes, NULL)) {
        fprintf(stderr, "START failed: %lu\n", (unsigned long)GetLastError());
        goto fail;
    }

    while (frames == 0 || got < frames) {
        DWORD payload;
        DWORD written;

        if (!ReadFile(h, frame, info.frame_bytes, &bytes, NULL)) {
            fprintf(stderr, "ReadFile failed: %lu\n",
                    (unsigned long)GetLastError());
            break;
        }

        hdr = (struct acap_frame_hdr *)frame;
        if (hdr->magic0 != ACAP_HDR_MAGIC0 || hdr->magic1 != ACAP_HDR_MAGIC1) {
            fprintf(stderr, "frame %d: bad header magic\n", got);
            continue;
        }

        payload = (DWORD)hdr->width * hdr->height * 2;
        if ((DWORD)ACAP_FRAME_HDR_SIZE + payload > info.frame_bytes) {
            fprintf(stderr, "frame %d: bad payload size %lu\n",
                    got, (unsigned long)payload);
            continue;
        }

        if (out) {
            if (fwrite(frame + ACAP_FRAME_HDR_SIZE, 1, payload, out) != payload) {
                fprintf(stderr, "write failed\n");
                break;
            }
        }

        {
            uint64_t ts = ((uint64_t)hdr->ts_hi << 32) | hdr->ts_lo;
            if (first_ts == 0)
                first_ts = ts;
            last_ts = ts;
            if ((got % 10) == 0) {
                printf("frame %d: seq=%u ts=%llu buf=?\n",
                       got, hdr->seq, (unsigned long long)ts);
            }
        }

        got++;
    }

    DeviceIoControl(h, ACAP_IOCTL_STOP, NULL, 0, NULL, 0, &bytes, NULL);

    if (got > 1 && last_ts > first_ts) {
        fps = (double)(got - 1) * 1e9 / (double)(last_ts - first_ts);
        printf("captured %d frames, %.2f fps, %.2f MB/s\n",
               got, fps, fps * (double)info.width * info.height * 2.0 / 1e6);
    } else {
        printf("captured %d frames\n", got);
    }

    if (out)
        fclose(out);
    free(frame);
    CloseHandle(h);
    return got > 0 ? 0 : 1;

fail:
    if (out)
        fclose(out);
    free(frame);
    if (h != INVALID_HANDLE_VALUE)
        CloseHandle(h);
    return 1;
}
