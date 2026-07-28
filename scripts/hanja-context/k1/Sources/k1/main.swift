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
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else {
    fail("usage: k1 <verify-contract|replicate|register-probe|build-donors> [--reference <path>]")
}

var referencePath: String?
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--reference":
        index += 1
        guard index < arguments.count else { fail("--reference needs a value") }
        referencePath = arguments[index]
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
default:
    fail("unknown mode: \(mode) (expected verify-contract|replicate|register-probe|build-donors)")
}
