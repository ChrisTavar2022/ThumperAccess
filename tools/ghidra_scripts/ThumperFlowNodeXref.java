// Headless Ghidra script: find what stores a POINTER into the flow-node event-name
// cluster (kLoadState*/kUIStart*/kUIController*/ui_select_start/ui_go_back_*, found by
// ThumperStringSearch.java, roughly 1401e8c78-1401e9f48). Every one of these strings
// showed "no references found" via Ghidra's normal getReferencesTo analysis, same
// symptom as the screen-name table (see session-2026-07-13-table-xref.md) - so this
// reuses the same raw byte-level scan technique instead of trusting the automatic xref
// pass: read every 8-byte (absolute pointer) and 4-byte (MSVC-style RVA) value across
// all initialized memory and check whether it falls inside the target region.
//
// This region also contains printf-style fallback strings ("Could not find UIStartEvent
// value %i") - the presence of that message strongly suggests an enum-to-string debug
// lookup function exists somewhere that takes an event id and returns/prints one of
// these names. Finding what references this table would very likely locate that lookup
// function, which is called whenever the game processes a flow-node event - a strong
// hook point for narrating menu navigation.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Symbol;

public class ThumperFlowNodeXref extends GhidraScript {

    // Flow-node event-name cluster: kLoadStateNumOuts (1401e8c78) through
    // ui_select_start (1401e9f38, 16 bytes incl. null terminator -> ~1401e9f48).
    // Narrower than the screen-name table scan to avoid picking up the *next*
    // cluster (localization/option keys starting ~1401ea408), which is a different
    // table.
    private static final long RANGE_START = 0x1401e8c78L;
    private static final long RANGE_END   = 0x1401e9f48L;

    @Override
    protected void run() throws Exception {
        Memory memory = currentProgram.getMemory();
        long imageBase = currentProgram.getImageBase().getOffset();
        long rvaRangeStart = RANGE_START - imageBase;
        long rvaRangeEnd = RANGE_END - imageBase;

        long matchCount8 = 0;
        long matchCount4 = 0;
        long scanned = 0;

        println("=== Image base: 0x" + Long.toHexString(imageBase) + " ===");
        println("=== Pass 1: scanning for absolute 8-byte pointers into 0x" +
            Long.toHexString(RANGE_START) + "-0x" + Long.toHexString(RANGE_END) + " ===");
        println("=== Pass 2: scanning for 4-byte RVAs into 0x" +
            Long.toHexString(rvaRangeStart) + "-0x" + Long.toHexString(rvaRangeEnd) + " (relative to image base) ===");

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
                    println("... scanned " + scanned + " addresses so far (8-byte matches: " + matchCount8 +
                        ", 4-byte RVA matches: " + matchCount4 + ")");
                }

                try {
                    long value8 = memory.getLong(addr);
                    if (value8 >= RANGE_START && value8 <= RANGE_END) {
                        matchCount8++;
                        report(addr, block, "absolute pointer", "0x" + Long.toHexString(value8));
                    }
                } catch (Exception e) {
                    // Unreadable/out-of-bounds at this offset - skip.
                }

                try {
                    int value4 = memory.getInt(addr);
                    long asUnsigned = value4 & 0xFFFFFFFFL;
                    if (asUnsigned >= rvaRangeStart && asUnsigned <= rvaRangeEnd) {
                        matchCount4++;
                        report(addr, block, "4-byte RVA", "0x" + Long.toHexString(asUnsigned) +
                            " (-> VA 0x" + Long.toHexString(asUnsigned + imageBase) + ")");
                    }
                } catch (Exception e) {
                    // Unreadable/out-of-bounds at this offset - skip.
                }

                addr = addr.add(1);
            }
        }

        println("=== Total scanned: " + scanned + "  8-byte matches: " + matchCount8 +
            "  4-byte RVA matches: " + matchCount4 + " ===");
    }

    private void report(Address addr, MemoryBlock block, String kind, String target) throws Exception {
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
        println(kind + " at: " + addr + "  ->  " + target + "  (block: " + block.getName() + ", " + where + ")");
    }
}
