#!/usr/bin/env python3
"""
Generate the PCIe configuration space for the ASM100T design, emulating an
ASMedia ASM1042 USB 3.0 xHCI host controller.

  PCI 1B21:1042, SUBSYS 1B21:1042, class 0x0C0330 (USB xHCI)
  BAR0 64 kB, MSI-X with 8 vectors (table 0x5000, PBA 0x6000)
  PCIe Gen2 x1

Windows binds the in-box usbxhci.sys through the class code.
"""

import os
import sys

CFG_DWORDS = 1024
VID = 0x1B21
DID = 0x1042
SUBSYS_ID = 0x1042
SUBSYS_VID = 0x1B21

cfg = [0] * CFG_DWORDS
mask = [0] * CFG_DWORDS

# Type-0 header
cfg[0x00] = (DID << 16) | VID
cfg[0x01] = 0x00100000                  # status: capabilities list
cfg[0x02] = 0x0C033001                  # class 0x0C0330, revision 0x01
cfg[0x03] = 0x00000010
cfg[0x04] = 0x00000000                  # BAR0, 64 kB memory
for i in range(0x05, 0x0B):
    cfg[i] = 0x00000000
cfg[0x0B] = (SUBSYS_VID << 16) | SUBSYS_ID
cfg[0x0C] = 0x00000000
cfg[0x0D] = 0x00000040                  # capabilities pointer -> PM
cfg[0x0E] = 0x00000000
cfg[0x0F] = 0x00000100

# Power Management capability @ 0x40 (next 0x50)
cfg[0x10] = 0x00035001
cfg[0x11] = 0x00000003
cfg[0x12] = 0x00000000

# MSI-X capability @ 0x50 (next 0x70), 8 vectors (table size 7)
cfg[0x14] = (0x0007 << 16) | (0x70 << 8) | 0x11
cfg[0x15] = 0x00005000
cfg[0x16] = 0x00006000

# PCI Express capability @ 0x70 (next 0), endpoint, Gen2 x1
cfg[0x1C] = 0x00020010
cfg[0x1D] = 0x00008002
cfg[0x1E] = 0x00000000
cfg[0x1F] = 0x00000012
cfg[0x20] = 0x00120000
cfg[0x21] = 0x00000000
cfg[0x22] = 0x00000000
cfg[0x23] = 0x00000000
cfg[0x24] = 0x00000000
cfg[0x25] = 0x00000000
cfg[0x26] = 0x00000000
cfg[0x27] = 0x00000002
cfg[0x28] = 0x00000002

# Write mask
mask[0x01] = 0x0000FFFF
mask[0x03] = 0x0000FFFF
mask[0x04] = 0xFFFF0000
mask[0x0F] = 0x000000FF
mask[0x12] = 0x00000103
mask[0x14] = 0xC0000000
mask[0x1E] = 0x0000FFFF
mask[0x20] = 0x0000FFFF
mask[0x26] = 0x0000FFFF
mask[0x28] = 0x0000FFFF


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
    root = os.path.normpath(os.path.join(here, ".."))
    write_coe(os.path.join(root, "ip", "pcileech_cfgspace.coe"), cfg)
    write_coe(os.path.join(root, "ip", "pcileech_cfgspace_writemask.coe"), mask)
    print("ASM1042 config space generated: 1B21:1042 class 0x0C0330 BAR0 64 kB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
