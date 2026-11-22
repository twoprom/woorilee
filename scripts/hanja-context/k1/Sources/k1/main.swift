// K1a offline Kiwi LM alias-registration runner.
// docs/plans/hanja-context-scaling-plan.md §12 K1a — Part 1: offline runner + replication gate.
//
// Talks to the raw CKiwi C API directly (does NOT depend on the `Kiwi` Swift package — see
// Package.swift). Subcommands:
//   verify-contract [--reference <path>]
//       Proves the morpheme-space contract (match/build options, topN=1, content tags, form/TAG
//       feature key) matches scripts/hanja-context/collector's `enum Contract` byte-for-byte on
//       the same sentences. Must be 0 diffs before replicate/register-probe results are trusted.
//   replicate
//       Reproduces the pre-registered 2026-07-25 measurements in
//       docs/hanja-context-quality-scaling-research.md §3.6 (수도<-상수도 context gap,
//       statistics-borrowing via 쑤도, warm-up build time, topN=1 latency). Stop-or-go gate.
//   register-probe
//       Multi-sense ceiling, donor failure modes, and POS-tag-effect probe for Part 2.
//   build-donors
//       Part 2 (K1a-2/K1a-3): builds the donor inventory from sources (a) anchor, (b) NIKL
//       discriminative simple word, (c) association-table top feature; registers every donor for
//       real; writes donors.tsv / donor-failures.tsv / k1a-coverage.md.
//   k1b [--cap <N>] [--topn <N>] [--throughput-only]
//       K1b Part 1 (docs/plans/hanja-context-scaling-plan.md §12 K1b): non-transductive per-donor
//       baseline from an independent wiki sample + coverage-bracket narrowing. Reads the
//       coordinator-built measure/{fit,holdout}.tsv (does not rebuild it). --throughput-only runs
//       just the small-slice timing probe and exits, no full run.
//   k1b-diagnose [--baseline-stats <path>] [--topn <N>]
//       gold_surfaced diagnostic decomposition (RunK1bDiagnose.swift) — reuses a PREVIOUSLY-WRITTEN
//       baseline-stats.tsv (default: k1/baseline-stats.tsv) instead of re-scanning the corpus, and
//       only re-scores holdout + the 258-row eval set with an added gold_surfaced field. Writes
//       diagnose-holdout-scored.tsv / diagnose-eval258-scored.tsv / k1b-gold-surfaced-diagnosis.md.
//   k1b-sweep [--baseline-stats <path>] [--cap <N>]
//       topN sweep (30/100/300) on a candidate-count-stratified holdout slice + definitional-subset
//       split (RunK1bSweep.swift). Reuses cached baseline-stats.tsv. --cap sets rows/bucket for the
//       stratified slice (default 700). Writes k1b-sweep-report.md / definitional-handcheck-sample.tsv.
//   k1b-matched [--baseline-stats <path>] [--occurrences <path>] [--cap <N>] [--occurrence-cap <N>]
//       Decisive matched-topN=300 test (re-estimates baselines at topN=300 for the slice's own
//       readings from cached baseline-occurrences.tsv, cap ~10-15/reading) + 31-reading
//       eval-composition subset (RunK1bMatched.swift). Writes k1b-matched-report.md.
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else {
    fail("usage: k1 <verify-contract|replicate|register-probe|build-donors|k1b> [--reference <path>] [--cap <N>] [--topn <N>] [--throughput-only]")
}

var referencePath: String?
var k1bOptions = K1bOptions()
var baselineStatsPath: String?
var occurrencesPath: String?
var occurrenceCapPerReading = 15
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--reference":
        index += 1
        guard index < arguments.count else { fail("--reference needs a value") }
        referencePath = arguments[index]
    case "--cap":
        index += 1
        guard index < arguments.count, let n = Int(arguments[index]) else { fail("--cap needs an integer value") }
        k1bOptions.capPerReading = n
        k1bOptions.sweepCapPerBucket = n
    case "--topn":
        index += 1
        guard index < arguments.count, let n = Int32(arguments[index]) else { fail("--topn needs an integer value") }
        k1bOptions.topN = n
    case "--throughput-only":
        k1bOptions.throughputOnly = true
    case "--baseline-stats":
        index += 1
        guard index < arguments.count else { fail("--baseline-stats needs a path") }
        baselineStatsPath = arguments[index]
    case "--occurrences":
        index += 1
        guard index < arguments.count else { fail("--occurrences needs a path") }
        occurrencesPath = arguments[index]
    case "--occurrence-cap":
        index += 1
        guard index < arguments.count, let n = Int(arguments[index]) else { fail("--occurrence-cap needs an integer value") }
        occurrenceCapPerReading = n
    default:
        fail("unknown argument: \(arguments[index])")
    }
    index += 1
}

switch mode {
case "verify-contract":
    try runVerifyContract(referencePath: referencePath)
case "replicate":
    try runReplicate()
case "register-probe":
    try runRegisterProbe()
case "build-donors":
    try runBuildDonors()
case "k1b":
    try runK1b(k1bOptions)
case "k1b-diagnose":
    let path = baselineStatsPath ?? Paths.outDir.appendingPathComponent("baseline-stats.tsv").path
    try runK1bDiagnose(baselineStatsPath: path, topN: k1bOptions.topN)
case "k1b-sweep":
    let path = baselineStatsPath ?? Paths.outDir.appendingPathComponent("baseline-stats.tsv").path
    try runK1bSweep(baselineStatsPath: path, capPerBucket: k1bOptions.sweepCapPerBucket, probeSize: 150)
case "k1b-matched":
    let path = baselineStatsPath ?? Paths.outDir.appendingPathComponent("baseline-stats.tsv").path
    let occPath = occurrencesPath ?? Paths.outDir.appendingPathComponent("baseline-occurrences.tsv").path
    try runK1bMatched(baselineStatsPath: path, occurrencesPath: occPath, capPerBucket: k1bOptions.sweepCapPerBucket, occurrenceCapPerReading: occurrenceCapPerReading)
default:
    fail("unknown mode: \(mode) (expected verify-contract|replicate|register-probe|build-donors|k1b|k1b-diagnose|k1b-sweep|k1b-matched)")
}
