#!/usr/bin/env python3
"""Build traceable example arrangements from the checked-in Mutopia sources.

Build complete performances with source structure and explicit arrangement metadata.
Run with Python's standard library only; nothing is required at app runtime.
"""
from pathlib import Path
from fractions import Fraction as F
import hashlib
import json
import re
import uuid
import xml.etree.ElementTree as ET
import zipfile
from compile_fur_elise import build_fur_elise_with_report
from compile_bach_gavotte import build_bach_gavotte_with_report
from compile_greensleeves import build_greensleeves_with_report
from compile_duet_arrangements import arrange_ode, arrange_grace

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Docs/Examples/Sources'
OUTPUT = ROOT / 'Sources/ScoreFilm/Resources/Examples'
RAW = ROOT / 'Docs/Examples/Library'
NATURAL = {'c': 0, 'd': 2, 'e': 4, 'f': 5, 'g': 7, 'a': 9, 'b': 11}
ALTER = {'': 0, 'is': 1, 'isis': 2, 'es': -1, 'eses': -2}
TYPES = {1: 'whole', 2: 'half', 4: 'quarter', 8: 'eighth', 16: '16th', 32: '32nd'}
DIVISIONS = 48


def el(parent, tag, text=None, **attrs):
    node = ET.SubElement(parent, tag, attrs)
    if text is not None:
        node.text = str(text)
    return node


def events(text, transpose=0):
    text = re.sub(r'%[^\n]*', '', text)
    text = re.sub(r'\\grace\s*\{[^{}]*\}', '', text)
    text = re.sub(r'\\(?:stemUp|stemDown|small)\b', '', text)
    text = text.replace('{', ' ').replace('}', ' ')
    result = []
    duration = (4, 0)
    for token in text.split():
        token = token.strip('[]()|')
        if not token:
            continue
        token = token.replace('[', '').replace(']', '').replace('(', '').replace(')', '')
        match = re.fullmatch(r"([a-g](?:isis|eses|is|es)?|r|s)([',]*)(\d+)?(\.*)", token)
        if not match:
            raise ValueError('Unparsed source token: ' + token)
        name, marks, number, dots = match.groups()
        if number:
            duration = (int(number), len(dots))
        elif dots:
            raise ValueError('Dot without duration: ' + token)
        denominator, dot_count = duration
        beats = F(4, denominator) * sum((F(1, 2**i) for i in range(dot_count + 1)), F(0))
        pitch = None
        if name not in ('r', 's'):
            octave = 3 + marks.count("'") - marks.count(',')
            pitch = (name[0].upper(), ALTER[name[1:]], octave, transpose)
        result.append((pitch, beats))
    return result


def partition(notes, meter, pickup=F(0)):
    bars, current, length = [], [], F(0)
    limit = pickup or meter
    for note in notes:
        if length + note[1] > limit:
            raise ValueError(('Source event crosses a bar', length, note, limit))
        current.append(note)
        length += note[1]
        if length == limit:
            bars.append(current)
            current, length, limit = [], F(0), meter
    if current:
        bars.append(current)
    return bars


def extract_voice(filename, name):
    source = (SOURCES / filename).read_text()
    match = re.search(r'\b' + name + r'\s*=\s*(?:\\transpose\s+c\s+c\'\s*)?\{', source)
    assert match, name
    start = match.end()
    level, index = 1, start
    while level:
        if source[index] == '{': level += 1
        if source[index] == '}': level -= 1
        index += 1
    text = source[start:index-1]
    text = re.sub(r'\\(?:voiceOne|voiceTwo)\b', '', text)
    text = re.sub(r'\\bar\s+"[^"]*"', '', text)
    text = re.sub(r'\\(?:time|partial)\s+[\d/.]+', '', text)
    text = re.sub(r'\\key\s+[a-g]+\s+\\\w+', '', text)
    text = re.sub(r'\\barNumberCheck\s+#\d+', '', text)
    return text


def written_pitch(pitch):
    step, alter, octave, transpose = pitch
    if transpose:
        assert transpose % 12 == 0
        octave += transpose // 12
    return step, alter, octave


