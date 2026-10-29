#!/usr/bin/env python3
"""Compile the complete, checked-in Mutopia BWV 1006 Gavotte source.

This is deliberately a checked LilyPond subset, not a general LilyPond parser.
The source's complete two-voice pitch/time stream can be compared against its
official MIDI before the explicitly documented ornament realization is applied.
"""
from __future__ import annotations

from dataclasses import dataclass, field, replace
from fractions import Fraction as F
from pathlib import Path
import argparse
import copy
import hashlib
import json
import re
import xml.etree.ElementTree as ET


STEPS = "cdefgab"
NATURAL = dict(zip(STEPS, (0, 2, 4, 5, 7, 9, 11)))
ALTERATIONS = {"": 0, "is": 1, "isis": 2, "es": -1, "eses": -2}
E_MAJOR = {"f": 1, "c": 1, "g": 1, "d": 1}
TYPE_NAMES = {1: "whole", 2: "half", 4: "quarter", 8: "eighth", 16: "16th", 32: "32nd", 64: "64th"}
DIVISIONS = 24
SOURCE_SHA256 = "d48ee7de665d64308481e194d7a1243abd9245176e0e41b5201133e1b7ddfb7b"
NOTE = r"(?:[a-g](?:isis|eses|is|es)?|[rs])[',]*(?:\d+)?\.*(?:\*\d+)?"
TOKEN = re.compile(r'\s*(\\[A-Za-z]+|volta|<[^>]+>\d*\.*|' + NOTE + r'|\d+/\d+|\d+|"[^"]*"|[{}\[\]()|])')
PITCH = re.compile(r"([a-g])(isis|eses|is|es)?([',]*)$")
SINGLE = re.compile(r"([a-g](?:isis|eses|is|es)?|[rs])([',]*)(\d+)?(\.*)(?:\*(\d+))?$")


@dataclass(frozen=True)
class Pitch:
    step: str
    alter: int
    octave: int

    @property
    def diatonic(self) -> int:
        return self.octave * 7 + STEPS.index(self.step)

    @property
    def midi(self) -> int:
        return (self.octave + 1) * 12 + NATURAL[self.step] + self.alter


@dataclass
class Event:
    pitches: tuple[Pitch, ...]
    duration: F
    denominator: int
    dots: int = 0
    kind: str = "note"
    slur_starts: list[int] = field(default_factory=list)
    slur_stops: list[int] = field(default_factory=list)
    tuplet: F | None = None
    tuplet_start: bool = False
    tuplet_stop: bool = False
    ornament: str | None = None
    tie_start: bool = False
    tie_stop: bool = False


def duration(denominator: int, dots: int = 0) -> F:
    return F(4, denominator) * sum((F(1, 2**i) for i in range(dots + 1)), F(0))


