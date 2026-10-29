#!/usr/bin/env python3
"""Build traceable example arrangements from the checked-in Mutopia sources.

RUSH E is not included; the piano example is Beethoven's Fur Elise theme.
Run with Python's standard library only; nothing is required at app runtime.
"""
from pathlib import Path
from fractions import Fraction as F
import copy
import hashlib
import json
import re
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Docs/Examples/Sources'
OUTPUT = ROOT / 'Sources/ScoreFilm/Resources/Examples'
RAW = ROOT / 'Docs/Examples/Library'
NATURAL = {'c': 0, 'd': 2, 'e': 4, 'f': 5, 'g': 7, 'a': 9, 'b': 11}
ALTER = {'': 0, 'is': 1, 'isis': 2, 'es': -1, 'eses': -2}
TYPES = {1: 'whole', 2: 'half', 4: 'quarter', 8: 'eighth', 16: '16th', 32: '32nd'}


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
        el(node, 'duration', int(beats * 4)); el(node, 'voice', voice)
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


def make_score(key, title, composer, voices, fifths, time, tempo, credit, repeat=False):
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
                attrs = el(measure, 'attributes'); el(attrs, 'divisions', 4)
                el(el(attrs, 'key'), 'fifths', fifths)
                t = el(attrs, 'time'); el(t, 'beats', time[0]); el(t, 'beat-type', time[1])
                if instrument == 'piano': el(attrs, 'staves', 2)
                for staff in range(1, 3 if instrument == 'piano' else 2):
                    clef = el(attrs, 'clef', number=str(staff)); el(clef, 'sign', 'G' if staff == 1 else 'F'); el(clef, 'line', 2 if staff == 1 else 4)
                direction = el(measure, 'direction'); met = el(el(direction, 'direction-type'), 'metronome'); el(met, 'beat-unit', 'quarter'); el(met, 'per-minute', tempo)
                el(direction, 'sound', tempo=str(tempo))
            if repeat and mi == 0: el(el(measure, 'barline', location='left'), 'repeat', direction='forward')
            for vi, (staff, bars) in enumerate(lanes, 1):
                bar = bars[mi]
                assert sum((n[1] for n in bar), F(0)) == length, (key, pi, vi, mi, length)
                if vi > 1: el(el(measure, 'backup'), 'duration', int(length * 4))
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


