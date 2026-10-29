#!/usr/bin/env python3
"""Normalize Grand Piano ranges for Apple's AUSampler without changing samples.

Input: unmodified GeneralUser GS 2.0.3 (pinned below).
Each piano preset zone gets an instrument with pre-intersected sample ranges.
This avoids AUSampler retaining sample zones whose preset/instrument ranges do
not overlap. Other presets, original instruments, modulators and PCM stay intact.
"""

import argparse
import hashlib
import json
import struct
from pathlib import Path

SOURCE_SHA256 = '9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe'
KEY_RANGE, VEL_RANGE, INSTRUMENT, SAMPLE_ID = 43, 44, 41, 53


def chunks(data):
    position = 0
    while position < len(data):
        tag, size = struct.unpack_from('<4sI', data, position)
        end = position + 8 + size
        assert end <= len(data), 'Truncated RIFF chunk'
        yield tag, data[position + 8:end]
        position = end + size % 2
    assert position == len(data)


def chunk(tag, data):
    return struct.pack('<4sI', tag, len(data)) + data + b'\0' * (len(data) % 2)


def records(data, fmt):
    size = struct.calcsize(fmt)
    assert len(data) % size == 0
    return list(struct.iter_unpack(fmt, data))


def encode(rows, fmt):
    return b''.join(struct.pack(fmt, *row) for row in rows)


def zones(bags, generators, modulators, begin, end):
    return [(generators[bags[i][0]:bags[i + 1][0]],
             modulators[bags[i][1]:bags[i + 1][1]]) for i in range(begin, end)]


def ranges(global_generators, local_generators):
    values = dict(global_generators)
    values.update(local_generators)
    return tuple((values.get(op, 0x7F00) & 255, values.get(op, 0x7F00) >> 8)
                 for op in (KEY_RANGE, VEL_RANGE))


def intersect(a, b):
    result = tuple((max(x[0], y[0]), min(x[1], y[1])) for x, y in zip(a, b))
    return result if all(lo <= hi for lo, hi in result) else None


def clipped_generators(generators, limits):
    # SF2 requires keyRange/velRange first and sampleID last.
    return [(op, lo | (hi << 8)) for op, (lo, hi) in zip((KEY_RANGE, VEL_RANGE), limits)] + [
        row for row in generators if row[0] not in (KEY_RANGE, VEL_RANGE)]


def normalize(data):
    assert hashlib.sha256(data).hexdigest() == SOURCE_SHA256, 'Expected original GeneralUser GS 2.0.3'
    assert data[:4] == b'RIFF' and data[8:12] == b'sfbk'
    outer = list(chunks(data[12:]))
    pdta_index = next(i for i, (tag, body) in enumerate(outer) if tag == b'LIST' and body[:4] == b'pdta')
    tables = dict(chunks(outer[pdta_index][1][4:]))
    phdr = records(tables[b'phdr'], '<20sHHHIII')
    pbag = records(tables[b'pbag'], '<HH')
    pgen = records(tables[b'pgen'], '<HH')
    pmod = records(tables[b'pmod'], '<HHhHH')
    inst = records(tables[b'inst'], '<20sH')
    ibag = records(tables[b'ibag'], '<HH')
    igen = records(tables[b'igen'], '<HH')
    imod = records(tables[b'imod'], '<HHhHH')
    original_inst = inst[:]
    original_ibag, original_igen, original_imod = ibag[:], igen[:], imod[:]

    preset_index = next(i for i, row in enumerate(phdr[:-1]) if row[1:3] == (0, 0))
    preset_zones = zones(pbag, pgen, pmod, phdr[preset_index][3], phdr[preset_index + 1][3])
    preset_global = preset_zones[0][0] if INSTRUMENT not in dict(preset_zones[0][0]) else []

    # Remove terminal records; all original zone indexes remain valid.
    inst = inst[:-1]
    igen, imod = igen[:ibag[-1][0]], imod[:ibag[-1][1]]
    ibag = ibag[:-1]
    expected = []
    combinations = 0
    local_index = 0
    for zone_index, (preset_generators, _) in enumerate(preset_zones):
        if INSTRUMENT not in dict(preset_generators):
            continue
        source_id = dict(preset_generators)[INSTRUMENT]
        source_zones = zones(original_ibag, original_igen, original_imod,
                             original_inst[source_id][1], original_inst[source_id + 1][1])
        instrument_global = source_zones[0][0] if SAMPLE_ID not in dict(source_zones[0][0]) else []
        limits = ranges(preset_global, preset_generators)
        new_id = len(inst)
        inst.append((f'MV Piano {local_index:02d}'.encode().ljust(20, b'\0'), len(ibag)))
        local_index += 1
        kept = 0
        for generators, modulators in source_zones:
            if SAMPLE_ID in dict(generators):
                combinations += 1
                overlap = intersect(limits, ranges(instrument_global, generators))
                if overlap is None:
                    continue
                generators = clipped_generators(generators, overlap)
                expected.append((overlap, dict(generators)[SAMPLE_ID]))
                kept += 1
            ibag.append((len(igen), len(imod)))
            igen.extend(generators)
            imod.extend(modulators)
        assert kept, 'Unexpected empty piano instrument'
        for index in range(pbag[phdr[preset_index][3] + zone_index][0],
                           pbag[phdr[preset_index][3] + zone_index + 1][0]):
            if pgen[index][0] == INSTRUMENT:
                pgen[index] = (INSTRUMENT, new_id)

    inst.append((b'EOI'.ljust(20, b'\0'), len(ibag)))
    ibag.append((len(igen), len(imod)))
    igen.append((0, 0))
    imod.append((0, 0, 0, 0, 0))
    assert max(len(inst), len(ibag), len(igen), len(imod)) < 65536, 'SF2 table exceeds UInt16 indexes'
    tables[b'pgen'] = encode(pgen, '<HH')
    tables[b'inst'] = encode(inst, '<20sH')
    tables[b'ibag'] = encode(ibag, '<HH')
    tables[b'igen'] = encode(igen, '<HH')
    tables[b'imod'] = encode(imod, '<HHhHH')
    outer[pdta_index] = (b'LIST', b'pdta' + b''.join(chunk(tag, body) for tag, body in tables.items()))
    body = b'sfbk' + b''.join(chunk(tag, payload) for tag, payload in outer)
    output = chunk(b'RIFF', body)
    report = {'sourceSHA256': SOURCE_SHA256, 'outputSHA256': hashlib.sha256(output).hexdigest(),
              'preset': 'bank 0 / program 0 / Grand Piano', 'privateInstruments': local_index,
              'unclippedCombinations': combinations, 'validSampleZones': len(expected),
              'pcmUnchanged': True, 'otherPresetsUnchanged': True,
              'probeSampleCounts': [
                  {'pitch': pitch, 'velocity': velocity,
                   'samples': sum(all(lo <= value <= hi for value, (lo, hi) in zip((pitch, velocity), bounds))
                                  for bounds, _ in expected)}
                  for pitch, velocity in [(76, 33), (60, 33), (45, 76)]]}
    return output, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    assert args.source.resolve() != args.destination.resolve(), 'Keep the original input intact'
    output, report = normalize(args.source.read_bytes())
    args.destination.write_bytes(output)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