class VoiceParser:
    def __init__(self, text: str, reference: str):
        self.tokens: list[str] = []
        text = re.sub(r"%[^\n]*", "", text)
        position = 0
        while position < len(text):
            match = TOKEN.match(text, position)
            if match is None:
                if not text[position:].strip():
                    break
                raise ValueError(f"Unrecognized LilyPond near {text[position:position+60]!r}")
            self.tokens.append(match.group(1))
            position = match.end()
        self.index = 0
        first = PITCH.fullmatch(reference)
        assert first is not None
        self.previous = Pitch(first[1], ALTERATIONS[first[2] or ""], 3 + first[3].count("'") - first[3].count(","))
        self.denominator, self.dots = 4, 0
        self.events: list[Event] = []
        self.active_slurs: list[int] = []
        self.next_slur = 1
        self.position = F(0)
        self.barlines: list[F] = []
        self.repeat_spans: list[tuple[F, F]] = []
        self.pickup: F | None = None

    def pitch(self, token: str, previous: Pitch) -> Pitch:
        match = PITCH.fullmatch(token)
        if match is None:
            raise ValueError(f"Bad relative pitch {token}")
        step, accidental, marks = match.groups()
        delta = (STEPS.index(step) - STEPS.index(previous.step) + 3) % 7 - 3
        diatonic = previous.diatonic + delta + 7 * (marks.count("'") - marks.count(","))
        return Pitch(step, ALTERATIONS[accidental or ""], diatonic // 7)

    def take(self) -> str:
        token = self.tokens[self.index]
        self.index += 1
        return token

    def parse(self, scale: F = F(1), closing: bool = False) -> None:
        while self.index < len(self.tokens):
            token = self.take()
            if token == "}":
                if not closing:
                    raise ValueError("Unexpected close brace")
                return
            if token == "{":
                self.parse(scale, True)
            elif token == "\\repeat":
                if (self.take(), self.take(), self.take()) != ("volta", "2", "{"):
                    raise ValueError("Only the source's volta 2 is supported")
                start = self.position
                self.parse(scale, True)
                self.repeat_spans.append((start, self.position))
            elif token == "\\times":
                ratio = F(self.take())
                if self.take() != "{" or ratio != F(2, 3):
                    raise ValueError("Unexpected tuplet")
                start = len(self.events)
                self.parse(scale * ratio, True)
                if start == len(self.events):
                    raise ValueError("Empty tuplet")
                self.events[start].tuplet_start = True
                self.events[-1].tuplet_stop = True
            elif token == "\\partial":
                value = F(4, int(self.take()))
                if self.position or self.pickup is not None:
                    raise ValueError("Unexpected partial")
                self.pickup = value
            elif token == "\\bar":
                if self.take() != '"|."':
                    raise ValueError("Unexpected final bar")
            elif token in ("\\trill", "\\mordent"):
                if not self.events or not self.events[-1].pitches:
                    raise ValueError("Ornament without pitched note")
                self.events[-1].ornament = token[1:]
            elif token == "(":
                if not self.events or not self.events[-1].pitches:
                    raise ValueError("Slur without pitched note")
                number = self.next_slur
                self.next_slur += 1
                self.active_slurs.append(number)
                self.events[-1].slur_starts.append(number)
            elif token == ")":
                if not self.active_slurs:
                    raise ValueError("Unmatched slur stop")
                self.events[-1].slur_stops.append(self.active_slurs.pop())
            elif token == "|":
                self.barlines.append(self.position)
            elif token in ("[", "]"):
                # Beam grouping is re-engraved from the unchanged written rhythm.
                pass
            elif token.startswith("\\"):
                raise ValueError(f"Unsupported command {token}")
            else:
                self.add_note(token, scale)
        if closing:
            raise ValueError("Unclosed music block")

    def add_note(self, token: str, scale: F) -> None:
        if token.startswith("<"):
            match = re.fullmatch(r"<([^>]+)>(\d+)?(\.*)", token)
            assert match is not None
            pitch_tokens, denominator, dots = match.groups()
            pitches = []
            previous = self.previous
            for name in pitch_tokens.split():
                previous = self.pitch(name, previous)
                pitches.append(previous)
            self.previous = pitches[0]  # Relative music after a chord uses its first pitch.
            kind, multiplier = "note", 1
        else:
            match = SINGLE.fullmatch(token)
            if match is None:
                raise ValueError(f"Bad note token {token}")
            name, marks, denominator, dots, multiple = match.groups()
            multiplier = int(multiple or 1)
            if name in ("r", "s"):
                pitches, kind = [], "rest" if name == "r" else "skip"
            else:
                self.previous = self.pitch(name + marks, self.previous)
                pitches, kind = [self.previous], "note"
        if denominator:
            self.denominator, self.dots = int(denominator), len(dots)
        elif dots:
            raise ValueError("Dots without written duration")
        value = duration(self.denominator, self.dots) * scale * multiplier
        self.events.append(Event(tuple(pitches), value, self.denominator, self.dots, kind, tuplet=scale if scale != 1 else None))
        self.position += value


def parse_voice(text: str, name: str) -> VoiceParser:
    match = re.search(r"\b" + re.escape(name) + r"\s*=\s*\\relative\s+([a-g](?:isis|eses|is|es)?[',]*)\s*\{", text)
    if match is None:
        raise ValueError(f"Missing {name}")
    depth, index = 1, match.end()
    while depth:
        depth += (text[index] == "{") - (text[index] == "}")
        index += 1
    parser = VoiceParser(text[match.end():index-1], match[1])
    parser.parse()
    if parser.active_slurs:
        raise ValueError(f"Unclosed {name} slurs")
    if parser.pickup != 2 or parser.position != 406 or parser.repeat_spans != [(F(0), F(34))]:
        raise ValueError(f"Unexpected source structure in {name}: {parser.pickup}, {parser.position}, {parser.repeat_spans}")
    allowed_barlines = {F(2 + 4 * i) for i in range(102)}
    if not set(parser.barlines) <= allowed_barlines:
        raise ValueError(f"Bar check failed in {name}")
    return parser


def split_value(value: F) -> list[tuple[F, int, int]]:
    result = []
    choices = sorted(((duration(d, dots), d, dots) for d in TYPE_NAMES for dots in range(3)), reverse=True)
    while value:
        item = next((item for item in choices if item[0] <= value), None)
        if item is None:
            raise ValueError(f"Cannot notate duration {value}")
        result.append(item)
        value -= item[0]
    return result


def source_bars(events: list[Event]) -> list[list[Event]]:
    bars: list[list[Event]] = [[]]
    limit, used = F(2), F(0)
    for event in events:
        remaining = event.duration
        while remaining:
            if used == limit:
                bars.append([])
                used, limit = F(0), F(4)
            count = min(remaining, limit - used)
            if count != event.duration:
                if event.pitches or event.slur_starts or event.slur_stops:
                    raise ValueError("Pitched source note unexpectedly crosses a bar")
                pieces = split_value(count)
                bars[-1].extend(replace(event, duration=value, denominator=d, dots=dots) for value, d, dots in pieces)
            else:
                bars[-1].append(copy.deepcopy(event))
            used += count
            remaining -= count
    if len(bars) != 102 or used != 4:
        raise ValueError("Complete source must contain 102 printed measures")
    return bars


def sounding_events(parser: VoiceParser) -> list[dict]:
    result = []
    position = F(0)
    for event in parser.events:
        for pitch in event.pitches:
            result.append({"start": str(position), "duration": str(event.duration), "midi": pitch.midi})
        position += event.duration
    return result


def prepare_bars(parser: VoiceParser) -> list[list[Event]]:
    bars = source_bars(parser.events)
    # The source uses two s2 engraving placeholders at the repeat join and a
    # final s2 to fill the bar. They are empty in BOTH voices. Compress them,
    # retaining the four complementary half-bars instead of adding silence.
    for index, first in [(8, False), (9, True), (101, False)]:
        event = bars[index][0 if first else -1]
        if event.kind != "skip" or event.duration != 2:
            raise ValueError(f"Source placeholder changed in printed measure {index+1}")
        del bars[index][0 if first else -1]
    return bars


def ornament_notes(event: Event) -> list[Event]:
    if event.ornament is None:
        return [event]
    if len(event.pitches) != 1 or event.tuplet is not None:
        raise ValueError("Unexpected ornament source")
    principal = event.pitches[0]
    if event.ornament == "trill":
        if event.duration != 1:
            raise ValueError("Expected source quarter-note trill")
        neighbor_index = principal.diatonic + 1
        step = STEPS[neighbor_index % 7]
        upper = Pitch(step, E_MAJOR.get(step, 0), neighbor_index // 7)
        # Baroque realization: start on the upper auxiliary, eight 32nds per
        # quarter, finishing on the principal. This is an explicit edition.
        expanded = [Event((upper if i % 2 == 0 else principal,), F(1, 8), 32) for i in range(8)]
    elif event.ornament == "mordent":
        if event.duration != F(3, 2):
            raise ValueError("Expected dotted-quarter mordent")
        neighbor_index = principal.diatonic - 1
        step = STEPS[neighbor_index % 7]
        lower = Pitch(step, E_MAJOR.get(step, 0), neighbor_index // 7)
        expanded = [Event((principal,), F(1, 8), 32), Event((lower,), F(1, 8), 32)]
        remaining = split_value(event.duration - F(1, 4))
        expanded.extend(Event((principal,), value, d, dots, tie_start=i < len(remaining)-1, tie_stop=i > 0) for i, (value, d, dots) in enumerate(remaining))
    else:
        raise ValueError(f"Unknown ornament {event.ornament}")
    expanded[0].slur_starts = list(event.slur_starts)
    expanded[-1].slur_stops = list(event.slur_stops)
    assert sum((n.duration for n in expanded), F(0)) == event.duration
    return expanded


def add(parent: ET.Element, tag: str, text: object | None = None, **attrs: str) -> ET.Element:
    node = ET.SubElement(parent, tag, attrs)
    if text is not None:
        node.text = str(text)
    return node


def write_note(measure: ET.Element, event: Event, voice: int, identity: str) -> None:
    pitches = event.pitches or (None,)
    for index, pitch in enumerate(pitches):
        attrs = {"id": identity + (f"-c{index}" if index else "")}
        if event.kind == "skip":
            attrs["print-object"] = "no"
        node = add(measure, "note", **attrs)
        if index:
            add(node, "chord")
        if pitch is None:
            add(node, "rest")
        else:
            p = add(node, "pitch")
            add(p, "step", pitch.step.upper())
            add(p, "alter", pitch.alter)
            add(p, "octave", pitch.octave)
        ticks = event.duration * DIVISIONS
        if ticks.denominator != 1:
            raise ValueError(f"Duration not exactly representable: {event.duration}")
        add(node, "duration", ticks.numerator)
        if event.tie_stop:
            add(node, "tie", type="stop")
        if event.tie_start:
            add(node, "tie", type="start")
        add(node, "voice", voice)
        add(node, "type", TYPE_NAMES[event.denominator])
        for _ in range(event.dots):
            add(node, "dot")
        if event.tuplet:
            modification = add(node, "time-modification")
            add(modification, "actual-notes", event.tuplet.denominator)
            add(modification, "normal-notes", event.tuplet.numerator)
            add(modification, "normal-type", TYPE_NAMES[event.denominator])
        add(node, "stem", "up" if voice == 1 else "down")
        add(node, "staff", 1)
        if not index and (event.slur_starts or event.slur_stops or event.tuplet_start or event.tuplet_stop or event.tie_start or event.tie_stop):
            marks = add(node, "notations")
            if event.tie_stop:
                add(marks, "tied", type="stop")
            if event.tie_start:
                add(marks, "tied", type="start")
            for number in event.slur_stops:
                add(marks, "slur", type="stop", number=str((number - 1) % 16 + 1))
            for number in event.slur_starts:
                add(marks, "slur", type="start", number=str((number - 1) % 16 + 1))
            if event.tuplet_start:
                add(marks, "tuplet", type="start", number="1", bracket="yes")
            if event.tuplet_stop:
                add(marks, "tuplet", type="stop", number="1")


def build_bach_gavotte_with_report(source: Path) -> tuple[bytes, dict]:
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise ValueError("Bach source differs from the verified Mutopia edition")
    text = source.read_text()
    parsers = [parse_voice(text, name) for name in ("melodyOne", "melodyTwo")]
    lanes = [prepare_bars(parser) for parser in parsers]
    lengths = [sum((event.duration for event in bar), F(0)) for bar in lanes[0]]
    assert lengths == [F(2) if i in (0, 8, 9, 101) else F(4) for i in range(102)]
    assert all([sum((event.duration for event in bar), F(0)) for bar in lane] == lengths for lane in lanes)
    source_streams = [sounding_events(parser) for parser in parsers]
    # The engraving contains 767 voice-note events. The official same-channel
    # MIDI omits four unisons already held by its other voice (763 events).
    assert sum(map(len, source_streams)) == 767
    credit = ("J. S. Bach, BWV 1006, complete Gavotte en Rondeau; Hajo Dezelski, "
              "Mutopia-2008/07/13-1471, Bach-Gesellschaft 1879 Band 27.1. "
              "Music Viewer performance edition: all 102 printed measures and both voices retained; "
              "source opening volta performed twice; empty engraving half-bar placeholders compressed. "
              "Six trills realized from the upper auxiliary as eight 32nds per quarter; "
              "one mordent realized as principal/lower/principal with the remaining principal held. "
              "Re-engraved beam grouping; original slurs, chords, and triplets retained; editorial quarter=110. CC BY-SA 3.0.")
    score = ET.Element("score-partwise", version="4.0")
    add(add(score, "work"), "work-title", "加沃特回旋曲（完整乐章）/ Gavotte en Rondeau")
    identification = add(score, "identification")
    add(identification, "creator", "J. S. Bach · BWV 1006", type="composer")
    add(identification, "rights", credit)
    listing = add(score, "part-list")
    declaration = add(listing, "score-part", id="P1")
    add(declaration, "part-name", "Violin / 小提琴")
    add(add(declaration, "score-instrument", id="I1"), "instrument-name", "Violin")
    instrument = add(declaration, "midi-instrument", id="I1")
    add(instrument, "midi-channel", 1)
    add(instrument, "midi-program", 41)
    part = add(score, "part", id="P1")
    realized_counts = [0, 0]
    ornaments = []
    attacks_by_measure = []
    for index, length in enumerate(lengths):
        measure = add(part, "measure", id=f"P1-m{index+1}", number=str(index+1), **({"implicit": "yes"} if length != 4 else {}))
        if index and index % 4 == 0:
            add(measure, "print", **{"new-system": "yes"})
        if not index:
            attributes = add(measure, "attributes")
            add(attributes, "divisions", DIVISIONS)
            add(add(attributes, "key"), "fifths", 4)
            time = add(attributes, "time")
            add(time, "beats", 4)
            add(time, "beat-type", 4)
            clef = add(attributes, "clef")
            add(clef, "sign", "G")
            add(clef, "line", 2)
            direction = add(measure, "direction")
            metronome = add(add(direction, "direction-type"), "metronome")
            add(metronome, "beat-unit", "quarter")
            add(metronome, "per-minute", 110)
            add(direction, "sound", tempo="110")
            add(add(measure, "barline", location="left"), "repeat", direction="forward")
        for voice, lane in enumerate(lanes, 1):
            if voice > 1:
                add(add(measure, "backup"), "duration", int(length * DIVISIONS))
            serial = 0
            for event in lane[index]:
                if event.ornament:
                    ornaments.append({"measure": index+1, "voice": voice, "kind": event.ornament, "principal": event.pitches[0].midi})
                for realized in ornament_notes(event):
                    serial += 1
                    realized_counts[voice-1] += len(realized.pitches)
                    write_note(measure, realized, voice, f"P1-m{index+1}-v{voice}-n{serial}")
        attacks_by_measure.append(sum(n.find("pitch") is not None and not any(t.get("type") == "stop" for t in n.findall("tie")) for n in measure.findall("note")))
        if index == 8:
            add(add(measure, "barline", location="right"), "repeat", direction="backward", times="2")
        elif index == 101:
            add(add(measure, "barline", location="right"), "bar-style", "light-heavy")
    assert [event["kind"] for event in ornaments].count("trill") == 6
    assert [event["kind"] for event in ornaments].count("mordent") == 1
    ET.indent(score, space="  ")
    xml = ET.tostring(score, encoding="utf-8", xml_declaration=True)
    report = {"sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(), "sourcePrintedMeasures": 102,
              "sourceQuarterBeatsWithEngravingSpaces": "406", "sourcePitchEvents": 767,
              "writtenQuarterBeats": str(sum(lengths, F(0))), "performedQuarterBeats": "432",
              "performedMeasureVisits": 111, "tempoQPM": 110, "musicDurationSeconds": 432 * 60 / 110,
              "performedNoteAttacks": sum(attacks_by_measure) + sum(attacks_by_measure[:9]),
              "compressedSourceHalfBars": [{"measure": 9, "end": "trailing"}, {"measure": 10, "end": "leading"}, {"measure": 102, "end": "trailing"}],
              "ornaments": ornaments, "realizedWrittenPitchEventsIncludingTiedSegments": sum(realized_counts),
              "sourceVoiceEvents": source_streams, "credit": credit,
              "xmlSHA256": hashlib.sha256(xml).hexdigest()}
    return xml, report


def build_bach_gavotte(source: Path) -> bytes:
    return build_bach_gavotte_with_report(source)[0]


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("source", type=Path)
    args.add_argument("output", type=Path)
    args.add_argument("--report", type=Path)
    options = args.parse_args()
    data, report = build_bach_gavotte_with_report(options.source)
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_bytes(data)
    if options.report:
        options.report.parent.mkdir(parents=True, exist_ok=True)
        options.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key not in ("sourceVoiceEvents", "credit")}, ensure_ascii=False, indent=2))
