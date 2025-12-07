#align(center, text(17pt)[
  CSCI 1951Q Final Project: Contributing Changes to Wasmtime Cranelift
])

#align(center, text(13pt)[
  _Bisheshank C. Aryal, Edward Wibowo, James Hu_
])

== Summary

== Introduction

== Implementation

== Evaluation

We implemented four ISLE rewrite rules that optimize a specific IR pattern in Cranelift: when a `select` instruction with constant operands is immediately compared against one of those constants. The optimization eliminates the intermediate select and comparison, directly using the select's condition.

Our concrete claims are:
- Reduces IR instruction count for the targeted pattern
- Maintains semantic correctness across all variants (equality/inequality, different constant orderings)
- Integrates without breaking existing optimizations

What we do not claim is that this makes real programs faster. We have no data on how often this pattern occurs in practice or whether the optimization provides measurable performance benefits.

=== Test Results and Validation

We wrote comprehensive tests with two key insights:

1. *Semantic testing was critical*: FileCheck tests only verify IR transformations, but semantic tests (`test run`) caught logical errors in the boolean algebra. For example:
   ```clif
   ; select(false, 6, 7) = 7, icmp(7, 6) = false
   ; Our rule: eq(select(cond, k1, k2), k1) -> ne(cond, 0)
   ; Verification: ne(false, 0) = false
   ```

2. *Boundary condition discovery*: The `%non_icmp_inner` test revealed our optimization works beyond the original motivating case---it handles any boolean condition, not just `icmp` results. This was accidental but valuable.

*Edge Case Handling*

The guard condition `(if-let false (u64_eq k1 k2))` correctly prevents optimization when both constants are identical, allowing constant propagation to handle `select(cond, k, k)` -> `k`.

=== What The Numbers Mean (And Don't Mean)

*IR Instruction Count Results:*
- Pattern occurrence: 5 instructions -> 1 instruction (5:1 reduction)
- Test coverage: 100% of target patterns optimized
- False positives: 0% (no incorrect transformations)

*Why instruction count is a limited metric:* Modern CPUs are complex. Out-of-order execution, register renaming, and aggressive speculation may already hide the inefficiencies we're targeting. Additionally, `select` instructions have varying costs across architectures being cheap on some, expensive on others.

*Missing critical data:*
- How often does this pattern appear in real code?
- What's the actual runtime performance impact?
- Does the optimization increase compile time noticeably?

=== Honest Assessment of Impact

*Engineering value:* The implementation demonstrates good compiler engineering practices. Minimal code (30 lines), leverages existing infrastructure effectively, comprehensive testing methodology.

*Real-world impact:* Unknown. Without frequency analysis on real codebases or performance benchmarks, we can't quantify whether this optimization matters. It might be optimizing a rare pattern, or modern hardware might already mask the inefficiency.

*Most valuable contribution:* The testing methodology insights may be more valuable than the optimization itself. The discovery that semantic testing + boundary condition testing + optimization interaction testing are all necessary provides a template for future compiler optimization work.

*Reproducibility details:*
- Cranelift commit: 32f12567f5aeb79ec733b9dc9d8f732a5872c73a
- File location: `cranelift/codegen/src/opts/icmp.isle:379-412`
