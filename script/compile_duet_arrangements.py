"""Complete, explicitly labelled Music Viewer violin/piano arrangements.

The hymn sources supply each complete tune and its harmony.  These are new
instrumental arrangements, not missing movements from Beethoven's symphony or
an asserted historical arrangement of Amazing Grace.  All sections are written
out, with an introduction, an instrumental dialogue/variation and a cadence;
there is no whole-score repeat added to lengthen a short demonstration.

The caller supplies parsed source lanes and writes MusicXML.  This module has
no file input, runtime dependency, random state or reference to generated assets.
"""
from __future__ import annotations

from copy import deepcopy
from fractions import Fraction as F
import hashlib
import json

_NATURAL = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
_DURATIONS = sorted({F(4, n) * sum((F(1, 2**i) for i in range(d + 1)), F())
                     for n in (1, 2, 4, 8, 16, 32) for d in range(3)}, reverse=True)


def _p(step, octave, alter=0):
    return (step, alter, octave, 0)


def _absolute(pitch):
    if pitch is None:
        return None
    if isinstance(pitch, list):
        return [_absolute(p) for p in pitch]
    step, alter, octave, transpose = pitch
    if transpose % 12:
        raise ValueError('These arrangements require octave-only source transposition')
    return step, alter, octave + transpose // 12, 0


def _shift(pitch, octaves):
    pitch = _absolute(pitch)
    if pitch is None:
        return None
    if isinstance(pitch, list):
        return [_shift(p, octaves) for p in pitch]
    step, alter, octave, _ = pitch
    return step, alter, octave + octaves, 0


def _midi(pitch):
    step, alter, octave, _ = _absolute(pitch)
    return (octave + 1) * 12 + _NATURAL[step] + alter


def _register(pitch, low, high):
    pitch = _absolute(pitch)
    while _midi(pitch) < low:
        pitch = _shift(pitch, 1)
    while _midi(pitch) > high:
        pitch = _shift(pitch, -1)
    if not low <= _midi(pitch) <= high:
        raise ValueError('Register is narrower than an octave')
    return pitch


def _length(bar):
    return sum((F(duration) for _, duration in bar), F())


def _hold(pitch, duration):
    """Write long holds/rests using standard values, without implicit padding."""
    left = F(duration)
    if left == F(9, 2):
        # Preserve compound-meter grouping instead of a whole note plus an
        # eighth note across the final dotted-quarter pulse.
        return [(deepcopy(pitch), F(3)), (deepcopy(pitch), F(3, 2))]
    result = []
    while left:
        value = next((x for x in _DURATIONS if x <= left), None)
        if value is None:
            raise ValueError(f'Unrepresentable duration: {duration}')
        result.append((deepcopy(pitch), value))
        left -= value
    return result


def _transpose_lane(lane, octaves):
    return [[(_shift(pitch, octaves), F(duration)) for pitch, duration in bar] for bar in lane]


def _at(bar, position):
    cursor = F()
    for pitch, duration in bar:
        if cursor <= position < cursor + duration:
            return _absolute(pitch)
        cursor += duration
    return None


def _arpeggio(chord, duration, pattern=(0, 1, 2, 1, 0, 1, 2, 1, 2)):
    duration = F(duration)
    if duration % F(1, 2):
        raise ValueError('Arpeggio duration must be a whole number of eighth notes')
    return [(deepcopy(chord[pattern[i % len(pattern)] % len(chord)]), F(1, 2))
            for i in range(int(duration * 2))]


def _ornament_ode(bar):
    """A measured upper-neighbour variation; the original main notes remain."""
    scale = {'C': ('D', 0), 'D': ('E', 0), 'E': ('F', 1), 'F': ('G', 0),
             'G': ('A', 0), 'A': ('B', 0), 'B': ('C', 0)}
    result = []
    for pitch, duration in bar:
        pitch, duration = _absolute(pitch), F(duration)
        if pitch is None or isinstance(pitch, list) or duration < 1:
            result.append((pitch, duration))
            continue
        step, _, octave, _ = pitch
        upper, alter = scale[step]
        neighbour = (upper, alter, octave + (step == 'B'), 0)
        # Quarter -> eighth + two sixteenths; half -> dotted quarter + two
        # sixteenths.  This is notation with exact time, not a playback effect.
        result += _hold(pitch, duration - F(1, 2))
        result += [(neighbour, F(1, 4)), (pitch, F(1, 4))]
    return result


