#!/usr/bin/env python3
"""Put the UniXNU layout on the NVMe drive of the Orange Pi 5. Runs on the board under Linux, as root; standard library only.

    nvme-install.py BUNDLE [--device /dev/nvme0n1] [--expect-bytes N --write] [--parts gpt,esp,root,data]
    nvme-install.py --selftest

BUNDLE is the directory make-bundle.py produced: layout.json, esp.img (the payload FAT volume), userdata-root.img.
Without --write it is a dry run: it checks the bundle (SHA-256), checks the drive, prints the plan and writes nothing.
--write needs --expect-bytes with the size the dry run printed, so that a write always follows a look at the drive.

The layout (from the board's board.toml [userdata], recorded in layout.json):

    LBA 0..2047                 protective MBR, GPT header and entries (the primary GPT is 34 sectors; the rest is alignment)
    esp        first_lba ..     the payload volume, 256 MiB, type EFI System; the firmware finds \\EFI\\UniXNU\\unixnu.toml on it
    userdata   first_lba ..     the root image at its start (manifest SHNGROOT first); the driver puts the persistent Data
                                window at its END (1 MiB header + the container of the Data seed)
    backup GPT                  the last 33 sectors of the drive, for whatever size the drive really has

--parts picks what is written (default all four):
    gpt    wipe the old tables, write MBR + primary + backup GPT (last, after the data, so an interrupted install leaves no table)
    esp    the payload volume. This is the only part that changes between kernel builds: `--parts esp` takes seconds
    root   userdata-root.img (about 9 GiB), only for a new OS image
    data   zero the header of the Data window, so the next boot formats it from the seed (a plain re-install keeps the Data volume)
Without gpt in --parts the drive's table must already be the one this layout describes; otherwise nothing is written.

What it will not do (each is a refusal, not a warning):
  * write to anything but a whole NVMe namespace (/dev/nvmeXnY), or to a drive with a mounted partition, swap, or a holder
    (device-mapper, md). Booted from the NVMe? Boot Linux from an SD card instead;
  * write to a drive whose logical block size is not 512 (the driver only speaks 512; `nvme format -l` converts, it erases);
  * write to a drive too small for the layout, or when the files do not match their SHA-256;
  * report success before it has read everything back with O_DIRECT (after BLKFLSBUF) and compared it.

A regular file works as the "device" for --selftest and for trying the plan.
"""
import argparse
import fcntl
import hashlib
import json
import mmap
import os
import re
import stat
import struct
import sys
import tempfile
import time
import uuid
import zlib

SECTOR = 512
CHUNK = 4 << 20            # a multiple of every logical block size involved
ALIGN = 512                # O_DIRECT granularity (the logical block size, which the drive check pins to 512)
BLKGETSIZE64 = 0x80081272
BLKFLSBUF = 0x1261
BLKRRPART = 0x125F
GPT_SECTORS = 33           # 1 header + 32 sectors of 128 entries
GPT_ENTRIES = 128
ESP_TYPE = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
DATA_TYPE = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
GUID_NAMESPACE = uuid.UUID("5d0e1c6e-8f79-4b2d-9d5c-0f3a3e4a7f10")
ALL_PARTS = ("gpt", "esp", "root", "data")


def log(message):
    print(message, flush=True)


def die(message):
    raise SystemExit("refusing: " + message)


# ---- GPT ----------------------------------------------------------------------------------------------------------------

def guid_bytes(text):
    return uuid.UUID(text).bytes_le


def protective_mbr(total_sectors):
    mbr = bytearray(SECTOR)
    entry = struct.pack("<B3sB3sII", 0, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, min(total_sectors - 1, 0xFFFFFFFF))
    mbr[446:446 + 16] = entry
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def gpt_entries(partitions):
    table = bytearray(GPT_ENTRIES * 128)
    for slot, part in enumerate(partitions):
        name = part["name"].encode("utf-16-le")
        if len(name) > 72:
            raise ValueError("partition name too long")
        raw = (guid_bytes(part["type"]) + guid_bytes(part["guid"]) + struct.pack("<QQQ", part["first"], part["last"], 0)
               + name.ljust(72, b"\0"))
        table[slot * 128:(slot + 1) * 128] = raw
    return bytes(table)