def note_xml(measure, note, note_id, voice, staff, fifths, first=False, last=False):
    pitch, beats = note
    chord = isinstance(pitch, list)
    pitches = pitch if chord else [pitch]
    for index, item in enumerate(pitches):
        node = el(measure, 'note', id=note_id + (f'-c{index}' if index else ''))
        if index: el(node, 'chord')
        if item is None:
            el(node, 'rest')
        else:
            step, alter, octave = written_pitch(item)
            p = el(node, 'pitch'); el(p, 'step', step); el(p, 'alter', alter); el(p, 'octave', octave)
        assert (beats * DIVISIONS).denominator == 1
        el(node, 'duration', int(beats * DIVISIONS)); el(node, 'voice', voice)
        options = [(F(4, n) * sum((F(1, 2**i) for i in range(d + 1)), F(0)), n, d) for n in TYPES for d in range(3)]
        _, denominator, dots = next(x for x in options if x[0] == beats)
        el(node, 'type', TYPES[denominator])
        for _ in range(dots): el(node, 'dot')
        if item is not None:
            defaults = {s: 1 for s in 'FCGDAEB'[:max(0, fifths)]} | {s: -1 for s in 'BEADGCF'[:max(0, -fifths)]}
            step, alter, _ = written_pitch(item)
            if alter != defaults.get(step, 0): el(node, 'accidental', {-2:'flat-flat', -1:'flat', 0:'natural', 1:'sharp', 2:'double-sharp'}[alter])
        el(node, 'staff', staff)
        if item is not None and index == 0 and (first or last):
            marks = el(node, 'notations')
            if last: el(marks, 'slur', type='stop', number='1')
            if first: el(marks, 'slur', type='start', number='1')


def make_score(key, title, composer, voices, fifths, time, tempo, credit, repeat=False, sections=None):
    """voices: per-part [(instrument, [(staff, bars), ...])]."""
    meter = F(int(time[0]) * 4, int(time[1]))
    count = len(voices[0][1][0][1])
    lengths = [sum((n[1] for n in bar), F(0)) for bar in voices[0][1][0][1]]
    assert all(F(0) < x <= meter for x in lengths)
    score = ET.Element('score-partwise', version='4.0')
    el(el(score, 'work'), 'work-title', title)
    ident = el(score, 'identification'); el(ident, 'creator', composer, type='composer'); el(ident, 'rights', credit)
    listing = el(score, 'part-list')
    for pi, (instrument, _) in enumerate(voices, 1):
        decl = el(listing, 'score-part', id=f'P{pi}')
        el(decl, 'part-name', 'Violin / 小提琴' if instrument == 'violin' else 'Piano / 钢琴')
        el(el(decl, 'score-instrument', id=f'I{pi}'), 'instrument-name', instrument.title())
        midi = el(decl, 'midi-instrument', id=f'I{pi}'); el(midi, 'midi-channel', pi); el(midi, 'midi-program', 41 if instrument == 'violin' else 1)
    for pi, (instrument, lanes) in enumerate(voices, 1):
        part = el(score, 'part', id=f'P{pi}')
        assert all(len(bars) == count for _, bars in lanes)
        for mi, length in enumerate(lengths):
            measure = el(part, 'measure', id=f'P{pi}-m{mi+1}', number=str(mi+1), **({'implicit': 'yes'} if length < meter else {}))
            if mi and mi % 4 == 0 and pi == 1: el(measure, 'print', **{'new-system':'yes'})
            if mi == 0:
                attrs = el(measure, 'attributes'); el(attrs, 'divisions', DIVISIONS)
                el(el(attrs, 'key'), 'fifths', fifths)
                t = el(attrs, 'time'); el(t, 'beats', time[0]); el(t, 'beat-type', time[1])
                if instrument == 'piano': el(attrs, 'staves', 2)
                for staff in range(1, 3 if instrument == 'piano' else 2):
                    clef = el(attrs, 'clef', number=str(staff)); el(clef, 'sign', 'G' if staff == 1 else 'F'); el(clef, 'line', 2 if staff == 1 else 4)
                direction = el(measure, 'direction'); met = el(el(direction, 'direction-type'), 'metronome'); el(met, 'beat-unit', 'quarter'); el(met, 'per-minute', tempo)
                el(direction, 'sound', tempo=str(tempo))
            for section in sections or []:
                if section['bar'] != mi:
                    continue
                if pi == 1:
                    direction = el(measure, 'direction', placement='above')
                    el(el(direction, 'direction-type'), 'words', section['name'])
                    el(direction, 'sound', tempo=str(section['tempo']))
                direction = el(measure, 'direction', placement='above')
                velocity = section['dynamics'][pi - 1]
                mark = 'p' if velocity < 56 else 'mp' if velocity < 70 else 'mf' if velocity < 86 else 'f'
                el(el(el(direction, 'direction-type'), 'dynamics'), mark)
                el(direction, 'sound', dynamics=str(velocity / 0.9))
            if repeat and mi == 0: el(el(measure, 'barline', location='left'), 'repeat', direction='forward')
            for vi, (staff, bars) in enumerate(lanes, 1):
                bar = bars[mi]
                assert sum((n[1] for n in bar), F(0)) == length, (key, pi, vi, mi, length)
                if vi > 1: el(el(measure, 'backup'), 'duration', int(length * DIVISIONS))
                nonrests = [i for i, n in enumerate(bar) if n[0] is not None]
                for ni, note in enumerate(bar):
                    # New phrasing marks are part of this arrangement, not inferred at playback.
                    first = instrument == 'violin' and vi == 1 and len(nonrests) > 1 and ni == nonrests[0]
                    last = instrument == 'violin' and vi == 1 and len(nonrests) > 1 and ni == nonrests[-1]
                    note_xml(measure, note, f'P{pi}-m{mi+1}-v{vi}-n{ni+1}', str(vi), staff, fifths, first, last)
            if mi == count - 1:
                line = el(measure, 'barline', location='right'); el(line, 'bar-style', 'light-heavy')
                if repeat: el(line, 'repeat', direction='backward', times='2')
    ET.indent(score, space='  ')
    return ET.tostring(score, encoding='utf-8', xml_declaration=True)


