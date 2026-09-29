// Headless Ghidra script: test the theory from session-2026-07-13-flownode-lockey-xref.md
// that the reason getReferencesTo() found 0 xrefs for every interesting string (screen
// names, flow-node event names, real localization keys) is that the code touching them
// was never disassembled by the initial default auto-analysis (plausible for code only
// reached via indirect/virtual dispatch rather than direct calls).
//
// This enables any analyzer option with "aggressive" in its name (notably "Aggressive
// Instruction Finder", which scans undefined bytes in executable memory for byte
// patterns that look like valid code even without an incoming call/jump reference) and
// re-runs analysis in-memory (process is started with -readOnly, so nothing is persisted
// to the project - this is a one-shot experiment), then re-checks proper Ghidra xrefs
// (not a raw byte scan this time) for every string address collected across all three
// prior sessions.
import ghidra.app.script.GhidraScript;
import ghidra.framework.options.Options;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Program;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

import java.util.LinkedHashMap;
import java.util.Map;

public class ThumperAggressiveAnalysis extends GhidraScript {

    private static final Map<Long, String> TARGETS = new LinkedHashMap<>();
    static {
        // Screen-name table (session-2026-07-13-string-search.md / table-xref.md)
        TARGETS.put(0x1401eb718L, "AutoLoadScreen");
        TARGETS.put(0x1401eb728L, "CreditsScreen");
        TARGETS.put(0x1401eb7b8L, "OptionsScreen");
        TARGETS.put(0x1401eb7d8L, "LevelSelectScreen");
        TARGETS.put(0x1401eb7f0L, "MainMenuScreen");
        TARGETS.put(0x1401eb810L, "LoadingScreen");
        TARGETS.put(0x1401eb830L, "TitleBackground");
        TARGETS.put(0x1401eb840L, "UILoadingScreen");
        // Flow-node event-name cluster
        TARGETS.put(0x1401e8c78L, "kLoadStateNumOuts");
        TARGETS.put(0x1401e8c90L, "kLoadStatePreUIState");
        TARGETS.put(0x1401e8cd0L, "kLoadStateOut");
        TARGETS.put(0x1401e8ce0L, "kLoadStateStartLoad");
        TARGETS.put(0x1401e8d20L, "kLoadStateUIState");
        TARGETS.put(0x1401e8d38L, "kLoadStateWorldState");
        TARGETS.put(0x1401e8e08L, "kUIControllerShowOptions");
        TARGETS.put(0x1401e8e58L, "kUIControllerStart");
        TARGETS.put(0x1401e8eb8L, "kUIControllerExit");
        TARGETS.put(0x1401e9160L, "kUIStartPrevious");
        TARGETS.put(0x1401e9178L, "kUIStartCurrent");
        TARGETS.put(0x1401e91d8L, "kUIStartIn");
        TARGETS.put(0x1401e9210L, "kUIStartStarted");
        TARGETS.put(0x1401e9220L, "kUIStartNumOuts");
        TARGETS.put(0x1401e9ee0L, "ui_go_back_end");
        TARGETS.put(0x1401e9ef0L, "ui_go_back_start");
        TARGETS.put(0x1401e9f38L, "ui_select_start");
        // Real, runtime-used localization keys
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
        Program program = currentProgram;
        Options analysisOptions = program.getOptions(Program.ANALYSIS_PROPERTIES);

        println("=== Analyzer options containing 'aggressive' (before) ===");
        int enabledCount = 0;
        int txId = program.startTransaction("Enable aggressive analyzers");
        boolean success = false;
        try {
            for (String name : analysisOptions.getOptionNames()) {
                if (name.toLowerCase().contains("aggressive")) {
                    Object before = analysisOptions.getObject(name, null);
                    println("  " + name + " = " + before);
                    analysisOptions.setBoolean(name, true);
                    enabledCount++;
                    println("  -> forced true");
                }
            }
            success = true;
        } finally {
            program.endTransaction(txId, success);
        }
        println("=== Enabled " + enabledCount + " aggressive-related analyzer option(s) ===");

        println("=== Re-running analysis (in-memory only, -readOnly so nothing is saved) ===");
        long startMs = System.currentTimeMillis();
        analyzeAll(program);
        long elapsedMs = System.currentTimeMillis() - startMs;
        println("=== Analysis complete in " + elapsedMs + " ms ===");

        println("=== Re-checking references for " + TARGETS.size() + " known strings ===");
        int foundCount = 0;
        for (Map.Entry<Long, String> entry : TARGETS.entrySet()) {
            Address addr = toAddr(entry.getKey());
            String label = entry.getValue();

            ReferenceIterator refIter = program.getReferenceManager().getReferencesTo(addr);
            int refCount = 0;
            while (refIter.hasNext() && refCount < 10) {
                Reference ref = refIter.next();
                Address fromAddr = ref.getFromAddress();
                Function fn = getFunctionContaining(fromAddr);
                String fnName = (fn != null) ? fn.getName() + " @ " + fn.getEntryPoint() : "(no function)";
                if (refCount == 0) {
                    println("---");
                    println("\"" + label + "\" @ " + addr + " now has reference(s):");
                    foundCount++;
                }
                println("  xref from: " + fromAddr + "  in function: " + fnName);
                refCount++;
            }
        }
        println("=== Strings with at least one reference after re-analysis: " + foundCount +
            " / " + TARGETS.size() + " ===");
    }
}