def _ode_harmony_arpeggios(voices):
    result = []
    for bars in zip(*voices):
        length = _length(bars[0])
        notes = []
        for index in range(int(length * 2)):
            position = F(index, 2)
            harmony = []
            for bar in bars:
                pitch = _at(bar, position)
                for tone in pitch if isinstance(pitch, list) else [pitch]:
                    if tone is not None:
                        tone = _register(tone, 60, 83)
                        if _midi(tone) not in [_midi(p) for p in harmony]:
                            harmony.append(tone)
            harmony.sort(key=_midi)
            if not harmony:
                notes.append((None, F(1, 2)))
            else:
                notes.append((harmony[(0, 1, 2, 1)[index % 4] % len(harmony)], F(1, 2)))
        result.append(notes)
    return result


def _canonical(lanes):
    return [[[(None if p is None else [_midi(x) for x in p] if isinstance(p, list) else _midi(p), str(d))
              for p, d in bar] for bar in lane] for lane in lanes]


def _fingerprint(lanes):
    return hashlib.sha256(json.dumps(_canonical(lanes), separators=(',', ':')).encode()).hexdigest()


def _verify_tune(actual, source, octaves=0):
    expected = _transpose_lane(source, octaves)
    if _canonical([actual]) != _canonical([expected]):
        raise ValueError('A complete source-tune presentation was truncated or changed')


def _report(lanes, sections, source_lanes, meter):
    if len(lanes) != 4 or len({len(lane) for lane in lanes}) != 1:
        raise ValueError('Expected four equally sized instrumental lanes')
    lengths = [_length(bar) for bar in lanes[0]]
    for index, bars in enumerate(zip(*lanes)):
        if len({_length(bar) for bar in bars}) != 1 or not 0 < lengths[index] <= meter:
            raise ValueError(f'Misaligned arrangement bar {index + 1}')
        for bar in bars:
            for _, duration in bar:
                if duration not in _DURATIONS:
                    raise ValueError(f'Unsupported note value {duration}')
    if sections[0]['bar'] != 0 or sorted(s['bar'] for s in sections) != [s['bar'] for s in sections]:
        raise ValueError('Sections must begin at zero and follow the score')
    expanded_sections = []
    seconds = F()
    for index, section in enumerate(sections):
        end = sections[index + 1]['bar'] if index + 1 < len(sections) else len(lengths)
        beats = sum(lengths[section['bar']:end], F())
        seconds += beats * 60 / F(section['tempo'])
        expanded_sections.append({**section, 'bars': end - section['bar'],
                                  'quarterBeats': str(beats),
                                  'musicSHA256': _fingerprint([lane[section['bar']:end] for lane in lanes])})
    ranges = []
    for lane in lanes:
        values = [_midi(p) for bar in lane for pitch, _ in bar
                  for p in (pitch if isinstance(pitch, list) else [pitch]) if p is not None]
        ranges.append([min(values), max(values)])
    return {'printedMeasures': len(lengths), 'quarterBeats': str(sum(lengths, F())),
            'musicSeconds': float(seconds), 'wholeScoreRepeats': 0,
            'laneQuarterBeats': [str(sum((_length(bar) for bar in lane), F())) for lane in lanes],
            'laneMidiRanges': ranges, 'sections': expanded_sections,
            'sourceTuneMeasures': len(source_lanes[0]),
            'sourceTuneSHA256': _fingerprint(source_lanes),
            'authorship': 'Original complete instrumental arrangement by Music Viewer; based on the credited hymn source.'}


