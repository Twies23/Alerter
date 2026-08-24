#!/usr/bin/env python3
# Decode a WeakAuras !WA:2! export: EncodeForPrint -> raw DEFLATE -> LibSerialize.
import sys, zlib, struct, json

ALPHA = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789()"
DEC = {ord(c): i for i, c in enumerate(ALPHA)}

def decode_for_print(s):
    s = "".join(ch for ch in s if not ch.isspace())
    out = bytearray()
    i, n = 0, len(s)
    while i <= n - 4:
        x1, x2, x3, x4 = (DEC[ord(s[i+k])] for k in range(4))
        cache = x1 + x2*64 + x3*4096 + x4*262144
        out.append(cache & 255); out.append((cache>>8) & 255); out.append((cache>>16) & 255)
        i += 4
    cache = 0; bits = 0
    while i < n:
        cache += DEC[ord(s[i])] << bits; bits += 6; i += 1
    while bits >= 8:
        out.append(cache & 255); cache >>= 8; bits -= 8
    return bytes(out)

class Reader:
    def __init__(self, b):
        self.b = b; self.i = 0
        self.strings = []; self.tables = []
    def byte(self):
        v = self.b[self.i]; self.i += 1; return v
    def bytes(self, n):
        v = self.b[self.i:self.i+n]; self.i += n; return v
    def rint(self, n):
        v = 0
        for c in self.bytes(n): v = v*256 + c
        return v
    def rfloat(self):
        return struct.unpack(">d", self.bytes(8))[0]
    def at_end(self):
        return self.i >= len(self.b)

    def read_string(self, ln):
        raw = self.bytes(ln)
        try: v = raw.decode("utf-8")
        except UnicodeDecodeError: v = raw.decode("latin-1")
        if ln > 2: self.strings.append(v)
        return v
    def read_table(self, cnt, val=None):
        if val is None:
            val = {}; self.tables.append(val)
        for _ in range(cnt):
            k = self.read_object(); v = self.read_object(); val[k] = v
        return val
    def read_array(self, cnt, val=None):
        if val is None:
            val = {}; self.tables.append(val)
        for i in range(1, cnt+1): val[i] = self.read_object()
        return val
    def read_mixed(self, ac, mc):
        val = {}; self.tables.append(val)
        self.read_array(ac, val); self.read_table(mc, val)
        return val

    def read_object(self):
        v = self.byte()
        if v % 2 == 1:
            return (v - 1)//2
        if v % 4 == 2:
            typ = (v - 2)//4
            count = (typ - typ % 4)//4
            typ = typ % 4
            if typ == 0: return self.read_string(count)
            if typ == 1: return self.read_table(count)
            if typ == 2: return self.read_array(count)
            if typ == 3: return self.read_mixed((count % 4)+1, count//4 + 1)
        if v % 8 == 4:
            packed = self.byte()*256 + v
            if v % 16 == 12: return -((packed - 12)//16)
            return (packed - 4)//16
        typ = v // 8
        return self.reader(typ)

    def reader(self, t):
        R = self
        if t == 0:  return None
        if t == 1:  return R.rint(2)
        if t == 2:  return -R.rint(2)
        if t == 3:  return R.rint(3)
        if t == 4:  return -R.rint(3)
        if t == 5:  return R.rint(4)
        if t == 6:  return -R.rint(4)
        if t == 7:  return R.rint(7)
        if t == 8:  return -R.rint(7)
        if t == 9:  return R.rfloat()
        if t == 10: return float(R.bytes(R.byte()))
        if t == 11: return -float(R.bytes(R.byte()))
        if t == 12: return True
        if t == 13: return False
        if t == 14: return R.read_string(R.byte())
        if t == 15: return R.read_string(R.rint(2))
        if t == 16: return R.read_string(R.rint(3))
        if t == 17: return R.read_table(R.byte())
        if t == 18: return R.read_table(R.rint(2))
        if t == 19: return R.read_table(R.rint(3))
        if t == 20: return R.read_array(R.byte())
        if t == 21: return R.read_array(R.rint(2))
        if t == 22: return R.read_array(R.rint(3))
        if t == 23: return R.read_mixed(R.byte(), R.byte())
        if t == 24: return R.read_mixed(R.rint(2), R.rint(2))
        if t == 25: return R.read_mixed(R.rint(3), R.rint(3))
        if t == 26: return R.strings[R.byte()-1]
        if t == 27: return R.strings[R.rint(2)-1]
        if t == 28: return R.strings[R.rint(3)-1]
        if t == 29: return R.tables[R.byte()-1]
        if t == 30: return R.tables[R.rint(2)-1]
        if t == 31: return R.tables[R.rint(3)-1]
        raise ValueError("bad type %d" % t)

def norm(o):
    if isinstance(o, dict):
        return {str(k): norm(v) for k, v in o.items()}
    if isinstance(o, float) and o.is_integer():
        return int(o)
    return o

def summarize(top):
    # WeakAuras export is usually { d = <aura or group>, c = { <child auras> }, ... }
    print("\n=== SUMMARY ===")
    if not isinstance(top, dict):
        print("top-level is", type(top)); return
    print("top-level keys:", list(top.keys()))
    children = top.get("c") or top.get("children")
    d = top.get("d")
    if isinstance(d, dict):
        print("root aura id:", d.get("id"), "| regionType:", d.get("regionType"))
    if isinstance(children, dict):
        kids = [children[k] for k in sorted(children, key=lambda x: (isinstance(x,str), x))]
        print("child count:", len(kids))
        print("\nfirst 40 aura ids:")
        for a in kids[:40]:
            if isinstance(a, dict):
                print("  -", a.get("id"), "| region:", a.get("regionType"),
                      "| load:", (a.get("load") or {}).get("class_and_spec") if isinstance(a.get("load"),dict) else "")

def main():
    src = sys.argv[1]
    try:
        raw = open(src).read()
    except (OSError, IOError):
        raw = src  # allow passing the string directly
    raw = raw.strip()
    if raw.startswith("!WA:2!"): raw = raw[6:]
    elif raw.startswith("!"):    raise SystemExit("old '!' AceSerializer format, not handled")
    comp = decode_for_print(raw)
    data = zlib.decompressobj(-15).decompress(comp)
    print("deflate-inflated bytes:", len(data), file=sys.stderr)
    r = Reader(data)
    ver = r.byte()
    print("serialization version:", ver, file=sys.stderr)
    top = r.read_object()
    json.dump(norm(top), open("wa_decoded.json","w"), indent=1, ensure_ascii=False)
    print("wrote wa_decoded.json (%d bytes)" % len(json.dumps(norm(top))), file=sys.stderr)
    summarize(top)

if __name__ == "__main__":
    main()
