"""pkg checksum verification.

pkg writes checksums as "<type>$<hash>"; without a type prefix the value is a
plain SHA256 hex digest. Type indexes follow pkg_checksum_type_t in the pkg
sources:
    0 SHA256_BASE32   1 SHA256_HEX
    2 BLAKE2_BASE32   3 BLAKE2_HEX
    4 BLAKE2S_BASE32  5 BLAKE2S_HEX
BASE32 means the z-base-32 alphabet with LSB-first bit packing.
"""
import hashlib

ALPHA = "ybndrfg8ejkmcpqxot1uwisza345h769"


def zb32_lsb(d):
    o = []
    bits = 0
    acc = 0
    for b in d:
        acc |= b << bits
        bits += 8
        while bits >= 5:
            o.append(ALPHA[acc & 31])
            acc >>= 5
            bits -= 5
    if bits:
        o.append(ALPHA[acc & 31])
    return "".join(o)


def _digest(path, algo):
    h = algo()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.digest()


_TYPES = {
    "0": (hashlib.sha256, zb32_lsb),
    "1": (hashlib.sha256, bytes.hex),
    "2": (hashlib.blake2b, zb32_lsb),
    "3": (hashlib.blake2b, bytes.hex),
    "4": (hashlib.blake2s, zb32_lsb),
    "5": (hashlib.blake2s, bytes.hex),
}


def pkg_sum(path, want=None):
    """If want is given, return the checksum computed in the same format."""
    if want and "$" in want:
        t = want.split("$", 1)[0]
        if t not in _TYPES:
            raise ValueError("unknown checksum type: " + t)
        algo, enc = _TYPES[t]
        return t + "$" + enc(_digest(path, algo))
    if want is None:
        return "2$" + zb32_lsb(_digest(path, hashlib.blake2b))
    # No prefix -> plain SHA256 hex.
    return _digest(path, hashlib.sha256).hex()


def verify(path, want):
    if not want:
        return True
    return pkg_sum(path, want) == want