def package(key, filename, xml, instrument_ids, tempo, license_text):
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
    source = (SOURCES / 'fur-elise.musicxml').read_bytes()
    assert hashlib.sha256(source).hexdigest() == 'f665fc5d0c8ad5c96e7e099a4bf927756d1087ea5a58d0d85816c2e8c3530f5c'
    elise = ET.fromstring(source)
    elise.find('work/work-title').text = '致爱丽丝（主题选段）/ Für Elise'
    for part in elise.findall('part'):
        for measure in part.findall('measure')[9:]: part.remove(measure)
        measures = part.findall('measure')
        for measure in measures:
            for barline in measure.findall('barline'):
                for ending in barline.findall('ending'): barline.remove(ending)
            for sound in measure.findall('.//sound'):
                if 'tempo' in sound.attrib: sound.set('tempo','66')
        # The final theme bar complements the opening upbeat. The source's
        # first-ending bracket is omitted because this excerpt repeats just A.
        measures[-1].set('implicit','yes')
        direction=ET.Element('direction');met=el(el(direction,'direction-type'),'metronome');el(met,'beat-unit','quarter');el(met,'per-minute',66);el(direction,'sound',tempo='66')
        insert=next(i for i,n in enumerate(measures[0]) if n.tag=='note')
        measures[0].insert(insert,direction)
    credit='L. van Beethoven, WoO 59; OpenScore (CC0), https://musescore.com/score/4053926. MusicXML mirror: sightreader/sheet-music. Music Viewer excerpt: opening theme only, first-ending bracket omitted, final bar complements upbeat, tempo set to quarter=66.'
    el(elise.find('identification'),'rights',credit)
    ET.indent(elise,space='  ')
    package('fur-elise','FurElise.scorefilm',ET.tostring(elise,encoding='utf-8',xml_declaration=True),['piano'],66,credit+'\nhttps://creativecommons.org/publicdomain/zero/1.0/\n')
    # Source LilyPond uses absolute pitches; soprano/alto are transposed up an octave.
    ode = [partition(events(extract_voice('ode.ly', name), 12 if name in ('sop','alto') else 0), F(4)) for name in ('sop','alto','tenor','bass')]
    credit='Beethoven; Peter Chubb, Mutopia-2009/08/05-528 (public domain). Violin/piano adaptation and phrasing: Music Viewer.'
    xml=make_score('ode-to-joy','欢乐颂 / Ode to Joy','L. van Beethoven', [('violin',[(1,ode[0])]),('piano',[(1,ode[1]),(2,ode[2]),(2,ode[3])])],1,(4,4),100,credit)
    package('ode-to-joy','OdeToJoy.scorefilm',xml,['violin','piano'],100,credit+'\nhttps://www.mutopiaproject.org/cgibin/piece-info.cgi?id=528\n'+pd)
    green=[partition(events(extract_voice('greensleeves.ly',name)),F(3),F(1,2)) for name in ('Soprano','Alto','Tenor','Bass')]
    credit='Traditional; Steve Dunlop, Mutopia-2014/03/30-1247 (public domain). Violin/piano adaptation and phrasing: Music Viewer.'
    xml=make_score('greensleeves','绿袖子 / Greensleeves','Traditional', [('violin',[(1,green[0])]),('piano',[(1,green[1]),(2,green[2]),(2,green[3])])],1,(6,8),70,credit)
    package('greensleeves','Greensleeves.scorefilm',xml,['violin','piano'],70,credit+'\nhttps://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1247\n'+pd)
    # Nine printed measures represent the upbeat and eight-bar rondo theme.
    top=["b'4 gis''4", "gis''4 fis''8 e''8 fis''4 a''4", "a''2 b''8 gis''8 a''8 fis''8", "b'8 fis''16 gis''16 a''8 fis''8 gis''8 e''8 fis''8 dis''8", "e''8 b'8 gis'8 e'8 gis'8 b'8 e''8 gis''8", "a'8 gis''8 fis''8 e''8 fis''8 gis''8 a''8 fis''8", "a''2 b'4 gis''4", "cis''4 fis''4 fis'4 dis''4", "e''2"]
    bottom=["e'4 r4", "a'4 r2.", "b'2 r2", "r1", "r1", "r1", "b'2 e'4 r4", "a'4 r4 b4 r4", "e'2"]
    low=[events(bar) for bar in bottom]
    low[7][0]=([('A',0,4,0),('C',1,5,0)],F(1))
    credit='J. S. Bach; Hajo Dezelski, Mutopia-2008/07/13-1471. Theme excerpt adapted by Music Viewer: ornaments omitted, upbeat/end aligned, phrasing restated.'
    xml=make_score('bach-gavotte','加沃特回旋曲（主题选段）/ Gavotte en Rondeau','J. S. Bach · BWV 1006', [('violin',[(1,[events(bar) for bar in top]),(1,low)])],4,(4,4),110,credit,repeat=True)
    package('bach-gavotte','BachGavotte.scorefilm',xml,['violin'],110,credit+'\nhttps://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1471\n'+cc)
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
    credit='Traditional; Breizh Partitions, Mutopia-2012/02/12-1832. Violin/piano adaptation by Music Viewer: bagpipe grace notes omitted, piano accompaniment and phrasing added.'
    xml=make_score('amazing-grace','奇异恩典 / Amazing Grace','Traditional', [('violin',[(1,melody)]),('piano',[(1,right),(2,left)])],-3,(9,8),90,credit)
    package('amazing-grace','AmazingGrace.scorefilm',xml,['violin','piano'],90,credit+'\nhttps://www.mutopiaproject.org/cgibin/piece-info.cgi?id=1832\n'+cc)

if __name__=='__main__':
    main()
