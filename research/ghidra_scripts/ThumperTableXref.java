// Headless Ghidra script: find what stores a POINTER into the screen-name table
// region (1401eb718-1401eb840, found by ThumperStringSearch.java). Ghidra's normal
// "who references this address" analysis (getReferencesTo) found 0 xrefs to these
// entries - likely because code computes "table_base + index*stride" in a register
// rather than embedding each entry's address directly in an instruction, which the
// automatic Reference analyzer does not always resolve.
//
// Instead of relying on instruction-operand xrefs, this does a raw byte-level scan:
// read every 8-byte (64-bit pointer-sized) value across all initialized memory and
// check whether it falls inside the table region. Any hit is either the table base
// address stored in code/data (the screen factory/registry we're looking for), or a
// pointer to one specific entry.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Symbol;

public class ThumperTableXref extends GhidraScript {

    // Screen-name table region found in session-2026-07-13-string-search.md, widened
    // a bit on both sides to also catch a table-base/header pointer sitting just
    // before the first entry (AutoLoadScreen @ 1401eb718), not just per-entry pointers.
    private static final long RANGE_START = 0x1401eb6d8L;
    private static final long RANGE_END   = 0x1401eb860L;

    @Override
    protected void run() throws Exception {
        Memory memory = currentProgram.getMemory();
        long imageBase = currentProgram.getImageBase().getOffset();
        // MSVC x64 often stores RTTI/table entries as 32-bit offsets relative to the
        // module base (RVA) instead of absolute 64-bit pointers, so the table region
        // has an RVA-space equivalent worth checking too.
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
