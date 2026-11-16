#!/usr/bin/env python3
"""
Generate the 4 kB PCIe Type-0 configuration space image for the
Magewell Pro Capture AIO identity (PCI 1CD7:0002).

The 7-series PCIe hard block runs in AXI4-Stream mode, so the host-visible
configuration space is emulated from a 32-bit x 1024 block RAM initialised by
these COE files.

Identity taken from the public Magewell Pro Capture driver database:
  PCI\\VEN_1CD7&DEV_0002&SUBSYS_00800001
  Class 0x040000 (Multimedia video controller), revision 0x01
  BAR0: 32-bit memory, 4 kB, non-prefetchable (matches pcie_7x_0.xci)

Usage:
    python3 gen_magewell_cfgspace.py            # writes ../ip/*.coe
    python3 gen_magewell_cfgspace.py --check    # print a summary only
"""

import os
import sys

CFG_DWORDS = 1024

MAGEWELL_VID = 0x1CD7
MAGEWELL_DID = 0x0002
SUBSYS_ID    = 0x0080          # reports as SUBSYS_00800001
SUBSYS_VID   = 0x0001

cfg = [0] * CFG_DWORDS
mask = [0] * CFG_DWORDS

# ---------------------------------------------------------------------------
# Type-0 configuration header
# ---------------------------------------------------------------------------
cfg[0x00] = (MAGEWELL_DID << 16) | MAGEWELL_VID
cfg[0x01] = 0x00100000          # command = 0, status = capabilities list
cfg[0x02] = 0x04000001          # class 0x040000, revision 0x01
cfg[0x03] = 0x00000010          # cache line 16, header type 0
cfg[0x04] = 0x00000000          # BAR0 base (memory, 32-bit, 4 kB)
for i in range(0x05, 0x0B):
    cfg[i] = 0x00000000         # BAR1..BAR5 unused
cfg[0x0B] = (SUBSYS_VID << 16) | SUBSYS_ID
cfg[0x0C] = 0x00000000          # expansion ROM disabled
cfg[0x0D] = 0x00000040          # capabilities pointer -> MSI at 0x40
cfg[0x0E] = 0x00000000
cfg[0x0F] = 0x00000100          # interrupt line 0, INTA#

# ---------------------------------------------------------------------------
# MSI capability at 0x40 (next = 0x50), 64-bit, one vector
# ---------------------------------------------------------------------------
cfg[0x10] = 0x00805005
cfg[0x11] = 0x00000000
cfg[0x12] = 0x00000000
cfg[0x13] = 0x00000000

# ---------------------------------------------------------------------------
# PCI Express capability at 0x50 (next = 0), endpoint, Gen2 x1
# ---------------------------------------------------------------------------
cfg[0x14] = 0x00020010
cfg[0x15] = 0x00008002          # 512-byte MPS supported, role-based error reporting
cfg[0x16] = 0x00000000
cfg[0x17] = 0x00000012          # link caps: Gen2 (2), x1 (1)
cfg[0x18] = 0x00120000          # link status: Gen2 x1
cfg[0x19] = 0x00000000
cfg[0x1A] = 0x00000000
cfg[0x1B] = 0x00000000
cfg[0x1C] = 0x00000000
cfg[0x1D] = 0x00000000
cfg[0x1E] = 0x00000002          # link caps 2: 5 GT/s
cfg[0x1F] = 0x00000002          # link control 2: target 5 GT/s
cfg[0x20] = 0x00000000

# ---------------------------------------------------------------------------
# Write mask ('1' = writable).  BAR0 must answer the sizing probe
# (write 0xFFFFFFFF, read back 0xFFFFF000) and MSI programming must stick.
# ---------------------------------------------------------------------------
mask[0x01] = 0x0000FFFF
mask[0x03] = 0x0000FFFF
mask[0x04] = 0xFFFFF000
mask[0x0F] = 0x000000FF
mask[0x10] = 0x000F0000
mask[0x11] = 0xFFFFFFFF
mask[0x12] = 0xFFFFFFFF
mask[0x13] = 0x0000FFFF
mask[0x16] = 0x0000FFFF
mask[0x18] = 0x0000FFFF
mask[0x1D] = 0x0000FFFF
mask[0x1F] = 0x000003FF


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
        print("VID:DID   = %04X:%04X" % (cfg[0] & 0xFFFF, cfg[0] >> 16))
        print("Class/Rev = %08X" % cfg[2])
        print("Subsystem = %08X" % cfg[0x0B])
        print("MSI       = %08X  PCIe = %08X  Link = %08X" %
              (cfg[0x10], cfg[0x14], cfg[0x18]))
        return 0

    write_coe(cfg_path, cfg)
    write_coe(mask_path, mask)
    print("wrote %s" % cfg_path)
    print("wrote %s" % mask_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
