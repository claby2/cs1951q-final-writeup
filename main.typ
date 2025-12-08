#align(center, text(17pt)[
  CSCI 1951Q Final Project: Contributing Changes to Wasmtime Cranelift
])

#align(center, text(13pt)[
  _Bisheshank C. Aryal, Edward Wibowo, James Hu_
])

#show link: underline

== Summary

#pagebreak()
== Introduction

Our final project involves introducing a missing optimization in #link("https://cranelift.dev")[Cranelift], a compiler backend used by #link("https://wasmtime.dev")[Wasmtime]. Wasmtime is a runtime for WebAssembly that leverages Cranelift to generate machine code either at runtime (via JIT) or ahead-of-time.

Cranelift produces optimized machine code from a custom interemediate representation (Cranelift IR). Here is an example of what this IR looks like in textual form:

```clif
function %non_icmp_inner(i64) -> i8 {
block0(v0: i64):
    v1 = iconst.i64 6
    v3 = iconst.i64 7
    v4 = select v0, v1, v3
    v5 = icmp eq v4, v1
    return v5
}
```

It is interesting to note that this textual form, known as CLIF, is primarily used for testing/debugging purposes. The actual IR used by Wasmtime is represented as an in-memory data structure. Cranelift's goal is to transform this IR into fast, architecture-dependent machine code. Doing so often requires IR-level mid-end optimization passes.

Cranelift uses its own DSL to express both lowering and optimization logic called ISLE (Instruction Selection Lowering Expressions). For this project specifically, we focused on mid-end optimizations, meaning producing expressions that take Cranelift IR and produces (optimized) Cranelift IR rather than machine code.

This project specifically aimed to create mid-end optimizations that were missing in Cranelift as pointed out by #link("https://github.com/bytecodealliance/wasmtime/issues/11578")[wasmtime/issues/#11578].
This issue points out a potential optimization involving `icmp`, `select`, and `brif` IR instructions.
Specifically, in the following CLIF code:

```clif
function %a(i64) -> i64 {
block0(v2: i64):
    v3 = band_imm v2, -562949953421310
    v4 = icmp_imm eq v3, 0
    v5 = iconst.i64 6
    v6 = iconst.i64 7
    v7 = select v4, v6, v5  ; v6 = 7, v5 = 6
    v8 = icmp_imm eq v7, 6
    brif v8, block2, block1

block1:
    v9 = iconst.i64 100
    jump block3(v9)

block2:
    v10 = iconst.i64 101
    jump block3(v10)

block3(v11: i64):
    return v11
}
```

One may observe that the value of `v8` is entirely dependent on the value of `v4`.
That is, the value of `v8` depends on whether `v7` is equal to `6`, and the value of `v7` is either equal to `v6 = 7` or `v5 = 6` depending on `v4`.
Crucially, since we know `v7` is constrained to either be equal to `6` or `7`, we can deduce that `v8` depends solely on `v4`.

Moreover, a further optimization may optimize away the branching if (`brif`) instruction by leveraging yet another `select` instead.
However, while we considered this approach, we chose to focus on the former optimization due to difficulties involving simplifying terminating instructions that may modify the control-flow graph.
Our attempts are discussed in the Implementation section [TODO: Make sure this is discussed].

#pagebreak()
== Implementation

#pagebreak()
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