def arrange_ode(voices):
    """G-major violin/piano introduction, theme, dialogue, variation and coda."""
    voices = deepcopy(voices)
    if len(voices) != 4 or any(len(lane) != 16 for lane in voices):
        raise ValueError('Ode to Joy requires all 16 bars of the four-part hymn source')
    for bars in zip(*voices):
        if any(_length(bar) != 4 for bar in bars):
            raise ValueError('The Ode source must have sixteen complete 4/4 bars')
    g = [_p('G', 4), _p('B', 4), _p('D', 5)]
    c = [_p('C', 4), _p('E', 4), _p('G', 4)]
    a = [_p('A', 3), _p('C', 4), _p('E', 4)]
    d = [_p('D', 4), _p('F', 4, 1), _p('A', 4)]
    intro = [[], [], [], []]
    for index, (chord, bass, inner) in enumerate([
            (g, _p('G', 2), _p('B', 3)), (c, _p('C', 3), _p('E', 3)),
            (a, _p('A', 2), _p('C', 4)), (d, _p('D', 3), _p('F', 3, 1))]):
        intro[0].append(_hold(None, 4) if index < 2 else
                        [(_p('D', 5), F(1)), (_p('C', 5), F(1)), (_p('A', 4), F(2))] if index == 3 else
                        [(_p('A', 4), F(1)), (_p('B', 4), F(1)), (_p('D', 5), F(2))])
        intro[1].append(_arpeggio(chord, 4))
        intro[2].append(_hold(inner, 4))
        intro[3].append(_hold(bass, 4))
    theme = [_transpose_lane(voices[0], 0), _transpose_lane(voices[1], 0),
             _transpose_lane(voices[2], -1), _transpose_lane(voices[3], -1)]
    dialogue = [_transpose_lane(voices[1], 0), _transpose_lane(voices[0], 0),
                _transpose_lane(voices[2], -1), _transpose_lane(voices[3], -1)]
    variation = [[_ornament_ode(bar) for bar in voices[0]],
                 _ode_harmony_arpeggios(voices[1:]),
                 _transpose_lane(voices[2], -1), _transpose_lane(voices[3], -1)]
    coda_violin = [
        [(_p('D', 5), F(1)), (_p('B', 4), F(1)), (_p('G', 4), F(2))],
        [(_p('A', 4), F(1)), (_p('C', 5), F(1)), (_p('B', 4), F(2))],
        [(_p('A', 4), F(1)), (_p('D', 5), F(1)), (_p('F', 5, 1), F(1)), (_p('A', 5), F(1))],
        _hold(_p('G', 5), 4)]
    coda = [coda_violin, [_arpeggio(g, 4), _arpeggio(c, 4),
                                  _arpeggio(d + [_p('C', 5)], 4), _hold(g, 4)],
            [_hold(_p('B', 3), 4), _hold(_p('E', 3), 4),
             _hold(_p('F', 3, 1), 4), _hold(_p('B', 3), 4)],
            [_hold(_p('G', 2), 4), _hold(_p('C', 3), 4),
             _hold(_p('D', 3), 4), _hold(_p('G', 2), 4)]]
    lanes = [sum((section[i] for section in [intro, theme, dialogue, variation, coda]), []) for i in range(4)]
    sections = [
        {'bar': 0, 'name': '前奏 · Introduction', 'tempo': 84, 'dynamics': [64, 58]},
        {'bar': 4, 'name': '完整主题 · Theme', 'tempo': 96, 'dynamics': [82, 62]},
        {'bar': 20, 'name': '钢琴答奏 · Piano dialogue', 'tempo': 88, 'dynamics': [62, 82]},
        {'bar': 36, 'name': '终段变奏 · Final variation', 'tempo': 108, 'dynamics': [90, 70]},
        {'bar': 52, 'name': '尾声 · Coda', 'tempo': 72, 'dynamics': [78, 65]}]
    _verify_tune(lanes[0][4:20], voices[0])
    _verify_tune(lanes[1][20:36], voices[0])
    report = _report(lanes, sections, voices, F(4))
    report['completeTunePresentations'] = [
        {'bar': 4, 'bars': 16, 'lane': 0, 'instrument': 'violin', 'octaveChange': 0},
        {'bar': 20, 'bars': 16, 'lane': 1, 'instrument': 'piano', 'octaveChange': 0}]
    return {'lanes': lanes, 'sections': sections,
            'description': 'Music Viewer 完整器乐编曲：前奏、完整圣歌主题、钢琴答奏、终段实音变奏与尾声；不是第九交响曲第四乐章全长版。',
            'report': report}


