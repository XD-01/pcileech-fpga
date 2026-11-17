#!/usr/bin/env python3
"""
Generate the configuration space (COE) and the Identify Controller ROM for
the WD100T design, which presents a Western Digital WD_BLACK SN850 NVMe SSD.

Identity:
    PCI 15B7:5011 (Sandisk / Western Digital)
    SUBSYS 5011:15B7
    Class 0x010802 (NVM Express controller)
    BAR0 16 kB, MSI-X with 32 vectors (table 0x2000, PBA 0x3000)
    PCIe capability advertises Gen4 x4; link status reports the actual
    Gen2 x1 negotiated with the Artix-7 core.
    Identify Controller reports NN = 0: no namespace, no virtual disk.

Usage:
    python3 gen_wd_cfgspace.py
"""

import os
import sys

CFG_DWORDS = 1024

VID = 0x15B7
DID = 0x5011
SUBSYS_ID = 0x5011
SUBSYS_VID = 0x15B7

cfg = [0] * CFG_DWORDS
mask = [0] * CFG_DWORDS

# ---------------------------------------------------------------------------
# Type-0 header
# ---------------------------------------------------------------------------
cfg[0x00] = (DID << 16) | VID
cfg[0x01] = 0x00100000              # command 0, status: capabilities list
cfg[0x02] = 0x01080201              # class 0x010802, revision 0x01
cfg[0x03] = 0x00000010              # header type 0, cache line 16
cfg[0x04] = 0x00000000              # BAR0, memory 32-bit, 16 kB
for i in range(0x05, 0x0B):
    cfg[i] = 0x00000000
cfg[0x0B] = (SUBSYS_VID << 16) | SUBSYS_ID
cfg[0x0C] = 0x00000000              # expansion ROM disabled
cfg[0x0D] = 0x00000040              # capability pointer -> PM @ 0x40
cfg[0x0E] = 0x00000000
cfg[0x0F] = 0x00000100              # INTA#

# ---------------------------------------------------------------------------
# Power Management capability at 0x40 (next = 0x60)
# ---------------------------------------------------------------------------
cfg[0x10] = 0x00036001
cfg[0x11] = 0x00000003
cfg[0x12] = 0x00000000

# ---------------------------------------------------------------------------
# MSI-X capability at 0x60 (next = 0x80), 32 vectors (table size = 31)
# Table: BAR0 + 0x2000, PBA: BAR0 + 0x3000
# ---------------------------------------------------------------------------
cfg[0x18] = (0x001F << 16) | (0x80 << 8) | 0x11
cfg[0x19] = 0x00002000
cfg[0x1A] = 0x00003000

# ---------------------------------------------------------------------------
# PCI Express capability at 0x80 (next = 0), endpoint, Gen4 x4 capable.
# The link status reflects the real negotiated Gen2 x1 of the Artix-7 core.
# ---------------------------------------------------------------------------
cfg[0x20] = 0x00020010
cfg[0x21] = 0x00008002              # 512-byte MPS, role-based error reporting
cfg[0x22] = 0x00000000              # device control / status
cfg[0x23] = 0x00000044              # link caps: 16 GT/s, x4
cfg[0x24] = 0x00120000              # link control 0, link status Gen2 x1
cfg[0x25] = 0x00000000
cfg[0x26] = 0x00000000
cfg[0x27] = 0x00000000
cfg[0x28] = 0x00000000
cfg[0x29] = 0x00000000              # device capabilities 2
cfg[0x2A] = 0x00000000              # device control 2 / status 2
cfg[0x2B] = 0x0000000F              # supported link speeds: 2.5/5/8/16
cfg[0x2C] = 0x00000004              # target link speed: 16 GT/s

# ---------------------------------------------------------------------------
# Write mask
# ---------------------------------------------------------------------------
mask[0x01] = 0x0000FFFF
mask[0x03] = 0x0000FFFF
mask[0x04] = 0xFFFFC000
mask[0x0F] = 0x000000FF
mask[0x12] = 0x00000103             # PMCSR power state / PME enable
mask[0x18] = 0xC0000000             # MSI-X enable + function mask
mask[0x22] = 0x0000FFFF
mask[0x24] = 0x0000FFFF
mask[0x2A] = 0x0000FFFF
mask[0x2C] = 0x0000FFFF


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


def build_identify():
    """Build the 4096-byte Identify Controller structure (little endian)."""
    buf = bytearray(4096)

    def put(off, data):
        buf[off:off + len(data)] = data

    put(0, VID.to_bytes(2, "little"))
    put(2, VID.to_bytes(2, "little"))
    put(4, b"WD-BLACK-SN850-0001".ljust(20, b" "))
    put(24, b"WDS100T1X0E-00AFY0".ljust(40, b" "))
    put(64, b"611100WD".ljust(8, b" "))
    put(72, b"\x00")
    put(73, bytes([0x00, 0x90, 0xA9]))          # WD / SanDisk OUI
    buf[76] = 0x00                              # CMIC
    buf[77] = 0x05                              # MDTS: 128 kB
    put(78, (1).to_bytes(2, "little"))          # CNTLID
    put(80, (0x00010400).to_bytes(4, "little")) # VER 1.4
    put(256, (0).to_bytes(2, "little"))         # OACS
    buf[258] = 3                                # ACL
    buf[259] = 3                                # AERL
    buf[260] = 0                                # FRMW
    buf[261] = 0                                # LPA
    buf[262] = 0                                # ELPE
    buf[263] = 0                                # NPSS
    put(512, (0).to_bytes(4, "little"))         # NN = 0 (no namespaces)
    put(516, (0).to_bytes(2, "little"))         # ONCS
    put(518, (0).to_bytes(2, "little"))         # FUSES
    put(532, (0).to_bytes(4, "little"))         # SGLS
    buf[544] = 0x66                             # SQES: 64 bytes
    buf[545] = 0x44                             # CQES: 16 bytes
    return buf


