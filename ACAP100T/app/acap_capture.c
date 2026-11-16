/*
 * ACAP-100T example capture program (Linux)
 *
 * Usage:
 *   ./acap_capture [-n frames] [-o output.yuv]
 *
 * The program uses the zero-copy mmap + WAIT_FRAME/RELEASE_FRAME API.  Each
 * buffer contains the 128-byte ACAP frame header followed by YUYV 4:2:2 data.
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "acap_uapi.h"
#include "acap_ioctl.h"

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

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
    int fd = -1;
    int opt;
    struct acap_info info;
    struct acap_frame frame;
    struct acap_frame_hdr *hdr;
    void *map = MAP_FAILED;
    size_t map_size;
    FILE *out = NULL;
    uint64_t first_ts = 0, last_ts = 0;
    int got = 0;

    while ((opt = getopt(argc, argv, "n:o:h")) != -1) {
        switch (opt) {
        case 'n': frames = atoi(optarg); break;
        case 'o': out_path = optarg; break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    fd = open("/dev/acap0", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open /dev/acap0: %s\n", strerror(errno));
        return 1;
    }

    memset(&info, 0, sizeof(info));
    if (ioctl(fd, ACAP_IOC_GET_INFO, &info) < 0) {
        fprintf(stderr, "GET_INFO: %s\n", strerror(errno));
        goto fail;
    }
    if (info.magic != ACAP_MAGIC) {
        fprintf(stderr, "bad device magic 0x%08x\n", info.magic);
        goto fail;
    }

    printf("ACAP-100T  %ux%u  fmt=%u  stride=%u  frame=%u bytes  buffers=%u  "
           "pixel clock=%" PRIu64 " Hz\n",
           info.width, info.height, info.format, info.stride,
           info.frame_bytes, info.buffer_count, info.pixel_clock_hz);

    map_size = (size_t)info.buffer_stride * info.buffer_count;
    map = mmap(NULL, map_size, PROT_READ, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        fprintf(stderr, "mmap: %s\n", strerror(errno));
        goto fail;
    }

    if (out_path) {
        out = fopen(out_path, "wb");
        if (!out) {
            fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
            goto fail;
        }
    }

    if (ioctl(fd, ACAP_IOC_START, 0) < 0) {
        fprintf(stderr, "START: %s\n", strerror(errno));
        goto fail;
    }

    while (!g_stop && (frames == 0 || got < frames)) {
        ssize_t payload;
        uint32_t idx;

        memset(&frame, 0, sizeof(frame));
        if (ioctl(fd, ACAP_IOC_WAIT_FRAME, &frame) < 0) {
            if (errno == EINTR)
                break;
            fprintf(stderr, "WAIT_FRAME: %s\n", strerror(errno));
            break;
        }

        idx = frame.buffer_index;
        if (idx >= info.buffer_count) {
            fprintf(stderr, "bad buffer index %u\n", idx);
            ioctl(fd, ACAP_IOC_RELEASE_FRAME, &idx);
            continue;
        }

        hdr = (struct acap_frame_hdr *)
              ((char *)map + (size_t)idx * info.buffer_stride);
        if (hdr->magic0 != ACAP_HDR_MAGIC0 || hdr->magic1 != ACAP_HDR_MAGIC1) {
            fprintf(stderr, "frame %u: bad header magic\n", idx);
            ioctl(fd, ACAP_IOC_RELEASE_FRAME, &idx);
            continue;
        }

        payload = (ssize_t)hdr->width * hdr->height * 2;
        if (payload <= 0 ||
            (size_t)ACAP_FRAME_HDR_SIZE + (size_t)payload > info.frame_bytes) {
            fprintf(stderr, "frame %u: bad payload size %zd\n", idx, payload);
            ioctl(fd, ACAP_IOC_RELEASE_FRAME, &idx);
            continue;
        }

        if (out) {
            const void *src = (const char *)hdr + ACAP_FRAME_HDR_SIZE;
            if (fwrite(src, 1, (size_t)payload, out) != (size_t)payload) {
                fprintf(stderr, "write: %s\n", strerror(errno));
                ioctl(fd, ACAP_IOC_RELEASE_FRAME, &idx);
                break;
            }
        }

        if (first_ts == 0)
            first_ts = frame.timestamp_ns;
        last_ts = frame.timestamp_ns;
        got++;

        if ((got % 10) == 0 || got == 1) {
            printf("frame %d: seq=%" PRIu64 " ts=%" PRIu64 " ns buf=%u\n",
                   got, frame.seq, frame.timestamp_ns, idx);
        }

        if (ioctl(fd, ACAP_IOC_RELEASE_FRAME, &idx) < 0) {
            fprintf(stderr, "RELEASE_FRAME: %s\n", strerror(errno));
            break;
        }
    }

    ioctl(fd, ACAP_IOC_STOP, 0);

    if (got > 1 && last_ts > first_ts) {
        double fps = (double)(got - 1) * 1e9 / (double)(last_ts - first_ts);
        printf("captured %d frames, %.2f fps, %.2f MB/s\n",
               got, fps, fps * (double)info.width * info.height * 2.0 / 1e6);
    } else {
        printf("captured %d frames\n", got);
    }

    if (out)
        fclose(out);
    if (map != MAP_FAILED)
        munmap(map, map_size);
    close(fd);
    return got > 0 ? 0 : 1;

fail:
    if (out)
        fclose(out);
    if (map != MAP_FAILED)
        munmap(map, map_size);
    if (fd >= 0)
        close(fd);
    return 1;
}