def _grace_harmony(chord, bass, duration, blocks=False):
    length = F(duration)
    right = ([(deepcopy(chord), min(F(3, 2), length - i)) for i in (F(0), F(3, 2), F(3)) if i < length]
             if blocks else _arpeggio(chord, length))
    third = _register(chord[1], 48, 59)
    return right, _hold(third, length), _hold(bass, min(F(3), length)) + (
        _hold(_register(chord[2], _midi(bass), _midi(bass) + 11), length - 3) if length > 3 else [])


def arrange_grace(voices):
    """E-flat introduction, complete tune, original dialogue and piano return."""
    voices = deepcopy(voices)
    if len(voices) == 3:
        melody, right, bass = voices
        inner = [[(_register(bar[min(1, len(bar) - 1)][0], 48, 59), d)
                  for _, d in _hold(None, _length(bar))] for bar in right]
        voices = [melody, right, inner, bass]
    if len(voices) != 4 or any(len(lane) != 17 for lane in voices):
        raise ValueError('Amazing Grace requires the complete seventeen-bar source tune')
    source_lengths = [_length(bar) for bar in voices[0]]
    if source_lengths != [F(3, 2)] + [F(9, 2)] * 15 + [F(3)]:
        raise ValueError('Amazing Grace must preserve its pickup and complementary final bar')
    eb = [_p('E', 4, -1), _p('G', 4), _p('B', 4, -1)]
    ab = [_p('A', 3, -1), _p('C', 4), _p('E', 4, -1)]
    fm = [_p('F', 4), _p('A', 4, -1), _p('C', 5)]
    bb = [_p('B', 3, -1), _p('D', 4), _p('F', 4)]
    intro = [[], [], [], []]
    intro_violin = [_hold(None, F(9, 2)), _hold(None, F(9, 2)),
                    [(_p('B', 4, -1), F(3, 2)), (_p('E', 5, -1), F(3, 2)), (_p('G', 5), F(3, 2))],
                    [(_p('F', 5), F(3, 2)), (_p('D', 5), F(3, 2)), (_p('B', 4, -1), F(3, 2))]]
    for index, (chord, bass) in enumerate([(eb, _p('E', 2, -1)), (ab, _p('A', 2, -1)),
                                           (fm, _p('F', 2)), (bb, _p('B', 2, -1))]):
        intro[0].append(intro_violin[index])
        harmony = _grace_harmony(chord, bass, F(9, 2))
        for i in range(3):
            intro[i + 1].append(harmony[i])
    theme = [_transpose_lane(lane, 0) for lane in voices]
    interlude_violin = [
        [(_p('G', 5), F(3, 2)), (_p('E', 5, -1), F(3, 2)), (_p('B', 4, -1), F(3, 2))],
        [(_p('A', 4, -1), F(3, 4)), (_p('B', 4, -1), F(3, 4)), (_p('C', 5), F(3, 2)), (_p('E', 5, -1), F(3, 2))],
        [(_p('G', 5), F(3, 2)), (_p('F', 5), F(3, 4)), (_p('E', 5, -1), F(3, 4)), (_p('D', 5), F(3, 2))],
        [(_p('F', 5), F(3, 2)), (_p('D', 5), F(3, 2)), (_p('B', 4, -1), F(3, 2))],
        [(_p('E', 5, -1), F(3, 4)), (_p('F', 5), F(3, 4)), (_p('G', 5), F(3, 2)), (_p('B', 5, -1), F(3, 2))],
        [(_p('A', 5, -1), F(3, 2)), (_p('G', 5), F(3, 4)), (_p('F', 5), F(3, 4)), (_p('E', 5, -1), F(3, 2))],
        [(_p('C', 5), F(3, 2)), (_p('E', 5, -1), F(3, 2)), (_p('F', 5), F(3, 2))],
        [(_p('F', 5), F(3, 2)), (_p('D', 5), F(3, 2)), (_p('B', 4, -1), F(3, 2))]]
    interlude = [interlude_violin, [], [], []]
    for chord, bass in [(eb, _p('E', 2, -1)), (ab, _p('A', 2, -1)),
                        (eb, _p('E', 2, -1)), (bb, _p('B', 2, -1)),
                        (eb, _p('E', 2, -1)), (ab, _p('A', 2, -1)),
                        (fm, _p('F', 2)), (bb, _p('B', 2, -1))]:
        harmony = _grace_harmony(chord, bass, F(9, 2), blocks=True)
        for i in range(3):
            interlude[i + 1].append(harmony[i])
    counter = []
    for index, bar in enumerate(voices[1]):
        length = _length(bar)
        guide = _register(next(p for p, _ in bar[1:] + bar[:1] if p is not None), 62, 74)
        if index and index % 4 == 0 and length > F(3, 2):
            counter.append(_hold(guide, length - F(3, 2)) + _hold(None, F(3, 2)))
        else:
            counter.append(_hold(guide, length))
    return_theme = [counter, _transpose_lane(voices[0], -1),
                    _transpose_lane(voices[1], -1), _transpose_lane(voices[3], 0)]
    coda_violin = [
        [(_p('G', 5), F(3, 2)), (_p('F', 5), F(3, 4)), (_p('E', 5, -1), F(3, 4)), (_p('B', 4, -1), F(3, 2))],
        [(_p('A', 5, -1), F(3, 2)), (_p('G', 5), F(3, 4)), (_p('F', 5), F(3, 4)), (_p('E', 5, -1), F(3, 2))],
        [(_p('F', 5), F(3, 2)), (_p('D', 5), F(3, 2)), (_p('B', 4, -1), F(3, 2))],
        _hold(_p('E', 5, -1), 3)]
    coda = [coda_violin, [], [], []]
    for chord, bass, length in [(eb, _p('E', 2, -1), F(9, 2)),
                                (ab, _p('A', 2, -1), F(9, 2)),
                                (bb, _p('B', 2, -1), F(9, 2)),
                                (eb, _p('E', 2, -1), F(3))]:
        harmony = _grace_harmony(chord, bass, length, blocks=True)
        for i in range(3):
            coda[i + 1].append(harmony[i])
    lanes = [sum((section[i] for section in [intro, theme, interlude, return_theme, coda]), []) for i in range(4)]
    sections = [
        {'bar': 0, 'name': '前奏 · Introduction', 'tempo': 66, 'dynamics': [62, 56]},
        {'bar': 4, 'name': '完整主题 · Theme', 'tempo': 78, 'dynamics': [82, 58]},
        {'bar': 21, 'name': '器乐对答 · Instrumental interlude', 'tempo': 78, 'dynamics': [80, 66]},
        {'bar': 29, 'name': '钢琴再现 · Piano return', 'tempo': 84, 'dynamics': [58, 84]},
        {'bar': 46, 'name': '尾声 · Coda', 'tempo': 66, 'dynamics': [72, 60]}]
    _verify_tune(lanes[0][4:21], voices[0])
    _verify_tune(lanes[1][29:46], voices[0], -1)
    report = _report(lanes, sections, voices, F(9, 2))
    report['completeTunePresentations'] = [
        {'bar': 4, 'bars': 17, 'lane': 0, 'instrument': 'violin', 'octaveChange': 0},
        {'bar': 29, 'bars': 17, 'lane': 1, 'instrument': 'piano', 'octaveChange': -1}]
    return {'lanes': lanes, 'sections': sections,
            'description': 'Music Viewer 完整小提琴与钢琴编曲：前奏、完整传统旋律、原创器乐对答、钢琴再现与尾声；不是主题的整曲循环。',
            'report': report}
