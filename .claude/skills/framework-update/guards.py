"""Report whether a Phi Framework binary checks respondsToSelector: before
sending each given delegate selector.

Usage: python3 -I guards.py "<framework binary>" <selector>...

Per selector: `checked` (the framework asks respondsToSelector: first),
`UNGUARDED` (sent with no check: Mist must implement it), or `never sent`.
"""

from collections import Counter
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def arm64_slice(data):
    magic = struct.unpack_from(">I", data)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        wide = magic == 0xCAFEBABF
        count = struct.unpack_from(">I", data, 4)[0]
        for i in range(count):
            if wide:
                cpu, _, offset, _, _, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            else:
                cpu, _, offset, _, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            if cpu == 0x0100000C:
                return offset
        raise SystemExit("no arm64 slice")
    return 0


def sections(data, base):
    magic, _, _, _, ncmds = struct.unpack_from("<IiiII", data, base)
    if magic != 0xFEEDFACF:
        raise SystemExit("not a 64-bit Mach-O")
    found = {}
    offset = base + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            for i in range(nsects):
                s = offset + 72 + i * 80
                name = data[s:s + 16].rstrip(b"\0").decode()
                segment = data[s + 16:s + 32].rstrip(b"\0").decode()
                addr, length, fileoff = struct.unpack_from("<QQI", data, s + 32)
                found[(segment, name)] = (addr, length, base + fileoff)
        offset += size
    return found


def selector_names(data, sects):
    """Map selref address -> selector. Chained fixups keep the target in the low 36 bits."""
    maddr, msize, moff = sects[("__TEXT", "__objc_methname")]
    names = {}
    for key in (("__DATA", "__objc_selrefs"), ("__DATA_CONST", "__objc_selrefs")):
        if key not in sects:
            continue
        saddr, ssize, soff = sects[key]
        for i in range(ssize // 8):
            target = struct.unpack_from("<Q", data, soff + i * 8)[0] & 0xFFFFFFFFF
            if maddr <= target < maddr + msize:
                start = moff + target - maddr
                names[saddr + i * 8] = data[start:data.index(b"\0", start)].decode()
    return names


def adrp_page(word, pc):
    imm = (((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 3)
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


def words(data, code, address, count):
    for addr, size, fileoff in code:
        if addr <= address and address + count * 4 <= addr + size:
            return struct.unpack_from(f"<{count}I", data, fileoff + address - addr)
    return None


def stub_selector(data, code, address, names):
    """Selector an objc_msgSend stub loads into x1, following lld's
    adrp x16 / add x16 / br x16 range-extension thunk if there is one."""
    w = words(data, code, address, 3)
    if w and (w[0] & 0x9F00001F) == 0x90000010 and (w[1] & 0xFFC003FF) == 0x91000210 and w[2] == 0xD61F0200:
        address = adrp_page(w[0], address) + ((w[1] >> 10) & 0xFFF)
        w = words(data, code, address, 2)
    if not w or (w[0] & 0x9F00001F) != 0x90000001 or (w[1] & 0xFFC003FF) != 0xF9400021:
        return None
    return names.get(adrp_page(w[0], address) + ((w[1] >> 10) & 0xFFF) * 8)


def main():
    binary, wanted = Path(sys.argv[1]), sys.argv[2:]
    data = binary.read_bytes()
    sects = sections(data, arm64_slice(data))
    names = selector_names(data, sects)
    by_name = {name: address for address, name in names.items()}
    # Sends go through objc_msgSend stubs (x1 = selector) in __objc_stubs.
    code = [sects[key] for key in (("__TEXT", "__text"), ("__TEXT", "__objc_stubs")) if key in sects]
    missing = [name for name in wanted if name not in by_name]
    present = [name for name in wanted if name in by_name]
    hits = []
    if present:
        with tempfile.TemporaryDirectory() as tmp:
            scanner = Path(tmp) / "scan"
            subprocess.run(["clang", "-O2", "-o", scanner, Path(__file__).with_name("scan.c")], check=True)
            for addr, size, fileoff in code:
                out = subprocess.run(
                    [scanner, binary, hex(fileoff), hex(addr), hex(size), *(hex(by_name[n]) for n in present)],
                    check=True, capture_output=True, text=True,
                ).stdout
                hits += [tuple(int(v, 0) for v in line.split()) for line in out.splitlines()]
    # A check loads the selector into x2 and calls objc_msgSend$respondsToSelector:.
    checks = Counter(bl for _, _, dest, bl in hits if dest == 2 and bl)
    helpers = {bl for bl in checks if stub_selector(data, code, bl, names) == "respondsToSelector:"}
    for name in wanted:
        if name in missing:
            print(f"{name}: never sent (no selref)")
            continue
        mine = [h for h in hits if h[1] == by_name[name]]
        checked = [h[0] for h in mine if h[2] == 2 and h[3] in helpers]
        sends = [h[0] for h in mine if h[2] == 1]
        if checked:
            verdict = "checked"
        elif sends:
            verdict = "UNGUARDED"
        else:
            verdict = "never sent"
        where = ", ".join(hex(pc) for pc in checked) or "-"
        print(f"{name}: {verdict} (checks at {where}; {len(sends)} send stub(s))")


if __name__ == "__main__":
    main()
