#!/usr/bin/env python3
"""Generate original, redistributable studies. No reference-video music is copied."""
from pathlib import Path
import argparse
import copy
import hashlib
import json
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def study():
    score = ET.parse(ROOT / "Docs/Examples/Duet/score.musicxml").getroot()
    score.find("work/work-title").text = "Music Viewer · Paper and Light"
    score.find("identification/creator").text = "Original Music Viewer demonstration"
    for part in score.findall("part"):
        source = list(part)
        for measure in source:
            part.remove(measure)
        for cycle in range(4):
            for bar, original in enumerate(source):
                measure = copy.deepcopy(original)
                index = cycle * 4 + bar + 1
                measure.set("number", str(index))
                measure.set("id", f"{part.get('id')}-study-m{index}")
                for note in measure.findall("note"):
                    note.set("id", f"{note.get('id')}-cycle{cycle+1}")
                if cycle and bar == 0:
                    measure.insert(0, ET.Element("print", {"new-page": "yes"} if cycle == 2 else {"new-system": "yes"}))
                if index != 16:
                    for barline in measure.findall("barline"):
                        measure.remove(barline)
                if cycle == 1 and bar == 0 and part.get("id") == "P2":
                    for note in measure.findall("note"):
                        if note.findtext("voice") == "1" and note.find("pitch") is not None:
                            note.find("staff").text = "2"
                if cycle == 2 and bar == 1 and part.get("id") == "P1":
                    for note in measure.findall("note")[1:]:
                        rest = note.find("rest")
                        if rest is not None:
                            note.remove(rest)
                            pitch = ET.SubElement(note, "pitch")
                            ET.SubElement(pitch, "step").text = "G"
                            ET.SubElement(pitch, "octave").text = "4"
                        if note.find("tie") is None:
                            ET.SubElement(note, "tie", {"type": "stop"})
                        ET.SubElement(note, "tie", {"type": "start"})
                        marks = note.find("notations")
                        if marks is None:
                            marks = ET.SubElement(note, "notations")
                        if not any(x.get("type") == "stop" for x in marks.findall("tied")):
                            ET.SubElement(marks, "tied", {"type": "stop"})
                        ET.SubElement(marks, "tied", {"type": "start"})
                if cycle == 2 and bar == 2 and part.get("id") == "P1":
                    note = measure.find("note")
                    note.find("pitch/step").text = "G"
                    ET.SubElement(note, "tie", {"type": "stop"})
                    ET.SubElement(note.find("notations"), "tied", {"type": "stop"})
                # Keep the MusicXML note content sequence valid after adding ties/pitches.
                order = ["grace", "cue", "chord", "pitch", "unpitched", "rest", "duration", "tie", "instrument", "footnote", "level", "voice", "type", "dot", "accidental", "time-modification", "stem", "notehead", "notehead-text", "staff", "beam", "notations", "lyric", "play", "listen"]
                for note in measure.findall("note"):
                    note[:] = sorted(note, key=lambda node: order.index(node.tag) if node.tag in order else len(order))
                part.append(measure)
    xml = ET.tostring(score, encoding="utf-8", xml_declaration=True)
    (ROOT / "Tests/Fixtures").mkdir(exist_ok=True)
    (ROOT / "Tests/Fixtures/PaperAndLight.musicxml").write_bytes(xml)
    settings = json.loads((ROOT / "Docs/Examples/Duet/project.json").read_text())
    settings["scoreAxis"]["referencePartId"] = "P1"
    settings["routes"] = [{"id": f"violin-cycle{c+1}", "selector": {"partId": "P1", "voiceId": "1"}, "range": {"from": {"measureId": f"P1-study-m{c*4+3}", "beat": {"n": 0, "d": 1}}, "to": {"measureId": f"P1-study-m{c*4+4}", "beat": {"n": 4, "d": 1}}}, "instrumentId": "violin", "priority": 100} for c in range(4)]
    settings["visual"].pop("noteOverrides", None)
    entries = {"score.musicxml": xml, "project.json": json.dumps(settings, ensure_ascii=False, indent=2).encode()}
    manifest = {"format": "scorefilm", "version": "1.0.0", "profile": "scorefilm-mac-v1", "projectId": "fb300a8a-c637-490f-81af-28471581f7d2", "title": "Paper and Light", "files": {"notation": "score.musicxml", "settings": "project.json"}, "requiredCapabilities": ["notation.musicxml4", "routing.segment", "visual.trails.v1", "export.mp4"], "integrity": {key: hashlib.sha256(data).hexdigest() for key, data in entries.items()}}
    entries["manifest.json"] = json.dumps(manifest, ensure_ascii=False, indent=2).encode()
    with zipfile.ZipFile(ROOT / "Sources/ScoreFilm/Resources/PaperAndLight.scorefilm", "w", zipfile.ZIP_DEFLATED) as archive:
        for key, data in entries.items():
            info = zipfile.ZipInfo(key, date_time=(2026,10,29,0,0,0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)

def stress():
    score = ET.Element("score-partwise", {"version": "4.0"})
    ET.SubElement(ET.SubElement(score,"work"), "work-title").text = "Music Viewer Five Minute Stress Study"
    listing = ET.SubElement(score, "part-list")
    for part_index in range(8):
        part_id = f"P{part_index+1}"
        declaration = ET.SubElement(listing,"score-part",{"id":part_id})
        ET.SubElement(declaration,"part-name").text = f"Track {part_index+1}"
        inst = ET.SubElement(declaration,"score-instrument",{"id":part_id+"-I"})
        ET.SubElement(inst,"instrument-name").text = "Piano" if part_index<4 else "Violin"
        midi = ET.SubElement(declaration,"midi-instrument",{"id":part_id+"-I"})
        ET.SubElement(midi,"midi-program").text = "1" if part_index<4 else "41"
    for part_index in range(8):
        part_id = f"P{part_index+1}"
        part = ET.SubElement(score,"part",{"id":part_id})
        for bar in range(125):
            measure = ET.SubElement(part,"measure",{"number":str(bar+1),"id":f"{part_id}-m{bar+1}"})
            if bar==0:
                attributes=ET.SubElement(measure,"attributes")
                ET.SubElement(attributes,"divisions").text="2"
                time=ET.SubElement(attributes,"time"); ET.SubElement(time,"beats").text="4"; ET.SubElement(time,"beat-type").text="4"
                clef=ET.SubElement(attributes,"clef"); ET.SubElement(clef,"sign").text="G"; ET.SubElement(clef,"line").text="2"
                direction = ET.SubElement(measure,"direction")
                metronome = ET.SubElement(ET.SubElement(direction,"direction-type"),"metronome")
                ET.SubElement(metronome,"beat-unit").text="quarter"; ET.SubElement(metronome,"per-minute").text="100"
                ET.SubElement(direction,"sound",{"tempo":"100"})
            for voice in range(4):
                if voice: ET.SubElement(ET.SubElement(measure,"backup"),"duration").text="8"
                for step in range(8):
                    note=ET.SubElement(measure,"note",{"id":f"{part_id}-m{bar+1}-v{voice+1}-n{step+1}"})
                    pitch=ET.SubElement(note,"pitch"); ET.SubElement(pitch,"step").text=["C","D","E","G","A","G","E","D"][(step+voice)%8]; ET.SubElement(pitch,"octave").text=str(3+voice)
                    ET.SubElement(note,"duration").text="1"; ET.SubElement(note,"voice").text=str(voice+1); ET.SubElement(note,"type").text="eighth"
                    if voice==0 and step in (0,7): ET.SubElement(ET.SubElement(note,"notations"),"slur",{"type":"start" if step==0 else "stop","number":"1"})
    output=ROOT/"Outputs/Stress.musicxml"
    output.parent.mkdir(exist_ok=True)
    output.write_bytes(ET.tostring(score,encoding="utf-8",xml_declaration=True))
    print(output)

def features():
    output = ROOT / "Outputs/NotationFeatures.mxl"
    output.parent.mkdir(exist_ok=True)
    container = b'<?xml version="1.0"?><container><rootfiles><rootfile full-path="score.musicxml" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles></container>'
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("score.musicxml", (ROOT / "Tests/Fixtures/NotationFeatures.musicxml").read_bytes())
    print(output)

if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--stress",action="store_true"); mode.add_argument("--features",action="store_true")
    args=parser.parse_args()
    stress() if args.stress else features() if args.features else study()
