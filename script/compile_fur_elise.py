"""Complete CC0 Fur Elise, with three grace notes and measured tremolos written out.

The original source remains unchanged. The performance edition borrows grace-note
length from the following note and preserves every measure's absolute duration.
"""
from pathlib import Path
from fractions import Fraction
import copy
import hashlib
import xml.etree.ElementTree as ET

SOURCE_SHA256 = 'f665fc5d0c8ad5c96e7e099a4bf927756d1087ea5a58d0d85816c2e8c3530f5c'
TYPES = {1: 'whole', 2: 'half', 4: 'quarter', 8: 'eighth', 16: '16th', 32: '32nd', 64: '64th', 128: '128th'}


def rhythm(note, ticks, divisions):
    for tag in ('duration', 'type', 'dot', 'beam', 'time-modification'):
        for child in note.findall(tag):
            note.remove(child)
    note.attrib.pop('default-x', None)
    value = Fraction(ticks, divisions)
    choices = [(Fraction(4, denominator) * sum((Fraction(1, 2**i) for i in range(dots + 1)), Fraction()), name, dots)
               for denominator, name in TYPES.items() for dots in range(3)]
    match = next((x for x in choices if x[0] == value), None)
    if match is None:
        raise ValueError(f'Unrepresentable written duration: {value}')
    # MusicXML order: pitch/rest, duration, ties, voice, type, dots, accidental...
    position = next(i for i, child in enumerate(note) if child.tag in ('pitch', 'rest', 'unpitched')) + 1
    duration = ET.Element('duration'); duration.text = str(ticks); note.insert(position, duration)
    position = next(i for i, child in enumerate(note) if child.tag == 'voice') + 1
    kind = ET.Element('type'); kind.text = match[1]; note.insert(position, kind)
    for index in range(match[2]):
        note.insert(position + index + 1, ET.Element('dot'))


def clean_tremolo(note, first, last):
    for notations in note.findall('notations'):
        for ornaments in notations.findall('ornaments'):
            for item in ornaments.findall('tremolo'):
                ornaments.remove(item)
            if not list(ornaments):
                notations.remove(ornaments)
        for slur in notations.findall('slur'):
            if (slur.get('type') == 'start' and not first) or (slur.get('type') == 'stop' and not last):
                notations.remove(slur)
        if not list(notations):
            note.remove(notations)


