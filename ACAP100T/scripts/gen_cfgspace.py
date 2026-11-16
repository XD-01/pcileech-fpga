#!/usr/bin/env python3
"""
Generate the 4 kB PCIe Type-0 configuration space image and its write mask
for the ACAP-100T capture card firmware.

The 7-series PCIe hard block is used in AXI4-Stream (TLP) mode.  In this mode
the host-visible configuration space is emulated by acap_cfgspace.sv from a
32-bit x 1024 block RAM.  The two COE files produced here are consumed by the
block RAM and distributed-ROM IP instances.

Layout (little-endian bytes):
  0x00  Vendor / Device ID           1AB2:1001
  0x04  Command / Status             cap-list bit set
  0x08  Class / Revision             048000:01  (Multimedia video controller)
  0x0C  Cache line / Header type
  0x10  BAR0                         4 kB, 32-bit, non-prefetchable
  0x2C  Subsystem ID                 1AB2:1001
  0x3C  Interrupt line / pin
  0x40  MSI capability               one vector, 64-bit address
  0x50  PCI Express capability       endpoint, Gen2 x1
The rest of the 4 kB aperture reads as zero.

Usage:
    python3 gen_cfgspace.py            # writes ../ip/*.coe
    python3 gen_cfgspace.py --check    # only print a summary
"""

import os
import sys

CFG_DWORDS = 1024
MASK_DWORDS = 1024

cfg = [0] * CFG_DWORDS
mask = [0] * MASK_DWORDS

# ---------------------------------------------------------------------------
# Type-0 configuration header
# ---------------------------------------------------------------------------
cfg[0x00] = 0x10011AB2          # vendor 0x1AB2, device 0x1001
cfg[0x01] = 0x00100000          # command = 0, status = capabilities-list
cfg[0x02] = 0x04800001          # class 0x048000 (video), revision 0x01
cfg[0x03] = 0x00000010          # cache line 16, latency 0, header type 0
cfg[0x04] = 0x00000000          # BAR0 base (memory, 32-bit, 4 kB)
for i in range(0x05, 0x0B):
    cfg[i] = 0x00000000         # BAR1..BAR5 unused
cfg[0x0B] = 0x10011AB2          # subsystem vendor / device
cfg[0x0C] = 0x00000000          # expansion ROM disabled
cfg[0x0D] = 0x00000000          # reserved
cfg[0x0E] = 0x00000000          # reserved
cfg[0x0F] = 0x00000100          # interrupt line 0, interrupt pin INTA#

# ---------------------------------------------------------------------------
# MSI capability at 0x40 (next = 0x50)
# ---------------------------------------------------------------------------
# Message control: bit 7 = 64-bit capable, bits 6:4 = MMC (0 -> 1 vector),
# bit 0 = MSI enable (cleared until the OS enables MSI).
cfg[0x10] = 0x00805005          # cap ID 0x05, next 0x50, control 0x0080
cfg[0x11] = 0x00000000          # message address low
cfg[0x12] = 0x00000000          # message address high
cfg[0x13] = 0x00000000          # message data (16 bits)

# ---------------------------------------------------------------------------
# PCI Express capability at 0x50 (next = 0)
# ---------------------------------------------------------------------------
cfg[0x14] = 0x00020010          # cap ID 0x10, next 0x00, version 2, endpoint
cfg[0x15] = 0x00008000          # device caps: role-based error reporting
cfg[0x16] = 0x00000000          # device control/status, MPS = 128 bytes
cfg[0x17] = 0x00000012          # link caps: Gen2 (2), x1 (1)
cfg[0x18] = 0x00120000          # link control 0, link status Gen2 x1
cfg[0x19] = 0x00000000          # slot capabilities
cfg[0x1A] = 0x00000000          # slot control/status
cfg[0x1B] = 0x00000000          # root control/status
cfg[0x1C] = 0x00000000          # device capabilities 2
cfg[0x1D] = 0x00000000          # device control 2
cfg[0x1E] = 0x00000002          # link capabilities 2: 5 GT/s supported
cfg[0x1F] = 0x00000002          # link control 2: target speed 5 GT/s
cfg[0x20] = 0x00000000          # link status 2

# ---------------------------------------------------------------------------
# Write mask.  A '1' bit means the corresponding configuration bit is
# writable.  Keeping read-only fields masked off is important: it also makes
# the BAR-sizing probe (write 0xFFFFFFFF, read back 0xFFFFF000) behave.
# ---------------------------------------------------------------------------
mask[0x01] = 0x0000FFFF          # command register
mask[0x03] = 0x0000FFFF          # cache line size / latency timer
mask[0x04] = 0xFFFFF000          # BAR0 base address (size encoded in low bits)
mask[0x0F] = 0x000000FF          # interrupt line
mask[0x10] = 0x000F0000          # MSI enable + multiple-message enable
mask[0x11] = 0xFFFFFFFF          # MSI address low
mask[0x12] = 0xFFFFFFFF          # MSI address high
mask[0x13] = 0x0000FFFF          # MSI data
mask[0x16] = 0x0000FFFF          # PCIe device control
mask[0x18] = 0x0000FFFF          # PCIe link control
mask[0x1D] = 0x0000FFFF          # PCIe device control 2
mask[0x1F] = 0x000003FF          # PCIe link control 2


def write_coe(path, values):
    words = ["%08X" % v for v in values]
    with open(path, "w", newline="\n") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        for i in range(0, len(words), 8):
            line = ",".join(words[i:i + 8])
            if i + 8 < len(words):
                line += ","
            f.write(line + "\n")
        f.write(";\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.normpath(os.path.join(here, "..", "ip"))
    cfg_path = os.path.join(out_dir, "pcileech_cfgspace.coe")
    mask_path = os.path.join(out_dir, "pcileech_cfgspace_writemask.coe")

    if "--check" in sys.argv:
        print("CFG 0x00=0x%08X 0x04=0x%08X 0x08=0x%08X" %
              (cfg[0], cfg[1], cfg[2]))
        print("MSI 0x40=0x%08X  PCIe 0x50=0x%08X  Link 0x5C=0x%08X" %
              (cfg[0x10], cfg[0x14], cfg[0x18]))
        return 0

    write_coe(cfg_path, cfg)
    write_coe(mask_path, mask)
    print("wrote %s" % cfg_path)
    print("wrote %s" % mask_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
