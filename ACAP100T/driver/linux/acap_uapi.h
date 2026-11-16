/*
 * ACAP-100T user/kernel ABI
 *
 * This header is shared by the Linux driver, the Windows KMDF driver and the
 * example applications.  Keep the layout in sync with acap_regs.sv and
 * acap_dma.sv.
 */
#ifndef ACAP_UAPI_H
#define ACAP_UAPI_H

#if defined(__KERNEL__)
#include <linux/types.h>
typedef __u32 acap_u32;
typedef __u64 acap_u64;
typedef __u16 acap_u16;
typedef __u8  acap_u8;
#elif defined(_WIN32)
typedef unsigned int       acap_u32;
typedef unsigned long long acap_u64;
typedef unsigned short     acap_u16;
typedef unsigned char      acap_u8;
#else
#include <stdint.h>
typedef uint32_t acap_u32;
typedef uint64_t acap_u64;
typedef uint16_t acap_u16;
typedef uint8_t  acap_u8;
#endif

#define ACAP_MAGIC              0x4D434150u   /* "MCAP" */
#define ACAP_VERSION            0x00010000u
#define ACAP_MAX_BUFFERS        8
#define ACAP_FORMAT_YUYV        0
#define ACAP_FRAME_HDR_SIZE     128
#define ACAP_HDR_MAGIC0         0x46524D31u   /* "FRM1" */
#define ACAP_HDR_MAGIC1         0x4D434150u   /* "MCAP" */

/* BAR0 register map (32-bit accesses) */
#define ACAP_REG_MAGIC          0x000
#define ACAP_REG_VERSION        0x004
#define ACAP_REG_CAPS           0x008
#define ACAP_REG_STATUS         0x00C
#define ACAP_REG_CONTROL        0x010
#define ACAP_REG_IRQ_STATUS     0x014
#define ACAP_REG_IRQ_ENABLE     0x018
#define ACAP_REG_FRAME_SEQ      0x01C
#define ACAP_REG_DROPPED        0x020
#define ACAP_REG_LAST_SIZE      0x024
#define ACAP_REG_LAST_TS_LO     0x028
#define ACAP_REG_LAST_TS_HI     0x02C
#define ACAP_REG_WIDTH          0x030
#define ACAP_REG_HEIGHT         0x034
#define ACAP_REG_STRIDE         0x038
#define ACAP_REG_FORMAT         0x03C
#define ACAP_REG_BUFFER_COUNT   0x040
#define ACAP_REG_FRAME_BYTES    0x044
#define ACAP_REG_ACTIVE_BUFFER  0x048
#define ACAP_REG_BUF_DONE       0x04C
#define ACAP_REG_BUF_ACK        0x050
#define ACAP_REG_HTOTAL         0x0E0
#define ACAP_REG_VTOTAL         0x0E4
#define ACAP_REG_PIXEL_CLK_HZ   0x0E8
#define ACAP_REG_FRAME_RATE_MHZ 0x0EC
#define ACAP_REG_PCIE_LINK      0x0F0
#define ACAP_REG_BUILD_ID       0x0F4
#define ACAP_REG_BUF_BASE       0x100
#define ACAP_REG_BUF_STRIDE     0x010

/* CONTROL bits */
#define ACAP_CTRL_ENABLE        0x00000001u
#define ACAP_CTRL_PATTERN       0x00000002u

/* IRQ bits */
#define ACAP_IRQ_FRAME_DONE     0x00000001u
#define ACAP_IRQ_FRAME_STALL    0x00000002u
#define ACAP_IRQ_ERROR          0x00000004u

struct acap_info {
    acap_u32 magic;
    acap_u32 version;
    acap_u32 width;
    acap_u32 height;
    acap_u32 stride;
    acap_u32 format;
    acap_u32 frame_bytes;       /* header + padded payload */
    acap_u32 buffer_stride;     /* page-aligned stride used for mmap */
    acap_u32 buffer_count;
    acap_u32 caps;
    acap_u64 pixel_clock_hz;
};

struct acap_frame {
    acap_u64 seq;
    acap_u64 timestamp_ns;
    acap_u32 buffer_index;
    acap_u32 bytes;
};

#pragma pack(push, 1)
struct acap_frame_hdr {
    acap_u32 magic0;            /* 0x46524D31 */
    acap_u32 magic1;            /* 0x4D434150 */
    acap_u32 seq;
    acap_u16 width;
    acap_u16 height;
    acap_u8  format;
    acap_u8  flags;
    acap_u16 reserved0;
    acap_u32 stride;
    acap_u32 ts_lo;
    acap_u32 ts_hi;
    acap_u8  reserved1[96];
};
#pragma pack(pop)

#endif /* ACAP_UAPI_H */
