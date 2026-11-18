#!/usr/bin/env python3
"""Extract partitions from Huawei UPDATE.APP and update.bin firmware packages.

Examples:
    python huawei_firmware_unpacker.py UPDATE.APP
    python huawei_firmware_unpacker.py UPDATE.APP --list
    python huawei_firmware_unpacker.py update.bin -p boot system vendor
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, List, Optional, Sequence, Tuple


APP_MAGIC = b"\x55\xAA\x5A\xA5"
APP_HEADER_FORMAT = "<III8sII16s16s20s14sHHH"
APP_HEADER_SIZE = struct.calcsize(APP_HEADER_FORMAT)
BIN_COMPONENT_OFFSET = 178
BIN_COMPONENT_RECORD_SIZE = 87
COPY_CHUNK_SIZE = 4 * 1024 * 1024
SPARSE_HEADER_MAGIC = 0xED26FF3A
SPARSE_HEADER_FORMAT = "<IHHHHIIII"
SPARSE_HEADER_SIZE = struct.calcsize(SPARSE_HEADER_FORMAT)
SPARSE_CHUNK_HEADER_FORMAT = "<HHII"
SPARSE_CHUNK_HEADER_SIZE = struct.calcsize(SPARSE_CHUNK_HEADER_FORMAT)
SPARSE_RAW = 0xCAC1
SPARSE_FILL = 0xCAC2
SPARSE_DONT_CARE = 0xCAC3
SPARSE_CRC32 = 0xCAC4


class FirmwareFormatError(ValueError):
    """The source file does not contain a supported firmware package."""


@dataclass(frozen=True)
class Partition:
    name: str
    offset: int
    size: int


@dataclass(frozen=True)
class SparseHeader:
    major_version: int
    minor_version: int
    file_header_size: int
    chunk_header_size: int
    block_size: int
    total_blocks: int
    total_chunks: int
    image_checksum: int


@dataclass(frozen=True)
class SparseChunk:
    chunk_type: int
    start_block: int
    end_block: int
    source_path: Path
    data_offset: int
    data_size: int


def clean_name(value: bytes) -> str:
    """Decode a package name and remove path prefixes/control characters."""
    name = value.split(b"\0", 1)[0].decode("utf-8", errors="replace").strip().lower()
    name = name.replace("\\", "/").lstrip("/")
    return "".join(char for char in name if char.isprintable()).strip()


def safe_filename(name: str) -> str:
    """Produce a single, Windows-safe filename while keeping partition names clear."""
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    result = "".join(char if char in allowed else "_" for char in name)
    result = result.strip("._")
    return result or "unnamed_partition"


def format_size(size: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{size} B"
        value /= 1024
    return f"{size} B"


def file_size(handle: BinaryIO) -> int:
    handle.seek(0, os.SEEK_END)
    size = handle.tell()
    handle.seek(0)
    return size


def read_exact(handle: BinaryIO, size: int, description: str) -> bytes:
    data = handle.read(size)
    if len(data) != size:
        raise FirmwareFormatError(f"Unexpected end of file while reading {description}.")
    return data


def is_valid_app_header(handle: BinaryIO, offset: int, total_size: int) -> bool:
    if offset + APP_HEADER_SIZE > total_size:
        return False
    handle.seek(offset)
    header = handle.read(APP_HEADER_SIZE)
    if len(header) != APP_HEADER_SIZE:
        return False
    values = struct.unpack(APP_HEADER_FORMAT, header)
    header_id, header_size, _unknown, _hardware, _sequence, payload_size = values[:6]
    name = clean_name(values[8])
    return (
        header_id == int.from_bytes(APP_MAGIC, "little")
        and APP_HEADER_SIZE <= header_size <= total_size - offset
        and bool(name)
        and all(char.isprintable() for char in name)
        and payload_size <= total_size - offset - header_size
    )


def find_app_start(handle: BinaryIO, total_size: int) -> Optional[int]:
    """Find the first valid UPDATE.APP record without loading the package in memory."""
    # Huawei packages commonly have a small preamble. 64 MiB also permits larger
    # wrappers while avoiding an expensive full scan of arbitrary multi-GB files.
    search_limit = min(total_size, 64 * 1024 * 1024)
    block_size = 1024 * 1024
    offset = 0
    tail = b""
    while offset < search_limit:
        handle.seek(offset)
        block = handle.read(min(block_size, search_limit - offset))
        if not block:
            break
        data = tail + block
        index = data.find(APP_MAGIC)
        while index != -1:
            candidate = offset - len(tail) + index
            if is_valid_app_header(handle, candidate, total_size):
                return candidate
            index = data.find(APP_MAGIC, index + 1)
        tail = data[-(len(APP_MAGIC) - 1) :]
        offset += len(block)
    return None


def parse_update_app(handle: BinaryIO, total_size: int) -> List[Partition]:
    position = find_app_start(handle, total_size)
    if position is None:
        raise FirmwareFormatError("No valid UPDATE.APP record was found.")

    partitions: List[Partition] = []
    while position + APP_HEADER_SIZE <= total_size:
        if not is_valid_app_header(handle, position, total_size):
            # A valid package ends after its final aligned payload.  Do not scan
            # payload bytes for another magic sequence, which could create false entries.
            break
        handle.seek(position)
        values = struct.unpack(APP_HEADER_FORMAT, read_exact(handle, APP_HEADER_SIZE, "UPDATE.APP header"))
        header_size = values[1]
        payload_size = values[5]
        name = clean_name(values[8])
        payload_offset = position + header_size
        partitions.append(Partition(name, payload_offset, payload_size))
        position = payload_offset + payload_size
        position += (-position) % 4

    if not partitions:
        raise FirmwareFormatError("UPDATE.APP contains no readable records.")
    return partitions


def parse_update_bin(handle: BinaryIO, total_size: int) -> List[Partition]:
    if total_size < BIN_COMPONENT_OFFSET + 2:
        raise FirmwareFormatError("File is too small to be an update.bin package.")

    handle.seek(BIN_COMPONENT_OFFSET)
    component_bytes = struct.unpack("<H", read_exact(handle, 2, "component table size"))[0]
    if component_bytes == 0 or component_bytes % BIN_COMPONENT_RECORD_SIZE != 0:
        raise FirmwareFormatError("Invalid update.bin component table size.")
    table_start = BIN_COMPONENT_OFFSET + 2
    table_end = table_start + component_bytes
    signature_start = table_end + 16
    if signature_start + 2 > total_size:
        raise FirmwareFormatError("Truncated update.bin header.")

    handle.seek(signature_start)
    signature_type = struct.unpack("<H", read_exact(handle, 2, "signature type"))[0]
    if signature_type == 0x08:
        hash_size = struct.unpack("<I", read_exact(handle, 4, "hash size"))[0]
    elif signature_type == 0x06:
        read_exact(handle, 16, "signature metadata")
        hash_size = struct.unpack("<I", read_exact(handle, 4, "hash size"))[0]
    else:
        raise FirmwareFormatError(f"Unsupported update.bin signature type: 0x{signature_type:04X}.")

    data_offset = handle.tell() + hash_size
    component_count = component_bytes // BIN_COMPONENT_RECORD_SIZE
    if data_offset > total_size:
        raise FirmwareFormatError("update.bin hash data extends past the end of the file.")

    partitions: List[Partition] = []
    handle.seek(table_start)
    for index in range(component_count):
        record = read_exact(handle, BIN_COMPONENT_RECORD_SIZE, f"component record {index + 1}")
        name = clean_name(record[:47])
        size = struct.unpack_from("<Q", record, 47)[0]
        if not name:
            raise FirmwareFormatError(f"Component record {index + 1} has no name.")
        if size > total_size - data_offset:
            raise FirmwareFormatError(f"Component '{name}' extends past the end of the package.")
        partitions.append(Partition(name, data_offset, size))
        data_offset += size

    if not partitions:
        raise FirmwareFormatError("update.bin contains no components.")
    return partitions


def detect_and_parse(handle: BinaryIO, requested_type: str) -> Tuple[str, List[Partition]]:
    total_size = file_size(handle)
    parsers = {
        "update-app": parse_update_app,
        "update-bin": parse_update_bin,
    }
    if requested_type != "auto":
        return requested_type, parsers[requested_type](handle, total_size)

    # Test the compact update.bin header first, then search for an APP record.
    # Each parser fully validates its offsets before returning any partitions.
    errors = []
    for package_type in ("update-bin", "update-app"):
        try:
            return package_type, parsers[package_type](handle, total_size)
        except FirmwareFormatError as error:
            errors.append(str(error))
    raise FirmwareFormatError("Unrecognized firmware package. " + " ".join(errors))


def print_partitions(partitions: Sequence[Partition]) -> None:
    width = max(len(partition.name) for partition in partitions)
    print(f"{'#':>3}  {'Partition':<{width}}  {'Size':>12}  Offset")
    print("-" * (width + 38))
    for index, partition in enumerate(partitions, 1):
        print(f"{index:>3}  {partition.name:<{width}}  {format_size(partition.size):>12}  0x{partition.offset:X}")
    print(f"\nTotal: {len(partitions)} entries")


def requested_names(values: Optional[Sequence[Sequence[str]]]) -> set[str]:
    names: set[str] = set()
    for group in values or ():
        for value in group:
            for name in value.split(","):
                cleaned = name.strip().removesuffix(".img").casefold()
                if cleaned:
                    names.add(cleaned)
    return names


def unique_output_path(output_dir: Path, partition_name: str, used_names: set[str]) -> Path:
    base = safe_filename(partition_name)
    candidate = base
    suffix = 2
    while candidate.casefold() in used_names:
        candidate = f"{base}_{suffix}"
        suffix += 1
    used_names.add(candidate.casefold())
    return output_dir / f"{candidate}.img"


def copy_partition(source: BinaryIO, partition: Partition, destination: Path, show_progress: bool) -> None:
    source.seek(partition.offset)
    remaining = partition.size
    written = 0
    previous_percent = -1
    with destination.open("wb") as target:
        while remaining:
            data = read_exact(source, min(COPY_CHUNK_SIZE, remaining), f"partition {partition.name}")
            target.write(data)
            remaining -= len(data)
            written += len(data)
            if show_progress and partition.size:
                percent = written * 100 // partition.size
                if percent != previous_percent:
                    print(f"\rExtracting {partition.name}: {percent:3d}%", end="", flush=True)
                    previous_percent = percent
    if show_progress:
        print()


def extract_partitions(
    source_path: Path, partitions: Sequence[Partition], output_dir: Path, overwrite: bool
) -> List[Tuple[Partition, Path]]:
    output_dir.mkdir(parents=True, exist_ok=True)
    used_names: set[str] = set()
    extracted: List[Tuple[Partition, Path]] = []
    show_progress = sys.stdout.isatty()
    with source_path.open("rb") as source:
        for partition in partitions:
            destination = unique_output_path(output_dir, partition.name, used_names)
            if destination.exists() and not overwrite:
                raise FileExistsError(f"Output file already exists: {destination} (use --overwrite to replace it)")
            print(f"Extracting {partition.name} -> {destination.name} ({format_size(partition.size)})")
            copy_partition(source, partition, destination, show_progress)
            extracted.append((partition, destination))
    return extracted


def parse_sparse_image(path: Path) -> Tuple[SparseHeader, List[SparseChunk]]:
    """Read and validate an Android sparse image without loading its data chunks."""
    image_size = path.stat().st_size
    with path.open("rb") as source:
        raw_header = read_exact(source, SPARSE_HEADER_SIZE, f"sparse header in {path.name}")
        values = struct.unpack(SPARSE_HEADER_FORMAT, raw_header)
        magic, *header_values = values
        header = SparseHeader(*header_values)
        if magic != SPARSE_HEADER_MAGIC:
            raise FirmwareFormatError(f"'{path.name}' is not an Android sparse image.")
        if header.major_version != 1:
            raise FirmwareFormatError(f"'{path.name}' uses unsupported sparse version {header.major_version}.")
        if header.file_header_size < SPARSE_HEADER_SIZE or header.chunk_header_size < SPARSE_CHUNK_HEADER_SIZE:
            raise FirmwareFormatError(f"'{path.name}' has an invalid sparse header size.")
        if header.block_size == 0:
            raise FirmwareFormatError(f"'{path.name}' has an invalid sparse block size.")
        if header.file_header_size > image_size:
            raise FirmwareFormatError(f"'{path.name}' has a truncated sparse header.")

        source.seek(header.file_header_size)
        current_block = 0
        data_chunks: List[SparseChunk] = []
        for index in range(header.total_chunks):
            chunk_start_offset = source.tell()
            raw_chunk_header = read_exact(source, SPARSE_CHUNK_HEADER_SIZE, f"sparse chunk {index + 1} in {path.name}")
            chunk_type, _reserved, chunk_blocks, total_size = struct.unpack(SPARSE_CHUNK_HEADER_FORMAT, raw_chunk_header)
            if total_size < header.chunk_header_size:
                raise FirmwareFormatError(f"'{path.name}' has an invalid size for sparse chunk {index + 1}.")
            data_offset = chunk_start_offset + header.chunk_header_size
            data_size = total_size - header.chunk_header_size
            if data_offset + data_size > image_size:
                raise FirmwareFormatError(f"'{path.name}' is truncated in sparse chunk {index + 1}.")

            start_block = current_block
            end_block = start_block + chunk_blocks
            if end_block > header.total_blocks:
                raise FirmwareFormatError(f"'{path.name}' sparse chunks exceed the declared block count.")
            if chunk_type == SPARSE_RAW:
                if data_size != chunk_blocks * header.block_size:
                    raise FirmwareFormatError(f"'{path.name}' has an invalid RAW sparse chunk {index + 1}.")
                data_chunks.append(SparseChunk(chunk_type, start_block, end_block, path, data_offset, data_size))
                current_block = end_block
            elif chunk_type == SPARSE_FILL:
                if data_size != 4:
                    raise FirmwareFormatError(f"'{path.name}' has an invalid FILL sparse chunk {index + 1}.")
                data_chunks.append(SparseChunk(chunk_type, start_block, end_block, path, data_offset, data_size))
                current_block = end_block
            elif chunk_type == SPARSE_DONT_CARE:
                if data_size != 0:
                    raise FirmwareFormatError(f"'{path.name}' has an invalid DONT_CARE sparse chunk {index + 1}.")
                current_block = end_block
            elif chunk_type == SPARSE_CRC32:
                if chunk_blocks != 0 or data_size != 4:
                    raise FirmwareFormatError(f"'{path.name}' has an invalid CRC32 sparse chunk {index + 1}.")
            else:
                raise FirmwareFormatError(f"'{path.name}' has unsupported sparse chunk type 0x{chunk_type:04X}.")
            source.seek(data_offset + data_size)

    if current_block != header.total_blocks:
        raise FirmwareFormatError(f"'{path.name}' sparse chunks do not cover the declared block count.")
    return header, data_chunks


def sparse_merge_segments(images: Sequence[List[SparseChunk]], total_blocks: int) -> List[Tuple[int, int, SparseChunk]]:
    """Overlay sparse chunks by block range; later input files take precedence."""
    boundaries = {0, total_blocks}
    for chunks in images:
        for chunk in chunks:
            boundaries.add(chunk.start_block)
            boundaries.add(chunk.end_block)

    sorted_boundaries = sorted(boundaries)
    positions = [0] * len(images)
    segments: List[Tuple[int, int, SparseChunk]] = []
    for start, end in zip(sorted_boundaries, sorted_boundaries[1:]):
        selected: Optional[SparseChunk] = None
        for image_index, chunks in enumerate(images):
            while positions[image_index] < len(chunks) and chunks[positions[image_index]].end_block <= start:
                positions[image_index] += 1
            if positions[image_index] < len(chunks):
                candidate = chunks[positions[image_index]]
                if candidate.start_block <= start and candidate.end_block >= end:
                    selected = candidate
        if selected is None:
            continue
        if segments and segments[-1][1] == start and segments[-1][2] == selected:
            segments[-1] = (segments[-1][0], end, selected)
        else:
            segments.append((start, end, selected))
    return segments


def merge_sparse_images(input_paths: Sequence[Path], output_path: Path, overwrite: bool) -> None:
    """Merge two or more sparse fragments into one valid sparse image."""
    if len(input_paths) < 2:
        raise FirmwareFormatError("At least two sparse super fragments are required for merging.")

    parsed = [parse_sparse_image(path) for path in input_paths]
    reference_header = parsed[0][0]
    for path, (header, _chunks) in zip(input_paths[1:], parsed[1:]):
        if header.block_size != reference_header.block_size or header.total_blocks != reference_header.total_blocks:
            raise FirmwareFormatError(
                f"'{path.name}' does not match the sparse block size or total block count of '{input_paths[0].name}'."
            )

    segments = sparse_merge_segments([chunks for _header, chunks in parsed], reference_header.total_blocks)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists() and not overwrite:
        raise FileExistsError(f"Merged output already exists: {output_path} (use --overwrite to replace it)")
    temporary_path = output_path.with_name(f"{output_path.name}.partial")
    if temporary_path.exists() and not overwrite:
        raise FileExistsError(f"Temporary merged output already exists: {temporary_path}")

    output_chunk_count = len(segments)
    previous_block = 0
    for start, end, _chunk in segments:
        if start > previous_block:
            output_chunk_count += 1
        previous_block = end
    if previous_block < reference_header.total_blocks:
        output_chunk_count += 1

    raw_bytes = sum((end - start) * reference_header.block_size for start, end, chunk in segments if chunk.chunk_type == SPARSE_RAW)
    copied_bytes = 0
    last_percent = -1
    show_progress = sys.stdout.isatty()

    try:
        with temporary_path.open("wb") as output:
            output.write(struct.pack(
                SPARSE_HEADER_FORMAT,
                SPARSE_HEADER_MAGIC,
                reference_header.major_version,
                reference_header.minor_version,
                SPARSE_HEADER_SIZE,
                SPARSE_CHUNK_HEADER_SIZE,
                reference_header.block_size,
                reference_header.total_blocks,
                output_chunk_count,
                0,
            ))
            source_handles = {path: path.open("rb") for path in input_paths}
            try:
                previous_block = 0
                for start, end, chunk in segments:
                    if start > previous_block:
                        output.write(struct.pack(SPARSE_CHUNK_HEADER_FORMAT, SPARSE_DONT_CARE, 0, start - previous_block, SPARSE_CHUNK_HEADER_SIZE))
                    block_count = end - start
                    if chunk.chunk_type == SPARSE_FILL:
                        source = source_handles[chunk.source_path]
                        source.seek(chunk.data_offset)
                        fill_value = read_exact(source, 4, f"FILL value in {chunk.source_path.name}")
                        output.write(struct.pack(SPARSE_CHUNK_HEADER_FORMAT, SPARSE_FILL, 0, block_count, SPARSE_CHUNK_HEADER_SIZE + 4))
                        output.write(fill_value)
                    else:
                        source = source_handles[chunk.source_path]
                        byte_count = block_count * reference_header.block_size
                        source.seek(chunk.data_offset + (start - chunk.start_block) * reference_header.block_size)
                        output.write(struct.pack(SPARSE_CHUNK_HEADER_FORMAT, SPARSE_RAW, 0, block_count, SPARSE_CHUNK_HEADER_SIZE + byte_count))
                        remaining = byte_count
                        while remaining:
                            data = read_exact(source, min(COPY_CHUNK_SIZE, remaining), f"merged data from {chunk.source_path.name}")
                            output.write(data)
                            remaining -= len(data)
                            copied_bytes += len(data)
                            if show_progress and raw_bytes:
                                percent = copied_bytes * 100 // raw_bytes
                                if percent != last_percent:
                                    print(f"\rMerging sparse super: {percent:3d}%", end="", flush=True)
                                    last_percent = percent
                    previous_block = end
                if previous_block < reference_header.total_blocks:
                    output.write(struct.pack(
                        SPARSE_CHUNK_HEADER_FORMAT,
                        SPARSE_DONT_CARE,
                        0,
                        reference_header.total_blocks - previous_block,
                        SPARSE_CHUNK_HEADER_SIZE,
                    ))
            finally:
                for source in source_handles.values():
                    source.close()
        if show_progress:
            print()
        os.replace(temporary_path, output_path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise


def merge_extracted_super(extracted: Sequence[Tuple[Partition, Path]], output_dir: Path, overwrite: bool) -> Optional[Path]:
    super_paths = [path for partition, path in extracted if partition.name == "super"]
    if len(super_paths) < 2:
        print("Sparse super merge skipped: fewer than two super partitions were extracted.")
        return None
    merged_path = output_dir / "super_merged.img"
    print(f"Merging {len(super_paths)} sparse super fragments -> {merged_path.name}")
    merge_sparse_images(super_paths, merged_path, overwrite)
    print(f"Merged sparse super image: {merged_path}")
    return merged_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Auto-detect and extract Huawei UPDATE.APP or update.bin firmware packages.",
        epilog="With only FIRMWARE specified, every partition is extracted.",
    )
    parser.add_argument("firmware", type=Path, help="Path to UPDATE.APP or update.bin")
    parser.add_argument("-l", "--list", action="store_true", help="Only list package entries; do not extract")
    parser.add_argument(
        "-p", "--partition", action="append", nargs="+", metavar="NAME",
        help="Extract only these partitions. Accepts spaces or commas: -p boot system,vendor",
    )
    parser.add_argument("-o", "--output-dir", type=Path, help="Destination directory (default: <firmware>_extracted)")
    parser.add_argument("--type", choices=("auto", "update-app", "update-bin"), default="auto", help="Package type override (default: auto)")
    parser.add_argument(
        "--merge-super",
        action="store_true",
        help="After extraction, merge two or more sparse super fragments into super_merged.img",
    )
    parser.add_argument("--overwrite", action="store_true", help="Replace existing output images")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.firmware.is_file():
        print(f"Error: firmware file not found: {args.firmware}", file=sys.stderr)
        return 2

    try:
        with args.firmware.open("rb") as source:
            package_type, partitions = detect_and_parse(source, args.type)
        print(f"Detected: {package_type} ({len(partitions)} entries)")
        if args.list:
            if args.merge_super:
                raise FirmwareFormatError("--merge-super cannot be used with --list because no images are extracted.")
            print_partitions(partitions)
            return 0

        names = requested_names(args.partition)
        selected = [partition for partition in partitions if not names or partition.name.removesuffix(".img").casefold() in names]
        if names and not selected:
            raise FirmwareFormatError("None of the requested partition names were found. Use --list to see available names.")
        output_dir = args.output_dir or args.firmware.with_name(f"{args.firmware.stem}_extracted")
        extracted = extract_partitions(args.firmware, selected, output_dir, args.overwrite)
        if args.merge_super:
            merge_extracted_super(extracted, output_dir, args.overwrite)
        print(f"Done: extracted {len(selected)} image(s) to {output_dir}")
        return 0
    except (FirmwareFormatError, OSError, struct.error) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
