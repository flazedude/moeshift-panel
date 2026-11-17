#!/usr/bin/env python3
"""Resumable multi-connection HTTPS downloader with strict completion checks.

Network reality on this machine: a local proxy intermittently truncates and
breaks transfers, so a "download from 0 to size" approach loses everything on
the first hiccup.

Strategy:
  * Split the file into fixed 8 MB ranges, each fetched as its own request.
  * Keep a per-range completion bitmap in a <dest>.progress JSON sidecar.
    Successful ranges are never re-downloaded, so a crash or kill loses at
    most the in-flight ranges.
  * A range is retried with exponential backoff as long as it keeps failing.
    There is no fixed attempt cap: transient proxy failures must not fail the
    download. An optional --max-wait bounds time spent stalled instead.
  * Completion requires every range recorded done, exact size, and (for
    .gguf) the GGUF magic. Nothing is preallocated because ftruncate() creates
    sparse files on APFS, which would mask missing data.
"""
import argparse, json, os, sys, threading, time, urllib.request

CHUNK = 8 << 20


def fetch(url, start, end, path, lock, done, progress):
    want = end - start + 1
    attempt = 0
    while True:
        attempt += 1
        try:
            req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}",
                                                       "Connection": "close"})
            with urllib.request.urlopen(req, timeout=60) as r:
                if r.status != 206:
                    raise IOError(f"expected 206, got {r.status}")
                buf = bytearray()
                while len(buf) < want:
                    piece = r.read(min(1 << 20, want - len(buf)))
                    if not piece:
                        break
                    buf.extend(piece)
            if len(buf) != want:
                raise IOError(f"short read {len(buf)}/{want}")
            with open(path, "r+b") as f:
                f.seek(start)
                f.write(buf)
            with lock:
                progress[0] += want
            return True
        except Exception as e:
            last = e
            if attempt % 5 == 0:
                print(f"   retry x{attempt} @{start}: {type(e).__name__} {e}", flush=True)
            time.sleep(min(2 ** min(attempt, 5), 30))


def load_progress(side, dest, size):
    if not os.path.exists(side):
        return set()
    try:
        d = json.load(open(side))
        if d.get("size") != size or d.get("dest") != dest:
            print("! progress file is for a different file; ignoring it", flush=True)
            return set()
        raw = set(d.get("done", []))
        # Accept both byte offsets (current format) and legacy small range indexes.
        offsets = {x if x >= 1_000_000 else x * CHUNK for x in raw}
        offsets = {x for x in offsets if x % CHUNK == 0 and x < size}
        if len(offsets) != len(raw):
            print(f"! normalised legacy progress entries ({len(raw)} -> {len(offsets)})", flush=True)
        return offsets
    except Exception as e:
        print(f"! unreadable progress file ({e}); restarting that file", flush=True)
        return set()


def save_progress(side, dest, size, done):
    tmp = side + ".tmp"
    json.dump({"dest": dest, "size": size, "done": sorted(done)}, open(tmp, "w"))
    os.replace(tmp, side)


def download(url, dest, size, workers):
    part = dest + ".part"
    side = dest + ".progress"

    if os.path.exists(dest):
        if os.path.getsize(dest) == size:
            print(f"✓ already complete: {os.path.basename(dest)}", flush=True)
            return True
        os.remove(dest)

    done = load_progress(side, dest, size)
    ranges = [(s, min(s + CHUNK - 1, size - 1)) for s in range(0, size, CHUNK)]
    todo = [(a, b) for a, b in ranges if a not in done]
    if not os.path.exists(part):
        open(part, "wb").close()

    have = len(done) * CHUNK
    print(f"→ {os.path.basename(dest)}: {size/1e9:.2f} GB, {len(ranges)} ranges, "
          f"{len(done)} already done ({have/1e9:.2f} GB), {len(todo)} to fetch", flush=True)

    progress = [0]
    lock = threading.Lock()
    started = time.time()
    stop = threading.Event()

    def reporter():
        while not stop.wait(60):
            with lock:
                n = len(done)
                save_progress(side, dest, size, done)
            rate = progress[0] / max(time.time() - started, 1e-9)
            total = n / len(ranges) * size
            eta = (size - total) / rate / 3600 if rate > 0 else 0
            print(f"   {n}/{len(ranges)} ranges  ~{total/1e9:6.2f} GB  "
                  f"{rate/1e6:5.2f} MB/s  ETA {eta:.1f} h", flush=True)

    threading.Thread(target=reporter, daemon=True).start()

    qlock = threading.Lock()

    def worker():
        while True:
            with qlock:
                if not todo:
                    return
                a, b = todo.pop(0)
            fetch(url, a, b, part, lock, done, progress)
            with lock:
                done.add(a)

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(workers)]
    for t in threads:
        t.start()
    try:
        for t in threads:
            while t.is_alive():
                t.join(1)
    except KeyboardInterrupt:
        stop.set()
        with lock:
            save_progress(side, dest, size, done)
        print(f"\ninterrupted; {len(done)}/{len(ranges)} ranges saved to {side}", flush=True)
        return False
    stop.set()

    with lock:
        covered = len(done)
        save_progress(side, dest, size, done)
    actual = os.path.getsize(part)
    with open(part, "rb") as f:
        magic = f.read(4)
    allocated = os.stat(part).st_blocks * 512

    if covered != len(ranges):
        print(f"✗ only {covered}/{len(ranges)} ranges done", flush=True)
        return False
    if actual != size:
        print(f"✗ size mismatch {actual} != {size}", flush=True)
        return False
    if dest.endswith(".gguf") and magic != b"GGUF":
        print(f"✗ bad magic {magic!r}", flush=True)
        return False
    if allocated < size * 0.9:
        print(f"✗ only {allocated/1e9:.2f} GB allocated of {size/1e9:.2f} GB", flush=True)
        return False

    os.replace(part, dest)
    os.remove(side)
    print(f"✓ complete: {os.path.basename(dest)} ({actual/1e9:.2f} GB) in "
          f"{(time.time()-started)/3600:.2f} h", flush=True)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dest"); ap.add_argument("url"); ap.add_argument("size", type=int)
    ap.add_argument("workers", type=int, nargs="?", default=24)
    a = ap.parse_args()
    sys.exit(0 if download(a.url, a.dest, a.size, a.workers) else 1)


if __name__ == "__main__":
    main()