def write_identify_sv(path):
    buf = build_identify()
    groups = []
    for i in range(0, 4096, 16):
        groups.append(int.from_bytes(buf[i:i + 16], "little"))
    lines = []
    lines.append("// Generated by scripts/gen_wd_cfgspace.py - do not edit.")
    lines.append("`timescale 1ns / 1ps")
    lines.append("")
    lines.append("module nvme_ident_data(")
    lines.append("    input  [7:0]       idx,")
    lines.append("    output reg [127:0] data")
    lines.append(");")
    lines.append("")
    lines.append("    always @ * begin")
    lines.append("        case ( idx )")
    for i, w in enumerate(groups):
        if w != 0:
            lines.append("            8'h%02X: data = 128'h%032X;" % (i, w))
    lines.append("            default: data = 128'h00000000000000000000000000000000;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("")
    lines.append("endmodule")
    lines.append("")
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines))


def write_log_sv(path):
    """Generate the static NVMe log-page data ROM (4 kB per page)."""
    smart = bytearray(4096)
    smart[1] = 0x2C                       # composite temperature 300 K (27 C)
    smart[2] = 0x01
    smart[3] = 100                        # available spare
    smart[4] = 10                         # available spare threshold
    smart[5] = 0                          # percentage used
    smart[112] = 1                        # power cycles = 1
    smart[128] = 1                        # power-on hours = 1
    for off in range(200, 216, 2):        # temperature sensors 1..8
        smart[off] = 0x2C
        smart[off + 1] = 0x01
    smart[216] = 0x2C                     # thermal management temperature 1
    smart[217] = 0x01

    fw = bytearray(4096)
    fw[0] = 0x01                          # active firmware slot 1
    fw[8:16] = b"611100WD"

    self_test = bytearray(4096)           # no operation in progress, all clean

    def emit_group_fn(name, page):
        groups = [int.from_bytes(page[i:i + 16], "little") for i in range(0, 4096, 16)]
        out = []
        out.append("    function [127:0] %s(input [7:0] idx);" % name)
        out.append("        case ( idx )")
        for i, w in enumerate(groups):
            if w != 0:
                out.append("            8'h%02X: %s = 128'h%032X;" % (i, name, w))
        out.append("            default: %s = 128'h00000000000000000000000000000000;" % name)
        out.append("        endcase")
        out.append("    endfunction")
        out.append("")
        return out

    lines = []
    lines.append("// Generated by scripts/gen_wd_cfgspace.py - do not edit.")
    lines.append("`timescale 1ns / 1ps")
    lines.append("")
    lines.append("module nvme_log_data(")
    lines.append("    input  [7:0]   lid,")
    lines.append("    input  [7:0]   idx,")
    lines.append("    output reg [127:0] data")
    lines.append(");")
    lines.append("")
    lines.extend(emit_group_fn("log_smart", smart))
    lines.extend(emit_group_fn("log_fw", fw))
    lines.extend(emit_group_fn("log_selftest", self_test))
    lines.append("    always @ * begin")
    lines.append("        case ( lid )")
    lines.append("            8'h01: data = 128'h00000000000000000000000000000000;  // error log: 0 entries")
    lines.append("            8'h02: data = log_smart(idx);")
    lines.append("            8'h03: data = log_fw(idx);")
    lines.append("            8'h04: data = 128'h00000000000000000000000000000000;  // changed NS list: empty")
    lines.append("            8'h05: data = 128'h00000000000000000000000000000000;  // command effects")
    lines.append("            8'h06: data = log_selftest(idx);")
    lines.append("            8'h07, 8'h08: data = 128'h00000000000000000000000000000000; // telemetry")
    lines.append("            8'h09, 8'h0A: data = 128'h00000000000000000000000000000000;")
    lines.append("            8'h15, 8'h16: data = 128'h00000000000000000000000000000000;")
    lines.append("            8'h80, 8'h81: data = 128'h00000000000000000000000000000000;")
    lines.append("            default: data = 128'h00000000000000000000000000000000;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("")
    lines.append("endmodule")
    lines.append("")
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, ".."))
    write_coe(os.path.join(root, "ip", "pcileech_cfgspace.coe"), cfg)
    write_coe(os.path.join(root, "ip", "pcileech_cfgspace_writemask.coe"), mask)
    write_identify_sv(os.path.join(root, "src", "nvme_ident_data.sv"))
    write_log_sv(os.path.join(root, "src", "nvme_log_data.sv"))
    print("WD config space + Identify + log-page ROM generated")
    print("VID:DID = %04X:%04X  SUBSYS = %04X:%04X  class = 0x010802  BAR0 = 16 kB" %
          (VID, DID, SUBSYS_VID, SUBSYS_ID))
    return 0


if __name__ == "__main__":
    sys.exit(main())