def gpt_header(my_lba, alt_lba, entries_lba, total_sectors, disk_guid, entries_crc):
    header = bytearray(SECTOR)
    header[0:8] = b"EFI PART"
    struct.pack_into("<IIII", header, 8, 0x00010000, 92, 0, 0)
    struct.pack_into("<QQQQ", header, 24, my_lba, alt_lba, 34, total_sectors - GPT_SECTORS - 1)
    header[56:72] = guid_bytes(disk_guid)
    struct.pack_into("<QIII", header, 72, entries_lba, GPT_ENTRIES, 128, entries_crc)
    struct.pack_into("<I", header, 16, zlib.crc32(bytes(header[:92])) & 0xFFFFFFFF)
    return bytes(header)


def build_gpt(layout, total_sectors):
    """The byte strings of the three table areas: (head, tail) as {offset: bytes} for a drive of total_sectors."""
    disk_guid = str(uuid.uuid5(GUID_NAMESPACE, "disk-%d" % total_sectors))
    partitions = [
        {"name": "esp", "type": ESP_TYPE, "guid": str(uuid.uuid5(GUID_NAMESPACE, "esp-%d" % total_sectors)),
         "first": layout["esp"]["first_lba"], "last": layout["esp"]["first_lba"] + layout["esp"]["sectors"] - 1},
        {"name": layout["userdata"]["label"], "type": DATA_TYPE,
         "guid": str(uuid.uuid5(GUID_NAMESPACE, "userdata-%d" % total_sectors)),
         "first": layout["userdata"]["first_lba"], "last": layout["userdata"]["last_lba"]},
    ]
    table = gpt_entries(partitions)
    crc = zlib.crc32(table) & 0xFFFFFFFF
    primary = gpt_header(1, total_sectors - 1, 2, total_sectors, disk_guid, crc)
    backup = gpt_header(total_sectors - 1, 1, total_sectors - GPT_SECTORS, total_sectors, disk_guid, crc)
    head = protective_mbr(total_sectors) + primary + table                       # LBA 0, 1, 2..33
    tail = table + backup                                                         # total-33 .. total-1
    return {"head": head, "tail": tail, "partitions": partitions}


def parse_gpt(read, total_sectors):
    """Independent reader (it does not share code with build_gpt): returns [(name, type, first, last)] or raises ValueError.
    Checks both tables, their CRCs and that they describe the same drive."""
    mbr = read(0, SECTOR)
    if mbr[510:512] != b"\x55\xaa" or mbr[450] != 0xEE:
        raise ValueError("no protective MBR")
    results = []
    for lba in (1, total_sectors - 1):
        header = read(lba * SECTOR, SECTOR)
        if header[:8] != b"EFI PART":
            raise ValueError("no GPT signature at LBA %d" % lba)
        size, crc = struct.unpack_from("<II", header, 12)
        probe = bytearray(header[:size])
        probe[16:20] = b"\0\0\0\0"
        if zlib.crc32(bytes(probe)) & 0xFFFFFFFF != crc:
            raise ValueError("header CRC at LBA %d" % lba)
        my, alt, first_usable, last_usable = struct.unpack_from("<QQQQ", header, 24)
        entries_lba, count, entry_size, entries_crc = struct.unpack_from("<QIII", header, 72)
        if my != lba or alt != (total_sectors - 1 if lba == 1 else 1):
            raise ValueError("header at LBA %d does not point at its twin" % lba)
        if last_usable != total_sectors - GPT_SECTORS - 1 or first_usable != 34:
            raise ValueError("usable range of the table at LBA %d is not that of this drive" % lba)
        table = read(entries_lba * SECTOR, count * entry_size)
        if zlib.crc32(table) & 0xFFFFFFFF != entries_crc:
            raise ValueError("entry array CRC at LBA %d" % lba)
        listed = []
        for slot in range(count):
            raw = table[slot * entry_size:(slot + 1) * entry_size]
            if raw[:16] == b"\0" * 16:
                continue
            first, last = struct.unpack_from("<QQ", raw, 32)
            name = raw[56:128].decode("utf-16-le").split("\0")[0]
            listed.append((name, str(uuid.UUID(bytes_le=raw[:16])).upper(), first, last))
        results.append(listed)
    if results[0] != results[1]:
        raise ValueError("primary and backup tables differ")
    return results[0]


# ---- I/O ----------------------------------------------------------------------------------------------------------------

