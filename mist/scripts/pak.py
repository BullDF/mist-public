"""Read and rebuild Chromium v5 DataPacks, preserving IDs and alias semantics.

Layout follows Chromium ui/base/resource/data_pack.cc. Brotli resources use
ResourceBundle's 2-byte marker plus a 6-byte little-endian uncompressed size.
"""

import argparse
import gzip
from pathlib import Path
import struct


HEADER = struct.Struct("<IB3xHH")
ENTRY = struct.Struct("<HI")
ALIAS = struct.Struct("<HH")
BROTLI = b"\x1e\x9b"


def decompress(data):
    if data.startswith(b"\x1f\x8b"):
        return gzip.decompress(data), "gzip"
    if data.startswith(BROTLI):
        import brotli
        if len(data) < 8:
            raise ValueError("Truncated Brotli resource header")
        decoded = brotli.decompress(data[8:])
        if len(decoded) != int.from_bytes(data[2:8], "little"):
            raise ValueError("Brotli resource size mismatch")
        return decoded, "brotli"
    return data, "raw"


def compress(data, kind):
    if kind == "gzip":
        return gzip.compress(data, mtime=0)
    if kind == "brotli":
        import brotli
        return BROTLI + len(data).to_bytes(6, "little") + brotli.compress(data)
    if kind != "raw":
        raise ValueError(f"Unknown compression: {kind}")
    return data


class Pak:
    def __init__(self, data):
        if len(data) < HEADER.size:
            raise ValueError("Truncated pak header")
        version, self.encoding, count, alias_count = HEADER.unpack_from(data)
        if version != 5 or self.encoding not in (0, 1, 2):
            raise ValueError(f"Unsupported pak version/encoding: {version}/{self.encoding}")
        table_end = HEADER.size + (count + 1) * ENTRY.size + alias_count * ALIAS.size
        if table_end > len(data):
            raise ValueError("Truncated pak index")
        entries = [ENTRY.unpack_from(data, HEADER.size + i * ENTRY.size) for i in range(count + 1)]
        ids = [resource_id for resource_id, _ in entries[:-1]]
        offsets = [offset for _, offset in entries]
        if ids != sorted(set(ids)) or offsets != sorted(offsets):
            raise ValueError("Unsorted or duplicate pak index")
        if offsets[0] != table_end or offsets[-1] != len(data):
            raise ValueError("Pak offsets do not match payload boundaries")
        self.resources = {
            resource_id: data[start:entries[i + 1][1]]
            for i, (resource_id, start) in enumerate(entries[:-1])
        }
        self.canonical_ids = set(self.resources)
        alias_start = HEADER.size + (count + 1) * ENTRY.size
        previous_id = -1
        for i in range(alias_count):
            resource_id, entry_index = ALIAS.unpack_from(data, alias_start + i * ALIAS.size)
            if entry_index >= count or resource_id in self.resources or resource_id <= previous_id:
                raise ValueError("Invalid pak alias")
            self.resources[resource_id] = self.resources[ids[entry_index]]
            previous_id = resource_id
        self.original = data
        self.changed = False

    @classmethod
    def read(cls, path):
        return cls(Path(path).read_bytes())

    def decoded(self, resource_id):
        return decompress(self.resources[resource_id])[0]

    def replace(self, resource_id, replacement):
        original = self.resources[resource_id]
        decoded, kind = decompress(original)
        if decoded != replacement:
            self.resources[resource_id] = compress(replacement, kind)
            self.changed = True

    def to_bytes(self):
        if not self.changed:
            return self.original
        canonical = []
        aliases = []
        seen = {}
        for resource_id, data in sorted(self.resources.items()):
            if data in seen:
                aliases.append((resource_id, seen[data]))
            else:
                seen[data] = len(canonical)
                canonical.append((resource_id, data))
        if len(canonical) > 65535 or len(aliases) > 65535:
            raise ValueError("Pak resource count exceeds v5 limits")
        offset = HEADER.size + (len(canonical) + 1) * ENTRY.size + len(aliases) * ALIAS.size
        table = bytearray()
        for resource_id, data in canonical:
            table.extend(ENTRY.pack(resource_id, offset))
            offset += len(data)
        table.extend(ENTRY.pack(0, offset))
        result = b"".join([
            HEADER.pack(5, self.encoding, len(canonical), len(aliases)),
            table,
            b"".join(ALIAS.pack(*alias) for alias in aliases),
            b"".join(data for _, data in canonical),
        ])
        if Pak(result).resources != self.resources:
            raise ValueError("Rebuilt pak failed resource/alias verification")
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pak", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--find", help="Show decoded resources containing this UTF-8 text")
    extract = commands.add_parser("extract")
    extract.add_argument("id", type=int)
    extract.add_argument("output", type=Path)
    replace = commands.add_parser("replace")
    replace.add_argument("id", type=int)
    replace.add_argument("input", type=Path)
    replace.add_argument("output", type=Path)
    args = parser.parse_args()
    pak = Pak.read(args.pak)
    if args.command == "extract":
        args.output.write_bytes(pak.decoded(args.id))
    elif args.command == "replace":
        pak.replace(args.id, args.input.read_bytes())
        args.output.write_bytes(pak.to_bytes())
    else:
        for resource_id, raw in sorted(pak.resources.items()):
            decoded, kind = decompress(raw)
            if args.find and args.find.encode("utf-8") not in decoded:
                continue
            print(f"{resource_id}\t{kind}\t{len(raw)}\t{len(decoded)}")


if __name__ == "__main__":
    main()
