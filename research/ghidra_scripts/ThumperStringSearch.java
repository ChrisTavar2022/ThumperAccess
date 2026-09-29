// Headless Ghidra script: search defined strings for likely menu-label text and
// report cross-references (who reads/uses each string) so we can locate menu
// construction / selection code. Run via analyzeHeadless -postScript.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.util.DefinedDataIterator;

import java.util.Arrays;
import java.util.List;

public class ThumperStringSearch extends GhidraScript {

    @Override
    protected void run() throws Exception {
        List<String> keywords = Arrays.asList(
            "PLAY", "OPTIONS", "EXIT", "QUIT", "LEVEL", "AUDIO", "VIDEO",
            "CONTROLS", "RESUME", "SAVE", "LOAD", "CONTINUE", "SETTINGS",
            "CREDITS", "NEW GAME", "BACK", "START", "MENU", "GRAPHICS",
            "DIFFICULTY", "CALIBRATE", "EXTRAS", "CHAPTER"
        );

        println("=== Menu-label string search ===");
        int matchCount = 0;
        for (Data data : DefinedDataIterator.byDataInstance(currentProgram, Data::hasStringValue)) {
            if (monitor.isCancelled()) break;

            String value;
            try {
                Object val = data.getValue();
                if (val == null) continue;
                value = val.toString();
            } catch (Exception e) {
                continue;
            }
            String upper = value.toUpperCase().trim();
            if (upper.isEmpty()) continue;

            boolean match = false;
            for (String kw : keywords) {
                if (upper.equals(kw) || upper.contains(kw)) {
                    match = true;
                    break;
                }
            }
            if (!match) continue;

            matchCount++;
            Address addr = data.getAddress();
            println("---");
            println("Address: " + addr + "  String: \"" + value + "\"");

            ReferenceIterator refIter = currentProgram.getReferenceManager().getReferencesTo(addr);
            int refCount = 0;
            while (refIter.hasNext() && refCount < 10) {
                Reference ref = refIter.next();
                Address fromAddr = ref.getFromAddress();
                Function fn = getFunctionContaining(fromAddr);
                String fnName = (fn != null) ? fn.getName() + " @ " + fn.getEntryPoint() : "(no function)";
                println("  xref from: " + fromAddr + "  in function: " + fnName);
                refCount++;
            }
            if (refCount == 0) {
                println("  (no references found)");
            }
        }
        println("=== Total matches: " + matchCount + " ===");
    }
}