def build_fur_elise_with_report(source: Path):
    raw = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('Unexpected Fur Elise source version')
    root = ET.fromstring(raw)
    root.set('version', '4.0')
    root.find('work/work-title').text = '致爱丽丝 / Für Elise — WoO 59'
    # Eight times the source divisions accommodates a 64th-note grace event
    # without rounding the original triplets or adding time to a measure.
    for item in root.iter():
        if item.tag in ('divisions', 'duration', 'offset') and item.text:
            item.text = str(int(item.text) * 8)
    grace_count = tremolo_count = added_attacks = 0
    divisions = 1
    for part in root.findall('part'):
        measures = part.findall('measure')
        if len(measures) != 106:
            raise ValueError('The complete source must contain 106 measures')
        for measure_index, measure in enumerate(measures):
            if measure.findtext('attributes/divisions'):
                divisions = int(measure.findtext('attributes/divisions'))
            children = list(measure)
            result = []
            index = 0
            pending = []
            while index < len(children):
                item = children[index]
                if item.tag != 'note':
                    if pending:
                        raise ValueError('Grace cluster has no following note in its voice')
                    result.append(item); index += 1; continue
                if item.find('grace') is not None:
                    if item.find('chord') is not None:
                        raise ValueError('Unexpected grace chord')
                    pending.append(item); grace_count += 1; index += 1; continue
                group = [item]
                index += 1
                while index < len(children) and children[index].tag == 'note' and children[index].find('chord') is not None:
                    group.append(children[index]); index += 1
                duration = int(item.findtext('duration'))
                if pending:
                    if len(group) != 1 or any(g.findtext('voice') != item.findtext('voice') for g in pending):
                        raise ValueError('Unexpected grace voice/chord relationship')
                    each = min(divisions // 8, duration // (2 * len(pending)))
                    for grace in pending:
                        grace.remove(grace.find('grace'))
                        rhythm(grace, each, divisions)
                        result.append(grace)
                    rhythm(item, duration - each * len(pending), divisions)
                    duration -= each * len(pending)
                    pending = []
                tremolos = [mark for note in group for mark in note.findall('notations/ornaments/tremolo')]
                if not tremolos:
                    result.extend(group); continue
                if any(t.get('type', 'single') != 'single' or t.text != '2' for t in tremolos):
                    raise ValueError('Unexpected tremolo form')
                subdivision = divisions // 4
                if duration % subdivision:
                    raise ValueError('Measured tremolo does not fit its written duration')
                count = duration // subdivision
                tremolo_count += 1
                added_attacks += (count - 1) * len(group)
                for stroke in range(count):
                    for chord_index, original in enumerate(group):
                        note = copy.deepcopy(original)
                        rhythm(note, subdivision, divisions)
                        clean_tremolo(note, stroke == 0, stroke == count - 1)
                        if chord_index == 0:
                            for beam_number in (1, 2):
                                beam = ET.Element('beam', number=str(beam_number))
                                position = next((i for i, child in enumerate(note) if child.tag == 'notations'), len(note))
                                note.insert(position, beam)
                                beam.text = 'begin' if stroke == 0 else 'end' if stroke == count - 1 else 'continue'
                        result.append(note)
            if pending:
                raise ValueError('Dangling grace note')
            measure[:] = result
            # These source ending bars complement the half-beat opening pickup;
            # do not pad them to a complete 3/8 bar during semantic import.
            if measure_index in (0, 8, 105):
                measure.set('implicit', 'yes')
            for number, note in enumerate(measure.findall('note'), 1):
                note.set('id', f'{part.get("id")}-m{measure_index + 1}-n{number}')
    if (grace_count, tremolo_count, added_attacks) != (3, 14, 69):
        raise ValueError(f'Unexpected source features: {(grace_count, tremolo_count, added_attacks)}')
    credit = ('L. van Beethoven, WoO 59; complete 106-measure score. OpenScore (CC0), '
              'https://musescore.com/score/4053926; MusicXML mirror: sightreader/sheet-music. '
              'Music Viewer performance edition: all sections and original first/second endings retained; '
              '3 grace notes borrow up to a 32nd note each (at most half the host duration) from the following note; '
              '14 measured single tremolos are written as sixteenth-note reattacks, including complete chords; '
              'incomplete ending measures are explicitly marked; performed pitches and octave-display lines retained. '
              'Source tempo quarter=72. https://creativecommons.org/publicdomain/zero/1.0/')
    identification = root.find('identification')
    rights = ET.Element('rights'); rights.text = credit
    position = next((i for i, item in enumerate(identification) if item.tag not in ('creator', 'rights')), len(identification))
    identification.insert(position, rights)
    ET.indent(root, space='  ')
    xml = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    report = {'sourceSHA256': SOURCE_SHA256, 'writtenMeasures': 106, 'expectedVisits': 127,
              'expectedQuarterBeats': 187.5, 'tempoQPM': 72, 'expectedMusicSeconds': 156.25,
              'sourceGraceNotes': grace_count, 'measuredTremolos': tremolo_count,
              'addedTremoloAttacks': added_attacks, 'expectedSoundingNotes': 1020,
              'sourcePitchedNotes': 815, 'writtenPitchedNotes': len(root.findall('.//note/pitch')),
              'credit': credit}
    return xml, report


def build_fur_elise(source: Path) -> bytes:
    return build_fur_elise_with_report(source)[0]
