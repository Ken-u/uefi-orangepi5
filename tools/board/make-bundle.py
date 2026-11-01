#!/usr/bin/env python3
"""Collect what goes onto the Orange Pi 5 into one directory that can be copied to the board (rsync -aL --partial).

    make-bundle.py OUT_DIR --device-repo ../UniXNU-orangepi5 --payload payload.img --root userdata-root.img [--nor nor.img]

OUT_DIR gets (symbolic links for the big files, `rsync -aL` follows them):
    layout.json         the layout nvme-install.py reads (from board.toml [userdata] and [payload], with the SHA-256 of both images)
    esp.img             the payload volume of `unixnu build payload` (written to the ESP of the NVMe drive)
    userdata-root.img   the root image of `unixnu build userdata` (written at the start of the userdata partition)
    nor.img             the SPI NOR image of uefi-orangepi5 (if given)
    nvme-install.py, spi-flash.sh
    SHA256SUMS          of everything above

Needs Python 3.11 (tomllib).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tomllib

SECTOR = 512
ESP_FIRST_LBA = 2048


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as handle:
        while True:
            block = handle.read(8 << 20)
            if not block:
                return digest.hexdigest()
            digest.update(block)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out")
    parser.add_argument("--device-repo", required=True)
    parser.add_argument("--payload", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--nor")
    args = parser.parse_args()

    with open(os.path.join(args.device_repo, "board.toml"), "rb") as handle:
        board = tomllib.load(handle)
    userdata = board["userdata"]
    payload = board["payload"]
    first, last = userdata["first_lba"], userdata["last_lba"]
    esp_sectors = payload["size_mib"] * 2048
    if ESP_FIRST_LBA + esp_sectors > first:
        sys.exit("the ESP (%d sectors at %d) overlaps userdata (first LBA %d)" % (esp_sectors, ESP_FIRST_LBA, first))
    arg = next((a for a in payload["kernel_args"] if a.startswith("nvme-data-size=")), None)
    container = int(arg.split("=")[1]) if arg else 2048
    for path in (args.payload, args.root) + ((args.nor,) if args.nor else ()):
        if not os.path.isfile(path):
            sys.exit("no such file: " + path)
    esp_bytes = os.path.getsize(args.payload)
    if esp_bytes != esp_sectors * SECTOR:
        sys.exit("payload.img is %d bytes, the ESP of board.toml is %d" % (esp_bytes, esp_sectors * SECTOR))

    os.makedirs(args.out, exist_ok=True)

    def link(source, name):
        target = os.path.join(args.out, name)
        if os.path.lexists(target):
            os.unlink(target)
        os.symlink(os.path.abspath(source), target)

    here = os.path.dirname(os.path.abspath(__file__))
    link(args.payload, "esp.img")
    link(args.root, "userdata-root.img")
    if args.nor:
        link(args.nor, "nor.img")
    for name in ("nvme-install.py", "spi-flash.sh"):
        shutil.copy(os.path.join(here, name), os.path.join(args.out, name))

    root_bytes = os.path.getsize(args.root)
    if root_bytes + (1 + container + 64) * (1 << 20) > (last - first + 1) * SECTOR:
        sys.exit("the root image and the Data window do not fit the userdata partition")
    layout = {
        "schema": 1,
        "sector_bytes": SECTOR,
        "esp": {"file": "esp.img", "first_lba": ESP_FIRST_LBA, "sectors": esp_sectors, "bytes": esp_bytes,
                "sha256": sha256_file(args.payload)},
        "userdata": {"label": "userdata", "first_lba": first, "last_lba": last},
        "root": {"file": "userdata-root.img", "offset_bytes": 0, "bytes": root_bytes, "sha256": sha256_file(args.root)},
        "data": {"header_mib": 1, "container_mib": container},
    }
    if args.nor:
        layout["nor"] = {"file": "nor.img", "bytes": os.path.getsize(args.nor), "sha256": sha256_file(args.nor)}
    with open(os.path.join(args.out, "layout.json"), "w") as handle:
        json.dump(layout, handle, indent=2)
        handle.write("\n")

    names = ["layout.json", "esp.img", "userdata-root.img", "nvme-install.py", "spi-flash.sh"] + (["nor.img"] if args.nor else [])
    with open(os.path.join(args.out, "SHA256SUMS"), "w") as handle:
        for name in names:
            path = os.path.join(args.out, name)
            digest = layout["esp"]["sha256"] if name == "esp.img" else layout["root"]["sha256"] if name == "userdata-root.img" else \
                layout["nor"]["sha256"] if name == "nor.img" else sha256_file(path)
            handle.write("%s  %s\n" % (digest, name))
    print("bundle in %s:" % args.out)
    for name in names:
        print("  %-18s %12d bytes" % (name, os.path.getsize(os.path.join(args.out, name))))
    print("layout: esp LBA %d..%d, userdata LBA %d..%d, Data container %d MiB" % (
        ESP_FIRST_LBA, ESP_FIRST_LBA + esp_sectors - 1, first, last, container))


if __name__ == "__main__":
    main()
