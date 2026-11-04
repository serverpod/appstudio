#!/usr/bin/env python3
"""Prints the base64 EdDSA public key for a Sparkle private key file.

publish_appcast.sh refuses to sign with a key that is not the one shipped in
the app (SUPublicEDKey). On a release Mac it asks the login Keychain for the
public half (`generate_keys -p`); in CI the private key arrives as a file
instead, and Sparkle's tools have no "print the public key of this file"
command. This derives it, with nothing but the standard library, so the check
runs the same either way.

The file is what `generate_keys -x` exports and what generate_appcast's
--ed-key-file reads: one base64 string, either the 32-byte seed (current
Sparkle and WinSparkle) or the 96-byte legacy form, the 64-byte expanded
private key followed by the 32-byte public key.

Usage: eddsa_public_key.py <private-key-file>
"""

import base64
import hashlib
import sys

# RFC 8032, section 5.1 — just the parts key generation needs.
P = 2**255 - 19
D = (-121665 * pow(121666, P - 2, P)) % P
GY = (4 * pow(5, P - 2, P)) % P


def _recover_x(y):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = x * pow(2, (P - 1) // 4, P) % P
    return P - x if x & 1 else x


G = (_recover_x(GY), GY, 1, _recover_x(GY) * GY % P)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    aa = (y1 - x1) * (y2 - x2) % P
    bb = (y1 + x1) * (y2 + x2) % P
    cc = 2 * t1 * t2 * D % P
    dd = 2 * z1 * z2 % P
    e, f, g, h = bb - aa, dd - cc, dd + cc, bb + aa
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s, point):
    q = (0, 1, 1, 0)
    while s:
        if s & 1:
            q = _add(q, point)
        point = _add(point, point)
        s >>= 1
    return q


def _encode(point):
    x, y, z, _ = point
    zi = pow(z, P - 2, P)
    x, y = x * zi % P, y * zi % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def public_key(raw):
    if len(raw) == 96:
        return raw[64:]
    if len(raw) == 32:
        h = hashlib.sha512(raw).digest()
        a = int.from_bytes(h[:32], "little")
        a &= (1 << 254) - 8
        a |= 1 << 254
        return _encode(_mul(a, G))
    raise ValueError(f"a Sparkle key is 32 or 96 bytes, this one is {len(raw)}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    with open(sys.argv[1], "rb") as f:
        text = f.read().strip()
    try:
        raw = base64.b64decode(text, validate=True)
        print(base64.b64encode(public_key(raw)).decode())
    except (ValueError, base64.binascii.Error) as e:
        sys.exit(f"error: {sys.argv[1]} is not a Sparkle private key: {e}")


if __name__ == "__main__":
    main()
