// Entry point / subcommand dispatch for the K1b Task 1 offline association-ranker harness.
//     Copyright (C) 2026 Seungjin Lee.
import Foundation

@main
struct AssocMain {
    static func main() async {
        let args = CommandLine.arguments
        let command = args.count > 1 ? args[1] : "help"

        await MainActor.run {
            do {
                switch command {
                case "eval-ctx":
                    try EvalCtx.run()
                case "eval5d":
                    try Eval5D.run()
                case "score-holdout":
                    guard args.count > 3 else {
                        print("usage: assoc score-holdout <input.tsv> <output.tsv> [--table=bin|txt]")
                        exit(1)
                    }
                    let useBinary = !(args.contains("--table=txt"))
                    try ScoreHoldout.run(inputPath: args[2], outputPath: args[3], useBinaryTable: useBinary)
                case "d2-verify":
                    guard args.count > 3 else {
                        print("usage: assoc d2-verify <mined-sentences.tsv> <out.tsv>")
                        exit(1)
                    }
                    try D2Verify.run(inputPath: args[2], outputPath: args[3])
                case "app-verify":
                    guard args.count > 3 else {
                        print("usage: assoc app-verify <mined-sentences.tsv> <out.jsonl>")
                        exit(1)
                    }
                    try AppVerify.run(inputPath: args[2], outputPath: args[3])
                case "app-preview-trace":
                    guard args.count > 3 else {
                        print("usage: assoc app-preview-trace <public-fixtures.tsv> <out.jsonl>")
                        exit(1)
                    }
                    try PreviewTrace.run(inputPath: args[2], outputPath: args[3])
                case "segmentation-compare":
                    guard args.count > 3 else {
                        print("usage: assoc segmentation-compare <mined-sentences.tsv> <out.jsonl>")
                        exit(1)
                    }
                    try SegmentationCompare.run(inputPath: args[2], outputPath: args[3])
                case "d3-features":
                    guard args.count > 3 else {
                        print("usage: assoc d3-features <seeds-dir> <out.tsv>")
                        exit(1)
                    }
                    try D3Features.run(seedsDir: args[2], outputPath: args[3])
                default:
                    print("usage: assoc <eval-ctx|eval5d|score-holdout|d2-verify|app-verify|app-preview-trace|segmentation-compare|d3-features> ...")
                }
            } catch {
                print("ERROR: \(error)")
                exit(1)
            }
        }
    }
}