def package(key, filename, xml, instrument_ids, tempo, license_text, completeness=None):
    folder = RAW / key; folder.mkdir(parents=True, exist_ok=True)
    settings = json.loads((ROOT / 'Docs/Examples/Duet/project.json').read_text())
    settings['partInstruments'] = {f'P{i}': inst for i, inst in enumerate(instrument_ids, 1)}
    settings['routes'] = []
    settings['performance']['defaultTempoQPM'] = tempo
    settings['performance']['reverbWetDryMix'] = 12
    settings['visual']['voiceColors'] = []
    settings['visual'].pop('noteOverrides', None)
    parsed = ET.fromstring(xml)
    colors = ['#6EDBFFFF','#F6BF73FF','#BAA3FFFF','#F397BAFF']
    for part in parsed.findall('part'):
        for voice in sorted({n.findtext('voice') for n in part.findall('measure/note')}):
            settings['visual']['voiceColors'].append({'selector': {'partId':part.get('id'), 'voiceId':voice},'color':colors[len(settings['visual']['voiceColors']) % len(colors)]})
    settings['camera']['focusPartIds'] = list(settings['partInstruments'])
    entries = {'score.musicxml':xml, 'project.json':json.dumps(settings, ensure_ascii=False, indent=2).encode(), 'Licenses/score.txt':license_text.encode()}
    if completeness is not None:
        entries['Metadata/completeness.json'] = json.dumps(completeness, ensure_ascii=False, indent=2).encode()
    manifest = {'format':'scorefilm','version':'1.0.0','profile':'scorefilm-mac-v1','projectId':str(uuid.uuid5(uuid.NAMESPACE_URL,'https://music-viewer.local/examples/'+key)), 'title':parsed.findtext('work/work-title'),'files':{'notation':'score.musicxml','settings':'project.json'},'requiredCapabilities':['notation.musicxml4','routing.segment','visual.trails.v1','export.mp4'],'integrity':{p:hashlib.sha256(data).hexdigest() for p,data in entries.items()}}
    entries['manifest.json'] = json.dumps(manifest, ensure_ascii=False, indent=2).encode()
    for path, data in entries.items():
        target = folder/path; target.parent.mkdir(exist_ok=True); target.write_bytes(data)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUTPUT/filename, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for path, data in sorted(entries.items()):
            info=zipfile.ZipInfo(path,(2026,10,29,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;z.writestr(info,data)
    print(filename, len(parsed.findall('.//note')), 'notes')


def main():
    cc = ('CC BY-SA 3.0: https://creativecommons.org/licenses/by-sa/3.0/\n'
          'This arrangement/translation is distributed under the same license.\n')
    pd = 'The source engraving was dedicated to the public domain by its typesetter.\n'
    xml, report = build_fur_elise_with_report(SOURCES / 'fur-elise.musicxml')
    package('fur-elise', 'FurElise.scorefilm', xml, ['piano'], 72, report['credit'], report)
    # Source LilyPond uses absolute pitches; soprano/alto are transposed up an octave.
    ode = [partition(events(extract_voice('ode.ly', name), 12 if name in ('sop','alto') else 0), F(4)) for name in ('sop','alto','tenor','bass')]
    arrangement = arrange_ode(ode)
    ode = arrangement['lanes']
    credit = ('Beethoven hymn theme; Peter Chubb, Mutopia-2009/08/05-528 (public domain). '
              'Music Viewer complete independent violin/piano arrangement: introduction, full violin theme, '
              'full piano response with violin counterpoint, written-out melodic variation, and coda. '
              'This is not the full fourth movement of Symphony No. 9. ' + arrangement['description'])
    xml = make_score('ode-to-joy', '欢乐颂：小提琴与钢琴完整编曲 / Ode to Joy', 'L. van Beethoven · arr. Music Viewer', [('violin', [(1, ode[0])]), ('piano', [(1, ode[1]), (2, ode[2]), (2, ode[3])])], 1, (4, 4), arrangement['sections'][0]['tempo'], credit, sections=arrangement['sections'])
    package('ode-to-joy', 'OdeToJoy.scorefilm', xml, ['violin', 'piano'], arrangement['sections'][0]['tempo'], credit + '\nhttps://www.mutopiaproject.org/cgibin/piece-info.cgi?id=528\n' + pd + 'Music Viewer arrangement: CC0 public-domain dedication, https://creativecommons.org/publicdomain/zero/1.0/\n', arrangement['report'])
    xml, report = build_greensleeves_with_report(SOURCES / 'greensleeves-divisions.ly')
    package('greensleeves', 'Greensleeves.scorefilm', xml, ['violin', 'piano'], 160, report['credit'] + '\n' + pd, report)
    xml, report = build_bach_gavotte_with_report(SOURCES / 'bach-gavotte.ly')
    package('bach-gavotte', 'BachGavotte.scorefilm', xml, ['violin'], 110, report['credit'] + '\n' + cc, report)
    melody=partition(events(extract_voice('amazing-grace.ly','bagpipeOne')),F(9,2),F(3,2))
    right=[]; left=[]
    roots=[(10,0),(3,0),(3,0),(8,0),(3,0),(3,0),(3,0),(10,0),(8,0),(8,0),(3,0),(8,0),(3,0),(3,0),(10,0),(3,0),(3,0)]
    # Major triads in E-flat, A-flat and B-flat, with a quieter piano part.
    spelled={3:[('E',-1,4,0),('G',0,4,0),('B',-1,4,0)],8:[('A',-1,3,0),('C',0,4,0),('E',-1,4,0)],10:[('B',-1,3,0),('D',0,4,0),('F',0,4,0)]}
    for i,bar in enumerate(melody):
        length=sum((n[1] for n in bar),F(0)); root=roots[min(i,len(roots)-1)][0]; triad=spelled[root]
        right.append([(triad[n%3],F(1,2)) for n in range(int(length*2))])
        bass=triad[0][:2]+(triad[0][2]-1,0)
        left.append([(bass,min(F(3),length))]+([(triad[2][:2]+(triad[2][2]-1,0),length-F(3))] if length>3 else []))
    arrangement = arrange_grace([melody, right, left])
    grace = arrangement['lanes']
    credit = ('Traditional; Breizh Partitions, Mutopia-2012/02/12-1832. Music Viewer complete independent '
              'violin/piano arrangement: introduction, complete hymn theme, motivic dialogue, complete piano '
              'theme with violin counterpoint, and coda. Bagpipe-specific grace figures are omitted in this '
              'instrumental adaptation; all hymn phrases are retained. ' + arrangement['description'])
    xml = make_score('amazing-grace', '奇异恩典：小提琴与钢琴完整编曲 / Amazing Grace', 'Traditional · arr. Music Viewer', [('violin', [(1, grace[0])]), ('piano', [(1, grace[1]), (2, grace[2]), (2, grace[3])])], -3, (9, 8), arrangement['sections'][0]['tempo'], credit, sections=arrangement['sections'])
    package('amazing-grace', 'AmazingGrace.scorefilm', xml, ['violin', 'piano'], arrangement['sections'][0]['tempo'], credit + '\nhttps://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1832\n' + cc, arrangement['report'])

if __name__=='__main__':
    main()
