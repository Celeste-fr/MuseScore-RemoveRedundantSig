//=============================================================================
// RemoveRedundantSig v1.0.0 — MuseScore 3.5+
//
// License: MIT (see LICENSE)
// The behaviors below were validated empirically on MuseScore 3.6.2;
// see README.md for the full story, guarantees, and limitations.
//
// Removes metrically-redundant time signatures WITHOUT triggering
// MuseScore's rebar logic, so layout breaks, volta offsets, spacers,
// stretch — everything — survives.
//
// MODES (dispatched by selection):
//   SINGLE  — one time signature selected: delete it (permissive on
//             display style; you clicked it, you mean it).
//   BATCH   — nothing selected: sweep ALL fully-redundant signatures.
//             Conservative: full identity match required (sigN, sigD,
//             display subtype, custom text — numeric 4/4 after common-time
//             C is KEPT), never the first sig, never right after a section
//             break, and required in every staff at the same ordinal
//             (which also protects local/per-staff sigs). Courtesy sigs
//             are generated at layout time, never stored, thus untouchable.
//   UNDO    — nothing selected AND current state == post-surgery snapshot:
//             offers Undo / Clean Up / Cancel. Undo can never eat work —
//             if you've edited since, Ctrl+Z back to the post-surgery
//             state first.
//
// FILE FORMATS:
//   .mscx — byte-surgical: the XML on disk is edited directly; the only
//           delta is the removed <TimeSig> lines. (Strongest guarantee.)
//   .mscz — roundtrip: current state is serialized to a temp .mscx, the
//           same surgery runs on that text, and MuseScore repacks it over
//           the original (.mscz is written by writeScore). Output is
//           MuseScore's canonical serialization of the surgered score —
//           everything that survives Ctrl+S survives, but the result is
//           not a byte-level edit of the original zip.
//
// FILES (in .mscbackup next to the score, stable names, overwritten):
//   <name>.rrs.bak        pre-surgery state. For .mscx: exact copy of the
//                         file. For .mscz: the pre-surgery .mscx
//                         serialization (restored by repacking).
//   <name>.rrs.post.mscx  post-surgery snapshot (undo eligibility oracle).
//=============================================================================

import QtQuick 2.2
import QtQuick.Dialogs 1.2
import QtQuick.Window 2.2
import QtQuick.Controls 1.1
import MuseScore 3.0
import FileIO 3.0

