"use strict";
window.scorefilm = {
  async layout(xml, options) {
    const doc = new DOMParser().parseFromString(xml, "application/xml");
    if (doc.querySelector("parsererror")) throw new Error("Invalid layout XML");
    // OSMD does not retain MusicXML note IDs. Carry an explicit token through its
    // documented NoteheadColorXml field, bind source objects, then restore ink.
    // This is an identity bridge, never a match by SVG order or screen position.
    const tokens = new Map();
    let serial = 0;
    for (const node of doc.querySelectorAll("part > measure > note")) {
      const token = "#" + (++serial).toString(16).padStart(6, "0").toUpperCase();
      tokens.set(token, node.getAttribute("id"));
      node.setAttribute("color", token);
      const head = node.querySelector("notehead");
      if (head) head.setAttribute("color", token);
    }
    const osmd = new opensheetmusicdisplay.OpenSheetMusicDisplay("score", {
      autoResize: false, backend: "svg", drawTitle: true, drawComposer: true,
      drawPartNames: true, drawMeasureNumbers: true,
      pageFormat: (options.paper === "letter" ? "Letter" : "A4") + (options.orientation === "landscape" ? "_L" : "_P"),
      newSystemFromXML: options.preserveBreaks, newPageFromXML: options.preserveBreaks
    });
    await osmd.load(doc);
    const sourceNotes = [];
    const issues = [];
    for (const measure of osmd.Sheet.SourceMeasures) {
      for (const container of measure.VerticalSourceStaffEntryContainers) {
        for (const staff of container.StaffEntries) {
          if (!staff) continue;
          for (const voice of staff.VoiceEntries) {
            voice.StemColor = "#18232C";
            for (const note of voice.Notes) {
              const token = String(note.NoteheadColorXml || "").toUpperCase();
              const sourceID = tokens.get(token);
              if (sourceID) sourceNotes.push({note, sourceID});
              else if (!note.isRest() && issues.length < 8) issues.push(`unidentified source: color=${note.NoteheadColorXml}, resolved=${note.NoteheadColor}, measure=${measure.MeasureNumber}, fields=${Object.keys(note).join(",")}`);
              note.NoteheadColor = "#18232C";
            }
          }
        }
      }
    }
    osmd.Zoom = options.scale || 1;
    await document.fonts.ready;
    osmd.render();
    const svgs = [...document.querySelectorAll("#score svg")];
    const anchors = [];
    const systems = new Map();
    for (const {note, sourceID} of sourceNotes) {
      if (note.isRest()) continue;
      const graphical = osmd.EngravingRules.GNote(note);
      if (!graphical) { issues.push(`${sourceID}: no graphical note`); continue; }
      // Each GraphicalNote points to its VexFlow chord and its own key index.
      // getNoteheadSVGs returns the whole chord, so choosing [0] conflates its heads.
      const heads = graphical.getNoteheadSVGs?.();
      const head = heads?.[graphical.vfnoteIndex];
      if (!head) { issues.push(`${sourceID}: missing head at chord index ${graphical.vfnoteIndex}, head count ${heads?.length}`); continue; }
      const svg = head.ownerSVGElement;
      const page = svgs.indexOf(svg);
      if (page < 0) { issues.push(`${sourceID}: SVG page not found`); continue; }
      const box = head.getBBox();
      const transform = svg.getCTM().inverse().multiply(head.getCTM());
      const point = svg.createSVGPoint();
      point.x = box.x + box.width/2; point.y = box.y + box.height/2;
      const center = point.matrixTransform(transform);
      const systemObject = graphical.parentVoiceEntry?.parentStaffEntry?.parentMeasure?.ParentMusicSystem;
      if (!systemObject) throw new Error(`Missing music system identity for ${sourceID}`);
      if (!systems.has(systemObject)) systems.set(systemObject, systems.size);
      anchors.push({sourceID, page, x: center.x, y: center.y, radius: Math.max(3, box.width * Math.hypot(transform.a,transform.b)/2), system: `${page}:${systems.get(systemObject)}`});
    }
    const pages = [];
    for (const svg of svgs) {
      const width = svg.viewBox.baseVal.width || parseFloat(svg.getAttribute("width"));
      const height = svg.viewBox.baseVal.height || parseFloat(svg.getAttribute("height"));
      svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
      const blob = new Blob([new XMLSerializer().serializeToString(svg)], {type:"image/svg+xml"});
      const url = URL.createObjectURL(blob);
      const image = new Image();
      try {
        image.src = url; await image.decode();
        const scale = Math.min(2, 4096/Math.max(width,height));
        const canvas = document.createElement("canvas");
        canvas.width = Math.ceil(width*scale); canvas.height = Math.ceil(height*scale);
        const context = canvas.getContext("2d");
        context.fillStyle = "white"; context.fillRect(0,0,canvas.width,canvas.height);
        context.drawImage(image,0,0,canvas.width,canvas.height);
        pages.push({width,height,png:canvas.toDataURL("image/png").split(",")[1]});
      } finally { URL.revokeObjectURL(url); }
    }
    const tagged = new Set(sourceNotes.map(x => x.sourceID));
    for (const sourceID of tokens.values()) if (!tagged.has(sourceID)) issues.push(`${sourceID}: source token not retained`);
    return {pages,anchors,issues};
  }
};
