#!/usr/bin/env python3
"""Compile all fifteen Playford Greensleeves divisions with their source ground.

Only the checked-in Mutopia 1730 LilyPond edition is accepted. The violin's
fifteen different divisions and each original volta 2 are retained. The eight
source ground-bass measures accompany every division on a piano bass staff;
no extra harmony or fabricated melody is added. Source tempo half=80 becomes
quarter=160. This is an explicit violin/piano adaptation of the complete piece.
"""
from __future__ import annotations

import argparse
import copy
from fractions import Fraction as F
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from compile_bach_gavotte import DIVISIONS, Event, Pitch, VoiceParser, add, write_note

SOURCE_SHA256 = "67ab58455b600931aa85b06056f0611fc35468a1161c19007360804aeca14601"
SOURCE_URL = "https://www.mutopiaproject.org/ftp/Anonymous/division-violin-two-27/division-violin-two-27.ly"


def block(text: str, start: int) -> tuple[str, int]:
    """Return the contents of a source brace at start, and its end offset."""
    if text[start] != "{":
        raise ValueError("Expected a LilyPond music block")
    level, position = 1, start + 1
    while level and position < len(text):
        level += (text[position] == "{") - (text[position] == "}")
        position += 1
    if level:
        raise ValueError("Unclosed source music block")
    return text[start + 1:position - 1], position


def voice_block(text: str, name: str) -> tuple[str, str]:
    match = re.search(r"\b" + re.escape(name) + r"\s*=\s*\\relative\s+([a-g][',]*)\s*\{", text)
    if match is None:
        raise ValueError(f"Missing source voice {name}")
    return block(text, match.end() - 1)[0], match[1]


def repeat_blocks(text: str) -> list[str]:
    result = []
    pattern = re.compile(r'\\repeat\s+"volta"\s+2\s*\{')
    position = 0
    while match := pattern.search(text, position):
        body, position = block(text, match.end() - 1)
        result.append(body)
    return result


def relative_reference(pitch: Pitch) -> str:
    accidental = {0: "", 1: "is", -1: "es", 2: "isis", -2: "eses"}[pitch.alter]
    octave = "'" * max(0, pitch.octave - 3) + "," * max(0, 3 - pitch.octave)
    return pitch.step + accidental + octave


def parse_division(text: str, reference: str) -> VoiceParser:
    # Start each explicitly numbered source division with the preceding
    # relative pitch; its opening written duration normally specifies rhythm.
    text = re.sub(r"%[^\n]*", "", text)
    text = re.sub(r'\\mark\s+\\markup\s*\{\s*\\circle\s+"\d+"\s*\}', "", text)
    text = re.sub(r"\\set\s+suggestAccidentals\s*=\s*##[tf]", "", text)
    text = re.sub(r"\\(?:break|pageBreak)\b", "", text)
    # The source includes english.ly. Convert its spelling into the relative
    # parser's equivalent names without altering diatonic pitch or octave.
    alterations = {"f": "es", "ff": "eses", "s": "is", "ss": "isis"}
    text = re.sub(r"\b([a-g])(ff|ss|f|s)(?=[',\d.\s\[\](){}|<>]|$)", lambda m: m[1] + alterations[m[2]], text)
    parser = VoiceParser(text, reference)
    parser.parse()
    if parser.active_slurs:
        raise ValueError("Unclosed source slur")
    if parser.position != 48:
        raise ValueError(f"Each complete source division/ground must contain 48 quarter beats, got {parser.position}")
    if any(value % 6 != 0 for value in parser.barlines):
        raise ValueError("Source barline is not at a 3/2 boundary")
    return parser


def measures(events: list[Event]) -> list[list[Event]]:
    bars: list[list[Event]] = [[]]
    used = F(0)
    for event in events:
        if used == 6:
            bars.append([])
            used = F(0)
        if used + event.duration > 6:
            raise ValueError("Source event unexpectedly crosses a measured bar")
        bars[-1].append(copy.deepcopy(event))
        used += event.duration
    if len(bars) != 8 or used != 6:
        raise ValueError("Each full division must contain eight 3/2 measures")
    return bars


def event_stream(parsers: list[VoiceParser]) -> list[dict]:
    result = []
    position = F(0)
    for parser in parsers:
        for event in parser.events:
            for pitch in event.pitches:
                result.append({"start": str(position), "duration": str(event.duration), "midi": pitch.midi})
            position += event.duration
    return result