def padded(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as handle:
        while True:
            block = handle.read(8 << 20)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


class Disk:
    """O_DIRECT access with aligned buffers; falls back to buffered access only for regular files."""

    def __init__(self, path, write):
        flags = os.O_RDWR if write else os.O_RDONLY
        self.block = stat.S_ISBLK(os.stat(path).st_mode)
        try:
            self.fd = os.open(path, flags | os.O_DIRECT)
        except OSError:
            if self.block:
                die("cannot open %s with O_DIRECT; a read-back without it proves nothing" % path)
            self.fd = os.open(path, flags)
        self.buf = mmap.mmap(-1, CHUNK)

    def size(self):
        if self.block:
            return struct.unpack("<Q", fcntl.ioctl(self.fd, BLKGETSIZE64, b"\0" * 8))[0]
        return os.fstat(self.fd).st_size

    def drop_cache(self):
        if self.block:
            fcntl.ioctl(self.fd, BLKFLSBUF, 0)
        else:
            os.posix_fadvise(self.fd, 0, 0, os.POSIX_FADV_DONTNEED)

    def write(self, data, offset):
        assert offset % ALIGN == 0
        data = data + b"\0" * (padded(len(data)) - len(data))
        for start in range(0, len(data), CHUNK):
            part = data[start:start + CHUNK]
            self.buf[:len(part)] = part
            view = memoryview(self.buf)[:len(part)]
            done = 0
            while done < len(part):
                done += os.pwritev(self.fd, [view[done:]], offset + start + done)

    def read(self, offset, length):
        """Any offset and length: the aligned span is read and trimmed."""
        start = offset // ALIGN * ALIGN
        end = padded(offset + length)
        out = bytearray()
        for at in range(start, end, CHUNK):
            span = min(CHUNK, end - at)
            view = memoryview(self.buf)[:span]
            got = 0
            while got < span:
                n = os.preadv(self.fd, [view[got:]], at + got)
                if n == 0:
                    raise EOFError("short read at %d" % (at + got))
                got += n
            out += view
        return bytes(out[offset - start:offset - start + length])

    def sync(self):
        os.fsync(self.fd)

    def rescan(self):
        if self.block:
            try:
                fcntl.ioctl(self.fd, BLKRRPART)
            except OSError as error:
                log("note: the kernel did not re-read the partition table (%s); it does at the next boot" % error)

    def close(self):
        os.close(self.fd)


def source_chunks(path):
    with open(path, "rb", buffering=0) as handle:
        at = 0
        while True:
            block = handle.read(CHUNK)
            if not block:
                return
            yield at, block
            at += len(block)


def write_file(disk, path, offset, label):
    total = os.path.getsize(path)
    began = time.time()
    last = 0
    for at, block in source_chunks(path):
        disk.write(block, offset + at)
        if (at + len(block)) * 20 // total != last:
            last = (at + len(block)) * 20 // total
            rate = (at + len(block)) / max(time.time() - began, 1e-3) / 1e6
            log("  %s: %3d%%  %.0f MB/s" % (label, last * 5, rate))


def verify_file(disk, path, offset, label):
    total = os.path.getsize(path)
    began = time.time()
    last = 0
    for at, block in source_chunks(path):
        got = disk.read(offset + at, len(block))
        if got != block:
            bad = next(i for i in range(len(block)) if got[i] != block[i])
            raise SystemExit("VERIFY FAILED: %s differs at byte %d of the image (drive offset %d)" % (label, at + bad, offset + at + bad))
        if (at + len(block)) * 20 // total != last:
            last = (at + len(block)) * 20 // total
            rate = (at + len(block)) / max(time.time() - began, 1e-3) / 1e6
            log("  verify %s: %3d%%  %.0f MB/s" % (label, last * 5, rate))


# ---- checks -------------------------------------------------------------------------------------------------------------

def read_sys(name, leaf):
    try:
        with open("/sys/block/%s/%s" % (name, leaf)) as handle:
            return handle.read().strip()
    except OSError:
        return None


def device_refusal(path, mounts, swaps, holders, block_size, regular_ok):
    """The decision on plain facts, so the selftest can feed it every case. Returns a refusal text or None."""
    if regular_ok:
        return None
    name = os.path.basename(os.path.realpath(path))
    if not re.fullmatch(r"nvme\d+n\d+", name):
        return "%s is not a whole NVMe namespace (nvmeXnY)" % path
    for source, target in mounts:
        if source.startswith("/dev/") and os.path.realpath(source).startswith("/dev/" + name):
            return "%s is mounted at %s" % (source, target)
    for source in swaps:
        if os.path.realpath(source).startswith("/dev/" + name):
            return "%s is in use as swap" % source
    if holders:
        return "%s is held by %s (device-mapper or md)" % (path, ", ".join(holders))
    if block_size != 512:
        return ("the logical block size of %s is %s, not 512: the driver only speaks 512-byte blocks. `nvme id-ns %s -H` lists the "
                "formats; `nvme format --lbaf=N` converts, erasing the drive" % (path, block_size, path))
    return None


def check_device(path):
    st = os.stat(path)
    regular_ok = stat.S_ISREG(st.st_mode)
    if not regular_ok and not stat.S_ISBLK(st.st_mode):
        die("%s is neither a block device nor a file" % path)
    mounts, swaps, holders = [], [], []
    block_size = 512
    if not regular_ok:
        with open("/proc/mounts") as handle:
            mounts = [line.split()[:2] for line in handle if line.strip()]
        try:
            with open("/proc/swaps") as handle:
                swaps = [line.split()[0] for line in list(handle)[1:]]
        except OSError:
            pass
        name = os.path.basename(os.path.realpath(path))
        base = "/sys/block/" + name
        for entry in [name] + [d for d in (os.listdir(base) if os.path.isdir(base) else []) if d.startswith(name + "p")]:
            folder = base + ("" if entry == name else "/" + entry) + "/holders"
            if os.path.isdir(folder):
                holders += os.listdir(folder)
        value = read_sys(name, "queue/logical_block_size")
        block_size = int(value) if value and value.isdigit() else 0
    why = device_refusal(path, mounts, swaps, holders, block_size, regular_ok)
    if why:
        die(why)
    return regular_ok


def describe_device(path, size, regular_ok):
    name = os.path.basename(os.path.realpath(path))
    if regular_ok:
        log("target: file %s, %d bytes (%d sectors)" % (path, size, size // SECTOR))
        return
    log("target: %s  model %r  serial %r  firmware %r" % (path, read_sys(name, "device/model"), read_sys(name, "device/serial"),
                                                          read_sys(name, "device/firmware_rev")))
    log("        %d bytes = %d sectors of 512 (%.1f GiB), logical block %s, physical block %s" % (
        size, size // SECTOR, size / 2**30, read_sys(name, "queue/logical_block_size"), read_sys(name, "queue/physical_block_size")))


def load_bundle(bundle, check_hashes):
    with open(os.path.join(bundle, "layout.json")) as handle:
        layout = json.load(handle)
    if layout.get("schema") != 1 or layout.get("sector_bytes") != SECTOR:
        die("layout.json is not a schema 1 layout of 512-byte sectors")
    files = {"esp": layout["esp"], "root": layout["root"]}
    for key, item in files.items():
        path = os.path.join(bundle, item["file"])
        if not os.path.isfile(path) or os.path.getsize(path) != item["bytes"]:
            die("%s is missing or its size is not %d bytes" % (path, item["bytes"]))
        item["path"] = path
    if layout["esp"]["bytes"] > layout["esp"]["sectors"] * SECTOR:
        die("the ESP image does not fit its partition")
    root = layout["root"]
    userdata = layout["userdata"]
    if root["offset_bytes"] % SECTOR:
        die("root offset is not a multiple of 512")
    if userdata["first_lba"] * SECTOR + root["offset_bytes"] + root["bytes"] > (userdata["last_lba"] + 1) * SECTOR:
        die("the root image does not fit the userdata partition")
    if layout["esp"]["first_lba"] + layout["esp"]["sectors"] > userdata["first_lba"]:
        die("the ESP overlaps userdata")
    if check_hashes:
        for key, item in files.items():
            log("sha256 %s ..." % item["file"])
            got = sha256_file(item["path"])
            if got != item["sha256"]:
                die("%s has sha256 %s, layout.json says %s" % (item["file"], got, item["sha256"]))
    return layout


def data_window(layout, total_sectors):
    """First sector and sectors of the Data window the driver uses: the end of userdata, header + container."""
    data = layout["data"]
    sectors = (data["header_mib"] + data["container_mib"]) * 2048
    last = layout["userdata"]["last_lba"]
    return last + 1 - sectors, sectors


def run(bundle, device, parts, write, expect_bytes, skip_hash):
    layout = load_bundle(bundle, check_hashes=not skip_hash)
    regular_ok = check_device(device)
    disk = Disk(device, write=write)
    try:
        size = disk.size()
        total = size // SECTOR
        describe_device(device, size, regular_ok)
        need = layout["userdata"]["last_lba"] + 1 + GPT_SECTORS
        if total < need:
            die("the drive has %d sectors, the layout needs at least %d" % (total, need))
        gpt = build_gpt(layout, total)
        window_first, window_sectors = data_window(layout, total)
        root_lba = layout["userdata"]["first_lba"] + layout["root"]["offset_bytes"] // SECTOR
        log("plan (%s):" % ("WRITE" if write else "dry run"))
        steps = []
        if "gpt" in parts:
            steps.append("zero LBA 0..2047 and the last %d sectors (old tables)" % GPT_SECTORS)
        if "esp" in parts:
            steps.append("write esp.img (%d MiB) at LBA %d" % (layout["esp"]["bytes"] >> 20, layout["esp"]["first_lba"]))
        if "root" in parts:
            steps.append("write userdata-root.img (%.2f GiB) at LBA %d" % (layout["root"]["bytes"] / 2**30, root_lba))
        if "data" in parts:
            steps.append("zero the Data window header: %d MiB at LBA %d" % (layout["data"]["header_mib"], window_first))
        if "gpt" in parts:
            steps.append("write MBR + GPT: esp %d..%d, %s %d..%d, backup at LBA %d" % (
                gpt["partitions"][0]["first"], gpt["partitions"][0]["last"], layout["userdata"]["label"],
                gpt["partitions"][1]["first"], gpt["partitions"][1]["last"], total - GPT_SECTORS))
        steps.append("read everything back with O_DIRECT and compare")
        for number, step in enumerate(steps, 1):
            log("  %d. %s" % (number, step))
        log("the Data window will sit at LBA %d..%d (%d MiB), %d MiB from the end of the root image" % (
            window_first, layout["userdata"]["last_lba"], window_sectors >> 11,
            (window_first - (root_lba + (layout["root"]["bytes"] + SECTOR - 1) // SECTOR)) >> 11))

        if "gpt" not in parts:
            try:
                listed = parse_gpt(disk.read, total)
            except (ValueError, EOFError) as error:
                die("without gpt in --parts the drive must already carry this layout, and its table is not readable: %s" % error)
            expected = [(p["name"], p["type"], p["first"], p["last"]) for p in gpt["partitions"]]
            if [(n, t.upper(), f, l) for n, t, f, l in listed] != [(n, t.upper(), f, l) for n, t, f, l in expected]:
                die("the table on the drive differs from the layout: %r" % (listed,))
            log("the table on the drive matches the layout")
        if not write:
            log("dry run: nothing written. To write: --write --expect-bytes %d" % size)
            return
        if expect_bytes != size:
            die("--expect-bytes %s is not the size of the drive (%d)" % (expect_bytes, size))

        if "gpt" in parts:
            log("zeroing the old tables")
            disk.write(b"\0" * (2048 * SECTOR), 0)
            disk.write(b"\0" * (GPT_SECTORS * SECTOR), size - GPT_SECTORS * SECTOR)
            disk.sync()
        if "esp" in parts:
            log("esp.img:")
            write_file(disk, layout["esp"]["path"], layout["esp"]["first_lba"] * SECTOR, "esp")
        if "root" in parts:
            log("userdata-root.img:")
            write_file(disk, layout["root"]["path"], root_lba * SECTOR, "root")
        if "data" in parts:
            disk.write(b"\0" * (layout["data"]["header_mib"] << 20), window_first * SECTOR)
        if "gpt" in parts:
            disk.write(gpt["head"], 0)
            disk.write(gpt["tail"], (total - GPT_SECTORS) * SECTOR)
        disk.sync()
        disk.drop_cache()

        log("reading back:")
        if "esp" in parts:
            verify_file(disk, layout["esp"]["path"], layout["esp"]["first_lba"] * SECTOR, "esp")
        if "root" in parts:
            verify_file(disk, layout["root"]["path"], root_lba * SECTOR, "root")
        if "data" in parts:
            if disk.read(window_first * SECTOR, layout["data"]["header_mib"] << 20) != b"\0" * (layout["data"]["header_mib"] << 20):
                raise SystemExit("VERIFY FAILED: the Data window header is not zero")
        if "gpt" in parts:
            if disk.read(0, len(gpt["head"])) != gpt["head"] or disk.read((total - GPT_SECTORS) * SECTOR, len(gpt["tail"])) != gpt["tail"]:
                raise SystemExit("VERIFY FAILED: the GPT read back differs")
        listed = parse_gpt(disk.read, total)
        for name, kind, first, last in listed:
            log("  partition %-9s %s LBA %d..%d (%.2f GiB)" % (name, kind, first, last, (last - first + 1) * SECTOR / 2**30))
        disk.rescan()
        log("OK: %s verified" % ", ".join(p for p in ALL_PARTS if p in parts))
    finally:
        disk.close()


# ---- selftest -----------------------------------------------------------------------------------------------------------

def selftest():
    import random
    random.seed(7)
    with tempfile.TemporaryDirectory() as folder:
        bundle = os.path.join(folder, "bundle")
        os.mkdir(bundle)
        # a small layout: ESP 2 MiB at LBA 2048, userdata 24 MiB at LBA 6144 (3 MiB), data window of 2+1 MiB at its end
        esp = bytes(random.getrandbits(8) for _ in range(1 << 16)) * 32
        root = bytes(random.getrandbits(8) for _ in range(1 << 16)) * 40 + b"tail-not-aligned"
        for name, data in (("esp.img", esp), ("userdata-root.img", root)):
            with open(os.path.join(bundle, name), "wb") as handle:
                handle.write(data)
        layout = {
            "schema": 1, "sector_bytes": 512,
            "esp": {"file": "esp.img", "first_lba": 2048, "sectors": 4096, "bytes": len(esp), "sha256": hashlib.sha256(esp).hexdigest()},
            "userdata": {"label": "userdata", "first_lba": 6144, "last_lba": 6144 + 24 * 2048 - 1},
            "root": {"file": "userdata-root.img", "offset_bytes": 0, "bytes": len(root), "sha256": hashlib.sha256(root).hexdigest()},
            "data": {"header_mib": 1, "container_mib": 2},
        }
        with open(os.path.join(bundle, "layout.json"), "w") as handle:
            json.dump(layout, handle)
        image = os.path.join(folder, "disk.img")
        total = 6144 + 24 * 2048 + 40001                      # not a multiple of 4096 bytes: the drive check has to cope
        with open(image, "wb") as handle:
            handle.truncate(total * SECTOR)
            handle.seek(200 * SECTOR)
            handle.write(b"old-table-junk" * 100)
            handle.seek((total - 5) * SECTOR)
            handle.write(b"old-backup-junk" * 100)
        size = total * SECTOR

        def attempt(*extra, expect_fail=None):
            try:
                run(bundle, image, *extra)
            except SystemExit as error:
                if expect_fail is None:
                    raise
                assert expect_fail in str(error), (expect_fail, str(error))
                assert os.path.getsize(image) == size, "the drive grew: a write went past its end"
                return
            assert expect_fail is None, "should have been refused: %s" % expect_fail
            assert os.path.getsize(image) == size, "the drive grew: a write went past its end"

        attempt(set(ALL_PARTS), False, None, False)                                       # dry run writes nothing
        assert open(image, "rb").read(512 * 300)[200 * SECTOR:200 * SECTOR + 14] == b"old-table-junk"
        attempt(set(ALL_PARTS), True, size + 512, False, expect_fail="--expect-bytes")
        attempt({"esp"}, True, size, False, expect_fail="without gpt in --parts")          # no table yet
        attempt(set(ALL_PARTS), True, size, False)
        with open(image, "rb") as handle:
            data = handle.read()
        assert data[2048 * 512:2048 * 512 + len(esp)] == esp
        assert data[6144 * 512:6144 * 512 + len(root)] == root
        assert b"old-table-junk" not in data and b"old-backup-junk" not in data
        listed = parse_gpt(lambda off, n: data[off:off + n], total)
        assert listed[0][0] == "esp" and listed[1][0] == "userdata" and listed[1][3] == 6144 + 24 * 2048 - 1, listed
        # a second run changes nothing but is accepted; a new ESP alone is written in place
        attempt(set(ALL_PARTS), True, size, False)
        new_esp = bytes(random.getrandbits(8) for _ in range(1 << 16)) * 32
        with open(os.path.join(bundle, "esp.img"), "wb") as handle:
            handle.write(new_esp)
        layout["esp"]["sha256"] = hashlib.sha256(new_esp).hexdigest()
        with open(os.path.join(bundle, "layout.json"), "w") as handle:
            json.dump(layout, handle)
        before_root = data[6144 * 512:6144 * 512 + len(root)]
        attempt({"esp"}, True, size, False)
        with open(image, "rb") as handle:
            data = handle.read()
        assert data[2048 * 512:2048 * 512 + len(new_esp)] == new_esp and data[6144 * 512:6144 * 512 + len(root)] == before_root
        # damage the backup table: --parts esp must refuse
        with open(image, "r+b") as handle:
            handle.seek((total - 3) * SECTOR)
            handle.write(b"\xff" * 16)
        attempt({"esp"}, True, size, False, expect_fail="not readable")
        # a file that does not match its hash, a drive too small
        with open(os.path.join(bundle, "esp.img"), "r+b") as handle:
            handle.write(b"X")
        attempt(set(ALL_PARTS), False, None, False, expect_fail="sha256")
        # the data header is zeroed on request
        with open(os.path.join(bundle, "esp.img"), "wb") as handle:
            handle.write(new_esp)
        window = layout["userdata"]["last_lba"] + 1 - 3 * 2048
        with open(image, "r+b") as handle:
            handle.seek(window * SECTOR)
            handle.write(b"EVB10DAT" + b"\x01" * 100)
        attempt(set(ALL_PARTS), True, size, False)
        with open(image, "rb") as handle:
            handle.seek(window * SECTOR)
            assert handle.read(1 << 20) == b"\0" * (1 << 20)
        small = os.path.join(folder, "small.img")
        with open(small, "wb") as handle:
            handle.truncate(10 << 20)
        try:
            run(bundle, small, set(ALL_PARTS), False, None, False)
        except SystemExit as error:
            assert "needs at least" in str(error)
        else:
            raise AssertionError("a small drive was accepted")

    # the device checks on plain facts
    for path, mounts, swaps, holders, bs, regular, fragment in (
            ("/dev/sda", [], [], [], 512, False, "not a whole NVMe namespace"),
            ("/dev/nvme0n1p2", [], [], [], 512, False, "not a whole NVMe namespace"),
            ("/dev/nvme0n1", [("/dev/nvme0n1p2", "/")], [], [], 512, False, "is mounted at /"),
            ("/dev/nvme0n1", [("/dev/mapper/x", "/m")], [], [], 512, False, None),
            ("/dev/nvme0n1", [], ["/dev/nvme0n1p3"], [], 512, False, "swap"),
            ("/dev/nvme0n1", [], [], ["dm-0"], 512, False, "held by dm-0"),
            ("/dev/nvme0n1", [], [], [], 4096, False, "not 512"),
            ("/dev/nvme0n1", [], [], [], 512, False, None),
            ("/tmp/x.img", [], [], [], 4096, True, None)):
        why = device_refusal(path, mounts, swaps, holders, bs, regular)
        assert (why is None) if fragment is None else (why is not None and fragment in why), (path, why)
    print("nvme-install selftest: ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bundle", nargs="?")
    parser.add_argument("--device", default="/dev/nvme0n1")
    parser.add_argument("--parts", default=",".join(ALL_PARTS))
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--expect-bytes", type=int)
    parser.add_argument("--skip-hash", action="store_true", help="do not hash the image files first (they are read again while verifying)")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if not args.bundle:
        parser.error("BUNDLE is required")
    parts = set(args.parts.split(","))
    if not parts <= set(ALL_PARTS) or not parts:
        parser.error("--parts takes a comma separated subset of %s" % ",".join(ALL_PARTS))
    if args.write and os.geteuid() != 0 and stat.S_ISBLK(os.stat(args.device).st_mode):
        die("writing a block device needs root")
    run(args.bundle, args.device, parts, args.write, args.expect_bytes, args.skip_hash)


if __name__ == "__main__":
    main()