MuseScore {
    menuPath: "Plugins.RemoveRedundantSig"
    version: "1.0.0"
    description: "Remove redundant time signatures losslessly (.mscx and .mscz). Select one to remove it; select nothing to sweep all / undo."
    requiresScore: true

    // ---- state --------------------------------------------------------------
    property string mode: ""          // "single" | "batch" | "noselect"
    property bool isMscz: false
    property int targetIdx: -1
    property int expN: 0
    property int expD: 0
    property string filePath: ""
    property string backupPath: ""
    property string sidecarPath: ""
    property string workActual: ""    // temp .mscx really written by writeScore
    property string successLog: ""
    property bool undoMode: false
    property var origScore: null
    property var pipeline: []
    property int pipelineStep: 0

    FileIO { id: srcFile }
    FileIO { id: bakFile }
    FileIO { id: chkFile }

    MessageDialog {
        id: msg
        title: "RemoveRedundantSig"
        onAccepted: Qt.quit()
        onRejected: Qt.quit()
        function report(t) { text = t; open(); }
    }

    // Choice window with properly-labeled buttons (MessageDialog can't
    // rename its standard buttons).
    Window {
        id: choiceWin
        title: "RemoveRedundantSig"
        modality: Qt.ApplicationModal
        flags: Qt.Dialog
        width: 440
        height: 150
        visible: false
        property bool handled: false
        onClosing: { if (!handled) Qt.quit(); }   // titlebar X = Cancel

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 20

            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Nothing has changed since the last surgery.\n"
                    + "Undo it, or clean up all redundant time signatures?"
            }

            Row {
                spacing: 8
                anchors.right: parent.right

                Button {
                    text: "Undo"
                    onClicked: {
                        choiceWin.handled = true;
                        choiceWin.visible = false;
                        performUndo();
                    }
                }
                Button {
                    text: "Clean Up"
                    onClicked: {
                        choiceWin.handled = true;
                        choiceWin.visible = false;
                        mode = "batch";
                        autoSaveThenAct();
                    }
                }
                Button {
                    text: "Cancel"
                    onClicked: {
                        choiceWin.handled = true;
                        choiceWin.visible = false;
                        Qt.quit();
                    }
                }
            }
        }
    }

    FileDialog {
        id: fileDlg
        title: "Select the saved file of the current score"
        selectExisting: true
        nameFilters: ["MuseScore files (*.mscx *.mscz)"]
        onAccepted: {
            filePath = urlToPath(fileDlg.fileUrl);
            isMscz = /\.mscz$/i.test(filePath);
            if (mode === "noselect") decideNoSelection();
            else autoSaveThenAct();
        }
        onRejected: Qt.quit()
    }

    // ---- path & string utilities ---------------------------------------------

    function urlToPath(u) {
        var s = u.toString();
        if (s.indexOf("file://") === 0) s = s.substring(7);
        if (/^\/[A-Za-z]:/.test(s)) s = s.substring(1);   // /C:/... -> C:/...
        return decodeURIComponent(s);
    }

    function pathParts(fp) {
        var cut = Math.max(fp.lastIndexOf("/"), fp.lastIndexOf("\\"));
        return { dir: fp.substring(0, cut),
                 base: fp.substring(cut + 1),
                 sep: fp.charAt(cut) };
    }

    function fileExists(p) {
        if (typeof chkFile.exists !== "function") return false;
        chkFile.source = p;
        return chkFile.exists();
    }

    // Read a file, tolerating writeScore builds that append the extension.
    function readWithExtFallback(p) {
        chkFile.source = p;
        var t = chkFile.read();
        if (!t || !t.length) {
            chkFile.source = p + ".mscx";
            t = chkFile.read();
        }
        return t;
    }

    function backupPathFor(fp) {
        var pp = pathParts(fp);
        var bdir = pp.dir + pp.sep + ".mscbackup";
        if (fileExists(bdir))
            return bdir + pp.sep + pp.base + ".rrs.bak";
        console.log("no .mscbackup folder found — falling back to same-dir .bak");
        return fp + ".bak";
    }

    function sidecarPathFor(fp) {
        var pp = pathParts(fp);
        var bdir = pp.dir + pp.sep + ".mscbackup";
        if (fileExists(bdir))
            return bdir + pp.sep + pp.base + ".rrs.post.mscx";
        return fp + ".rrs.post.mscx";
    }

    function sigEq(a, b) {
        return a && b
            && a.numerator === b.numerator
            && a.denominator === b.denominator;
    }

    function lineStart(text, i) { return text.lastIndexOf("\n", i) + 1; }

    function lineEnd(text, i) {
        var j = text.indexOf("\n", i);
        return j === -1 ? text.length : j + 1;
    }

    function normalizeForCompare(text) {
        var lines = text.split("\n");
        var out = [];
        for (var i = 0; i < lines.length; ++i) {
            if (lines[i].indexOf("<programVersion") !== -1) continue;
            if (lines[i].indexOf("<programRevision") !== -1) continue;
            if (lines[i].indexOf("creationDate") !== -1) continue;
            out.push(lines[i]);
        }
        return out.join("\n");
    }

    // Serialize a score to <tempdir>/<name>.mscx; returns the actual path
    // written (extension quirks resolved) or "".
    function serializeScoreTo(score, name) {
        var base = chkFile.tempPath() + "/" + name;
        if (!writeScore(score, base + ".mscx", "mscx")) {
            console.log("serializeScoreTo: writeScore failed for " + name);
            return "";
        }
        if (fileExists(base + ".mscx")) return base + ".mscx";
        if (fileExists(base + ".mscx.mscx")) return base + ".mscx.mscx";
        return "";
    }

    function serializeCurrentScore() {
        var p = serializeScoreTo(curScore, "rrs_state");
        if (!p) return "";
        chkFile.source = p;
        var t = chkFile.read();
        if (typeof chkFile.remove === "function")
            chkFile.remove();
        return t || "";
    }

    // Post-auto-save invariant for .mscx: serialized memory must equal
    // disk. Not checkable for .mscz (binary), where the auto-save itself
    // is the guarantee that matters. Fails OPEN if the check can't run.
    function isFileInSync() {
        if (isMscz) {
            console.log("sync-check: skipped for .mscz (binary container)");
            return true;
        }
        var mem = serializeCurrentScore();
        chkFile.source = filePath;
        var disk = chkFile.read();
        if (!mem.length || !disk || !disk.length) {
            console.log("sync-check: couldn't compare — skipping check");
            return true;
        }
        var same = normalizeForCompare(mem) === normalizeForCompare(disk);
        console.log("sync-check: in-memory vs disk -> "
                  + (same ? "IN SYNC" : "DIFFERENT"));
        return same;
    }

    // ---- XML scanning ----------------------------------------------------------

    function collectStaffBlocks(text) {
        var out = [];
        var pos = 0;
        while (true) {
            var s = text.indexOf("<Staff id=", pos);
            if (s === -1) break;
            var e = text.indexOf("</Staff>", s);
            if (e === -1) break;
            e += "</Staff>".length;
            if (text.substring(s, e).indexOf("<Measure") !== -1)
                out.push({ start: s, end: e });
            pos = e;
        }
        return out;
    }

    function sigIdentity(body) {
        function grab(re) { var m = re.exec(body); return m ? m[1] : ""; }
        return {
            n:       grab(/<sigN>(\d+)<\/sigN>/),
            d:       grab(/<sigD>(\d+)<\/sigD>/),
            subtype: grab(/<subtype>([\s\S]*?)<\/subtype>/),
            textN:   grab(/<textN>([\s\S]*?)<\/textN>/),
            textD:   grab(/<textD>([\s\S]*?)<\/textD>/)
        };
    }

    function identityEq(a, b) {
        return a && b && a.n.length && a.d.length
            && a.n === b.n && a.d === b.d
            && a.subtype === b.subtype
            && a.textN === b.textN && a.textD === b.textD;
    }

    function forEachMeasure(text, blk, visit) {
        var pos = blk.start;
        var idx = 0;
        while (true) {
            var ms = text.indexOf("<Measure", pos);
            if (ms === -1 || ms >= blk.end) return idx;
            var me = text.indexOf("</Measure>", ms);
            if (me === -1 || me >= blk.end) return -1;
            me += "</Measure>".length;

            var tsStart = -1, tsEnd = -1, ident = null;
            var ts = text.indexOf("<TimeSig>", ms);
            if (ts !== -1 && ts < me) {
                tsStart = ts;
                tsEnd = text.indexOf("</TimeSig>", ts);
                if (tsEnd === -1) return -1;
                tsEnd += "</TimeSig>".length;
                ident = sigIdentity(text.substring(tsStart, tsEnd));
            }
            if (visit(idx, ms, me, tsStart, tsEnd, ident) === false)
                return idx;
            pos = me;
            ++idx;
        }
    }

    function findSingleTarget(text, blk, tIdx, n, d) {
        var result = { found: false, reason: "measure ordinal out of range" };
        var prevailing = null;
        forEachMeasure(text, blk, function (idx, ms, me, tsS, tsE, ident) {
            if (idx === tIdx) {
                if (!ident)
                    result = { found: false, reason: "no <TimeSig> in measure "
                               + (tIdx + 1) + " of the serialized score" };
                else if (ident.n !== String(n) || ident.d !== String(d))
                    result = { found: false, reason: "found " + ident.n + "/"
                               + ident.d + " there, expected " + n + "/" + d };
                else if (!prevailing || prevailing.n !== String(n)
                                     || prevailing.d !== String(d))
                    result = { found: false,
                               reason: "prevailing sig doesn't match — refusing" };
                else
                    result = { found: true,
                               delStart: lineStart(text, tsS),
                               delEnd:   lineEnd(text, tsE - 1) };
                return false;
            }
            if (ident) prevailing = ident;
            return true;
        });
        return result;
    }

    function scanStaffBatch(text, blk) {
        var cands = {};
        var prevailing = null;
        forEachMeasure(text, blk, function (idx, ms, me, tsS, tsE, ident) {
            if (ident) {
                if (prevailing && identityEq(prevailing, ident))
                    cands[idx] = { delStart: lineStart(text, tsS),
                                   delEnd:   lineEnd(text, tsE - 1) };
                else
                    prevailing = ident;
            }
            return true;
        });
        return cands;
    }

    function sectionBreakOrdinals(text, blk) {
        var set = {};
        forEachMeasure(text, blk, function (idx, ms, me) {
            var p = text.indexOf("<LayoutBreak>", ms);
            while (p !== -1 && p < me) {
                var q = text.indexOf("</LayoutBreak>", p);
                if (q === -1 || q > me) break;
                if (/<subtype>\s*section\s*<\/subtype>/.test(text.substring(p, q)))
                    set[idx] = true;
                p = text.indexOf("<LayoutBreak>", q);
            }
            return true;
        });
        return set;
    }

    // Mode-dependent range computation over serialized text.
    // Returns { ok:true, ranges:[...], log:"..." } or { ok:false, err }.
    function prepareRanges(text) {
        var staves = collectStaffBlocks(text);
        if (!staves.length)
            return { ok: false, err: "No measure-bearing <Staff> blocks found." };

        if (mode === "single") {
            var ranges = [];
            for (var i = 0; i < staves.length; ++i) {
                var r = findSingleTarget(text, staves[i], targetIdx, expN, expD);
                if (!r.found)
                    return { ok: false, err: "Staff block " + (i + 1) + ": "
                             + r.reason + "\n\n(All staves must carry the "
                             + "redundant signature at the same measure — "
                             + "per-staff/local time signatures are not "
                             + "supported.)" };
                ranges.push(r);
            }
            return { ok: true, ranges: ranges,
                     log: "Deleted redundant " + expN + "/" + expD
                        + " at measure " + (targetIdx + 1) + " in "
                        + ranges.length + " staff block(s)." };
        }

        // batch
        var perStaff = [];
        for (var j = 0; j < staves.length; ++j)
            perStaff.push(scanStaffBatch(text, staves[j]));
        var sections = sectionBreakOrdinals(text, staves[0]);

        var ordinals = [];
        for (var key in perStaff[0]) {
            var ord = parseInt(key, 10);
            if (sections[ord - 1]) {
                console.log("measure " + (ord + 1)
                          + ": redundant but follows a section break — kept");
                continue;
            }
            var everywhere = true;
            for (var s = 1; s < perStaff.length; ++s)
                if (!(key in perStaff[s])) { everywhere = false; break; }
            if (everywhere) ordinals.push(ord);
            else console.log("measure " + (ord + 1)
                           + ": not redundant in all staves (local sig?) — kept");
        }

        if (!ordinals.length)
            return { ok: false, none: true,
                     err: "No redundant time signatures found.\n\n(Reminder: "
                        + "signatures with different display styles — e.g. "
                        + "numeric 4/4 after common-time C — and signatures "
                        + "after section breaks are deliberately kept. To "
                        + "force one out, select it and run the plugin.)" };

        ordinals.sort(function (a, b) { return a - b; });
        var batchRanges = [];
        var measureList = [];
        for (var o = 0; o < ordinals.length; ++o) {
            measureList.push(ordinals[o] + 1);
            for (var t = 0; t < perStaff.length; ++t)
                batchRanges.push(perStaff[t][String(ordinals[o])]);
        }
        return { ok: true, ranges: batchRanges,
                 log: "Batch: removed " + ordinals.length
                    + " redundant time signature(s) at measure(s) "
                    + measureList.join(", ") + " across " + staves.length
                    + " staff block(s)." };
    }

    function spliceRanges(text, ranges) {
        ranges.sort(function (a, b) { return b.delStart - a.delStart; });
        for (var k = 0; k < ranges.length; ++k)
            text = text.substring(0, ranges[k].delStart)
                 + text.substring(ranges[k].delEnd);
        return text;
    }

    // ---- flow ---------------------------------------------------------------------

    function autoSaveThenAct() {
        console.log("auto-saving via cmd(\"file-save\"), then verifying");
        cmd("file-save");
        saveRetryTimer.start();
    }

    Timer {
        id: saveRetryTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (!isFileInSync()) {
                msg.report("Auto-saved, but the serialized score still doesn't "
                         + "match the file on disk (save failed? external "
                         + "modification? serializer drift?). Aborting with no "
                         + "changes to the file.");
                return;
            }
            backupPath = backupPathFor(filePath);
            sidecarPath = sidecarPathFor(filePath);
            console.log("backup -> " + backupPath);
            if (isMscz) doMsczSurgery();
            else doMscxSurgery();
        }
    }

    // ---- .mscx surgery (byte-surgical, v0.5 behavior) --------------------------

    function doMscxSurgery() {
        srcFile.source = filePath;
        var text = srcFile.read();
        if (!text || text.indexOf("<museScore") === -1) {
            msg.report("Couldn't read a MuseScore XML file at:\n" + filePath);
            return;
        }
        var prep = prepareRanges(text);
        if (!prep.ok) {
            msg.report(prep.none ? prep.err
                                 : "Aborting, no changes made.\n" + prep.err);
            return;
        }
        bakFile.source = backupPath;
        if (!bakFile.write(text)) {
            msg.report("Failed to write backup " + backupPath
                     + " — aborting, no changes made.");
            return;
        }
        srcFile.source = filePath;
        if (!srcFile.write(spliceRanges(text, prep.ranges))) {
            msg.report("FAILED to write " + filePath
                     + "\nYour original is intact at " + backupPath);
            return;
        }
        successLog = prep.log + " Backup: " + backupPath;
        undoMode = false;
        startPipeline(mscxSwapSteps());
    }

    // ---- .mscz surgery (serialize -> surgery -> repack) --------------------------

    function doMsczSurgery() {
        workActual = serializeScoreTo(curScore, "rrs_work");
        if (!workActual) {
            msg.report("Couldn't serialize the current score to a temp .mscx "
                     + "— aborting, nothing touched.");
            return;
        }
        chkFile.source = workActual;
        var text = chkFile.read();
        if (!text || text.indexOf("<museScore") === -1) {
            msg.report("Temp serialization at " + workActual
                     + " is unreadable — aborting, nothing touched.");
            return;
        }
        var prep = prepareRanges(text);
        if (!prep.ok) {
            msg.report(prep.none ? prep.err
                                 : "Aborting, no changes made.\n" + prep.err);
            return;
        }
        // backup = pre-surgery serialization (restorable by repacking)
        bakFile.source = backupPath;
        if (!bakFile.write(text)) {
            msg.report("Failed to write backup " + backupPath
                     + " — aborting, no changes made.");
            return;
        }
        srcFile.source = workActual;
        if (!srcFile.write(spliceRanges(text, prep.ranges))) {
            msg.report("Failed to write temp file " + workActual
                     + " — aborting, original untouched.");
            return;
        }
        successLog = prep.log + " Backup: " + backupPath;
        undoMode = false;
        startPipeline(msczRepackSteps());
    }

    // ---- undo -------------------------------------------------------------------

    function performUndo() {
        chkFile.source = backupPath;
        var text = chkFile.read();
        if (!text || text.indexOf("<museScore") === -1) {
            msg.report("Backup at\n" + backupPath
                     + "\nis unreadable — nothing restored.");
            return;
        }
        undoMode = true;
        successLog = "Undid last surgery: restored " + filePath
                   + " from " + backupPath;
        if (!isMscz) {
            srcFile.source = filePath;
            if (!srcFile.write(text)) {
                msg.report("FAILED to write " + filePath + " — file may be "
                         + "locked. The backup is untouched at:\n" + backupPath);
                return;
            }
            consumeSidecar();
            startPipeline(mscxSwapSteps());
        } else {
            // stage the backup serialization as the repack source
            workActual = chkFile.tempPath() + "/rrs_work.mscx";
            srcFile.source = workActual;
            if (!srcFile.write(text)) {
                msg.report("Failed to stage temp file " + workActual
                         + " — nothing restored.");
                return;
            }
            consumeSidecar();
            startPipeline(msczRepackSteps());
        }
    }

    function consumeSidecar() {
        chkFile.source = sidecarPath;
        if (chkFile.exists() && typeof chkFile.remove === "function")
            chkFile.remove();
    }

    // Nothing selected: offer undo if eligible, else batch sweep.
    function decideNoSelection() {
        backupPath = backupPathFor(filePath);
        sidecarPath = sidecarPathFor(filePath);
        if (fileExists(backupPath) && fileExists(sidecarPath)) {
            var post = readWithExtFallback(sidecarPath);
            var now = serializeCurrentScore();
            if (post && post.length && now.length
                && normalizeForCompare(now) === normalizeForCompare(post)) {
                choiceWin.handled = false;
                choiceWin.visible = true;
                return;
            }
        }
        mode = "batch";
        autoSaveThenAct();
    }

    // ---- step pipeline (each tab operation gets its own event-loop turn) ---------

    function startPipeline(steps) {
        pipeline = steps;
        pipelineStep = 0;
        origScore = curScore;
        stepTimer.start();
    }

    Timer {
        id: stepTimer
        interval: 200
        repeat: true
        onTriggered: {
            if (pipelineStep >= pipeline.length) {
                stepTimer.stop();
                console.log(successLog);
                Qt.quit();                        // silent success
                return;
            }
            var step = pipeline[pipelineStep];
            console.log("pipeline step " + (pipelineStep + 1) + "/"
                      + pipeline.length + ": " + step.desc);
            var ok = false;
            try { ok = step.run(); }
            catch (err) { console.log("  threw: " + err); }
            if (!ok) {
                stepTimer.stop();
                msg.report("Pipeline failed at step " + (pipelineStep + 1)
                         + " (" + step.desc + ").\n\nThe pre-surgery backup "
                         + "is at:\n" + backupPath
                         + "\n\nIf your score tab is gone, simply reopen:\n"
                         + filePath);
                return;
            }
            ++pipelineStep;
        }
    }

    property var pipeScore: null      // score object carried between steps

    // .mscx: file already rewritten; close stale tab, reopen, snapshot.
    function mscxSwapSteps() {
        return [
            { desc: "close stale tab",
              run: function () {
                  if (typeof closeScore === "function") closeScore(origScore);
                  else cmd("file-close");
                  return true;
              } },
            { desc: "reopen edited file",
              run: function () {
                  pipeScore = readScore(filePath);
                  return pipeScore !== null && pipeScore !== undefined;
              } },
            { desc: "write post-surgery snapshot",
              run: function () {
                  if (undoMode) return true;
                  if (!writeScore(pipeScore, sidecarPath, "mscx"))
                      console.log("WARNING: snapshot write failed — undo of "
                                + "this surgery won't be offered");
                  return true;
              } }
        ];
    }

    // .mscz: original tab closes FIRST (so no stale tab can ever sit over
    // an updated file); then temp is loaded, repacked over the original,
    // temp closed, original reopened, snapshot written.
    function msczRepackSteps() {
        return [
            { desc: "close original tab",
              run: function () {
                  if (typeof closeScore === "function") closeScore(origScore);
                  else cmd("file-close");
                  return true;
              } },
            { desc: "load surgered temp .mscx",
              run: function () {
                  pipeScore = readScore(workActual);
                  return pipeScore !== null && pipeScore !== undefined;
              } },
            { desc: "repack over original .mscz",
              run: function () {
                  return writeScore(pipeScore, filePath, "mscz");
              } },
            { desc: "close temp tab",
              run: function () {
                  if (typeof closeScore === "function") closeScore(pipeScore);
                  else cmd("file-close");
                  return true;
              } },
            { desc: "reopen original .mscz",
              run: function () {
                  pipeScore = readScore(filePath);
                  return pipeScore !== null && pipeScore !== undefined;
              } },
            { desc: "write post-surgery snapshot",
              run: function () {
                  if (undoMode) return true;
                  if (!writeScore(pipeScore, sidecarPath, "mscx"))
                      console.log("WARNING: snapshot write failed — undo of "
                                + "this surgery won't be offered");
                  return true;
              } }
        ];
    }

    // ---- entry ---------------------------------------------------------------------

    onRun: {
        var sel = curScore.selection ? curScore.selection.elements : null;
        var isSingle = (sel && sel.length === 1
                        && sel[0].type === Element.TIMESIG);

        var p = (curScore.path !== undefined) ? curScore.path : "";
        if (p) {
            isMscz = /\.mscz$/i.test(p);
            if (isMscz) console.log("compressed .mscz — using repack pipeline");
        }

        if (!isSingle) {
            mode = "noselect";
            if (p && /\.(mscx|mscz)$/i.test(p)) {
                filePath = p;
                decideNoSelection();
            } else {
                fileDlg.open();
            }
            return;
        }

        mode = "single";
        var ts  = sel[0];
        var seg = ts.parent;
        var m   = seg ? seg.parent : null;
        if (!m || m.type !== Element.MEASURE) {
            msg.report("Couldn't resolve the measure containing this time "
                     + "signature.\n(If you clicked a courtesy copy at a line "
                     + "end, select the real one at the start of the next "
                     + "system.)");
            return;
        }
        if (!m.prevMeasure) {
            msg.report("That's the initial time signature — refusing.");
            return;
        }
        var here = m.timesigNominal;
        var prev = m.prevMeasure.timesigNominal;
        if (!sigEq(here, prev)) {
            msg.report("Not redundant: this measure is " + here.numerator + "/"
                     + here.denominator + " but the previous measure is "
                     + prev.numerator + "/" + prev.denominator
                     + ".\nAborting with no changes.");
            return;
        }
        expN = here.numerator;
        expD = here.denominator;

        targetIdx = 0;
        for (var w = curScore.firstMeasure; w && !w.is(m); w = w.nextMeasure)
            ++targetIdx;
        console.log("Target: " + expN + "/" + expD + " at measure ordinal "
                  + targetIdx + " (measure " + (targetIdx + 1) + ")");

        if (p && /\.(mscx|mscz)$/i.test(p)) {
            filePath = p;
            autoSaveThenAct();
            return;
        }
        console.log("Score path unavailable via API — asking via file dialog.");
        fileDlg.open();
    }
}
