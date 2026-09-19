// Headless Ghidra script: find pointers to specific runtime localization-key strings
// (option_exit, main_menu, pause_resume, credits, settings, continue, level_select, ...)
// found by ThumperStringSearch.java. Unlike the flow-node event-name table and the
// screen-name table (both showed zero live references and are suspected to be
// dead/tooling-only debug data - see session-2026-07-13-table-xref.md and the
// flow-node scan), these are genuine "ui/thumper.en.credits"-style lookup keys that
// the running game must actually use to find and display menu text - so a live
// reference to one of these is a much stronger lead toward the real menu/label code.
//
// Checks EXACT addresses (not a byte range) for each known key string, both as an
// absolute 8-byte pointer and as a 4-byte MSVC-style RVA (offset from image base),
// across all initialized memory. Exact-address matching avoids the page-alignment
// false positives seen in the range-based scans (a .reloc PageRVA entry coincidentally
// landing inside a wide scan range).
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Symbol;

import java.util.LinkedHashMap;
import java.util.Map;

public class ThumperLocKeyXref extends GhidraScript {

    private static final Map<Long, String> TARGETS = new LinkedHashMap<>();
    static {
        TARGETS.put(0x1401cf4d8L, "option_quick_restart");
        TARGETS.put(0x1401ea438L, "level_select_unlocked");
        TARGETS.put(0x1401ea450L, "settings");
        TARGETS.put(0x1401ea6f0L, "main_menu");
        TARGETS.put(0x1401ea8d0L, "level_select");
        TARGETS.put(0x1401ea9a0L, "credits");
        TARGETS.put(0x1401eaa10L, "continue");
        TARGETS.put(0x1401eabd0L, "pause_restart_checkpoint");
        TARGETS.put(0x1401eac00L, "pause_resume");
        TARGETS.put(0x1401eac10L, "level_exit");
        TARGETS.put(0x1401eac20L, "option_exit");
        TARGETS.put(0x1401eac30L, "pause_restart");
        TARGETS.put(0x1401eac40L, "pause_quit");
        TARGETS.put(0x1401eaf68L, "level_select_start");
        TARGETS.put(0x1401eaf80L, "pause_restart_checkpoint_prompt");
        TARGETS.put(0x1401eafa0L, "level_select_restart");
        TARGETS.put(0x1401eb050L, "option_controls");
        TARGETS.put(0x1401eb200L, "option_audio");
        TARGETS.put(0x1401eb210L, "option_credits");
        TARGETS.put(0x1401eb220L, "option_video");
        TARGETS.put(0x1401eb230L, "option_gameplay");
        TARGETS.put(0x1401eb338L, "pause_restart_prompt");
        TARGETS.put(0x1401eb380L, "restart_checkpoint");
        TARGETS.put(0x1401eb398L, "pause_quit_prompt");
        TARGETS.put(0x1401eb418L, "exit_prompt");
        TARGETS.put(0x1401eb430L, "restart_checkpoint_previous");
    }

    @Override
    protected void run() throws Exception {
        Memory memory = currentProgram.getMemory();
        long imageBase = currentProgram.getImageBase().getOffset();

        println("=== Image base: 0x" + Long.toHexString(imageBase) + " ===");
        println("=== Scanning for pointers to " + TARGETS.size() + " known localization-key strings ===");

        long scanned = 0;
        long matches = 0;

        for (MemoryBlock block : memory.getBlocks()) {
            if (!block.isInitialized()) {
                continue;
            }
            println("Scanning block: " + block.getName() + "  " + block.getStart() + " - " + block.getEnd());

            Address end = block.getEnd();
            Address addr = block.getStart();

            while (addr != null && addr.compareTo(end) < 0) {
                if (monitor.isCancelled()) {
                    break;
                }

                scanned++;
                if (scanned % 2000000 == 0) {
                    println("... scanned " + scanned + " addresses so far (matches: " + matches + ")");
                }

                try {
                    long value8 = memory.getLong(addr);
                    String name = TARGETS.get(value8);
                    if (name != null) {
                        matches++;
                        report(addr, block, "absolute pointer", name, value8);
                    }
                } catch (Exception e) {
                    // Unreadable/out-of-bounds - skip.
                }

                try {
                    int value4 = memory.getInt(addr);
                    long asUnsigned = value4 & 0xFFFFFFFFL;
                    long asVa = asUnsigned + imageBase;
                    String name = TARGETS.get(asVa);
                    if (name != null) {
                        matches++;
                        report(addr, block, "4-byte RVA", name, asVa);
                    }
                } catch (Exception e) {
                    // Unreadable/out-of-bounds - skip.
                }

                addr = addr.add(1);
            }
        }

        println("=== Total scanned: " + scanned + "  Total matches: " + matches + " ===");
    }

    private void report(Address addr, MemoryBlock block, String kind, String targetName, long targetAddr) throws Exception {
        Function fn = getFunctionContaining(addr);
        Symbol sym = getSymbolAt(addr);
        String where;
        if (fn != null) {
            where = "in function " + fn.getName() + " @ " + fn.getEntryPoint();
        } else if (sym != null) {
            where = "at symbol " + sym.getName();
        } else {
            where = "no function/symbol";
        }
        println("---");
        println(kind + " at: " + addr + "  ->  \"" + targetName + "\" @ 0x" + Long.toHexString(targetAddr) +
            "  (block: " + block.getName() + ", " + where + ")");
    }
}