def build_greensleeves_with_report(source: Path) -> tuple[bytes, dict]:
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError("Greensleeves source differs from the verified Mutopia edition")
    text = source.read_text()
    violin_body, reference = voice_block(text, "violin")
    divisions = repeat_blocks(violin_body)
    if len(divisions) != 15:
        raise ValueError("The complete Greensleeves source has fifteen divisions")
    parsers = []
    violin = []
    for index, body in enumerate(divisions, 1):
        if not re.search(r'\\circle\s+"' + str(index) + r'"', body):
            raise ValueError(f"Missing source division number {index}")
        if index == 5:
            # The source omits the first quarter duration here. Its MIDI
            # inherits dotted halves from division 4, overfilling the first
            # 3/2 bar by six quarter beats. Realize the three unmarked notes
            # as quarters to preserve the eight-bar division/ground structure.
            marker = "f' bf, g' f4."
            if body.count(marker) != 1:
                raise ValueError("The documented source rhythm correction changed")
            body = body.replace(marker, "f'4 bf, g' f4.", 1)
        parser = parse_division(body, reference)
        parsers.append(parser)
        violin.extend(measures(parser.events))
        reference = relative_reference(parser.previous)
    bass_body, bass_reference = voice_block(text, "groundbass")
    bass_repeats = repeat_blocks(bass_body)
    if len(bass_repeats) != 1:
        raise ValueError("Expected the source's single ground-bass pattern")
    bass_parser = parse_division(bass_repeats[0], bass_reference)
    ground = measures(bass_parser.events)
    piano = [copy.deepcopy(bar) for _ in range(15) for bar in ground]
    if len(violin) != 120 or len(piano) != 120:
        raise ValueError("The full arrangement must contain all 120 printed measures")
    credit = ("Anonymous, Greensleeves to a Ground with Division; complete fifteen divisions from the 1705 fourth edition "
              "of Playford's Division Violin, second part; typeset by Allen Garvin, Mutopia-2009/12/15-1730, Public Domain. "
              "Music Viewer complete violin/piano adaptation: all fifteen source divisions, all source pitches, "
              "slurs and each original volta 2 retained; the first three implicit notes of division 5 are explicitly "
              "notated as quarters, correcting the source's inherited dotted halves which overfill its first 3/2 measure. "
              "The source's own eight-measure ground bass accompanies each division "
              "on a piano bass staff. No extra harmony is added. Source half-note=80, quarter-note=160.")
    score = ET.Element("score-partwise", version="4.0")
    add(add(score, "work"), "work-title", "绿袖子：十五段变奏 / Greensleeves")
    identification = add(score, "identification")
    add(identification, "creator", "Anonymous · Playford 1705", type="composer")
    add(identification, "rights", credit)
    listing = add(score, "part-list")
    for index, (instrument, program) in enumerate([("Violin / 小提琴", 41), ("Piano / 钢琴", 1)], 1):
        declaration = add(listing, "score-part", id=f"P{index}")
        add(declaration, "part-name", instrument)
        add(add(declaration, "score-instrument", id=f"I{index}"), "instrument-name", instrument)
        midi = add(declaration, "midi-instrument", id=f"I{index}")
        add(midi, "midi-channel", index)
        add(midi, "midi-program", program)
    for part_index, lane in enumerate([violin, piano], 1):
        part = add(score, "part", id=f"P{part_index}")
        for index, bar in enumerate(lane):
            measure = add(part, "measure", id=f"P{part_index}-m{index + 1}", number=str(index + 1))
            if index % 8 == 0:
                if index:
                    add(measure, "print", **{"new-system": "yes"})
                direction = add(measure, "direction", placement="above")
                add(add(direction, "direction-type"), "words", f"Variation {index // 8 + 1} / 变奏 {index // 8 + 1}")
                add(add(measure, "barline", location="left"), "repeat", direction="forward")
            if index == 0:
                attrs = add(measure, "attributes")
                add(attrs, "divisions", DIVISIONS)
                key = add(attrs, "key")
                add(key, "fifths", -2)
                add(key, "mode", "minor")
                time = add(attrs, "time")
                add(time, "beats", 3)
                add(time, "beat-type", 2)
                clef = add(attrs, "clef")
                add(clef, "sign", "G" if part_index == 1 else "F")
                add(clef, "line", 2 if part_index == 1 else 4)
                direction = add(measure, "direction")
                met = add(add(direction, "direction-type"), "metronome")
                add(met, "beat-unit", "half")
                add(met, "per-minute", 80)
                add(direction, "sound", tempo="160")
            for serial, event in enumerate(bar, 1):
                write_note(measure, event, 1, f"P{part_index}-m{index + 1}-v1-n{serial}")
            if index % 8 == 7:
                line = add(measure, "barline", location="right")
                if index == 119:
                    add(line, "bar-style", "light-heavy")
                add(line, "repeat", direction="backward", times="2")
    # Both parts are monophonic staves; let the engraver choose stem direction
    # from pitch rather than inheriting the two-voice Bach writer's stem rule.
    for note in score.findall("part/measure/note"):
        for stem in note.findall("stem"):
            note.remove(stem)
    ET.indent(score, space="  ")
    data = ET.tostring(score, encoding="utf-8", xml_declaration=True)
    violin_source = event_stream(parsers)
    bass_source = event_stream([bass_parser])
    report = {"sourceURL": SOURCE_URL, "sourceSHA256": digest,
              "sourceDivisions": 15, "sourceMeasuresPerDivision": 8, "writtenMeasures": 120,
              "sourceQuarterBeatsBeforeRhythmCorrection": "726",
              "sourceRhythmCorrections": [{"division": 5, "measure": 33, "notes": 3,
                  "sourceImplicitQuarterBeatsPerNote": "3", "realizedQuarterBeatsPerNote": "1",
                  "reason": "The omitted opening duration inherits dotted halves and overfills the source 3/2 bar. Explicit quarters restore its eight-bar ground structure."}],
              "performedMeasureVisits": 240, "writtenQuarterBeats": "720", "performedQuarterBeats": "1440",
              "tempoQPM": 160, "musicDurationSeconds": 540,
              "writtenViolinPitchEvents": len(violin_source), "writtenGroundPitchEvents": len(bass_source) * 15,
              "performedNoteAttacks": (len(violin_source) + len(bass_source) * 15) * 2,
              "originalRepeatGroups": [[i * 8 + 1, i * 8 + 8] for i in range(15)],
              "sourceViolinEvents": violin_source, "sourceGroundEvents": bass_source,
              "credit": credit, "xmlSHA256": hashlib.sha256(data).hexdigest()}
    return data, report


def build_greensleeves(source: Path) -> bytes:
    return build_greensleeves_with_report(source)[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    xml, report = build_greensleeves_with_report(args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(xml)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("sourceViolinEvents", "sourceGroundEvents", "credit")}, ensure_ascii=False, indent=2))
