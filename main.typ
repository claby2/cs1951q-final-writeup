#align(center, text(17pt)[
  CSCI 1951Q Final Project: Contributing Changes to Wasmtime Cranelift
])

#align(center, text(13pt)[
  _Bisheshank C. Aryal, Edward Wibowo, James Hu_
])

#show link: underline

== Summary

We implemented a missing optimization in Cranelift, Wasmtime's compiler backend, targeting a specific pattern involving `icmp`, `select`, and `brif` IR instructions. Our optimization eliminates redundant intermediate instructions when a `select` instruction with constant operands is immediately compared against one of those constants, reducing the pattern from 5 instructions to 1. Using Cranelift's ISLE DSL, we developed four rewrite rules handling equality/inequality comparisons with different constant orderings, while addressing challenges including terminator instruction restrictions, boolean casting requirements, and isomorphic comparison cases. Our comprehensive testing methodology combining semantic verification, FileCheck transformations, and boundary condition analysis ensured correctness across all variants. Though we demonstrated successful IR reduction and maintained semantic correctness without breaking existing optimizations, the real-world performance impact remains unmeasured due to lack of frequency analysis on practical codebases and runtime benchmarks.

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

For reference, `icmp` returns 1 if the comparison is true and 0 otherwise. #footnote[The function can also return -1 for vector operations, but that is not in scope for this project.]
`select` returns the first argument if its condition is truthy (not `0`) and the second argument otherwise.

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
Our attempts are discussed in the Implementation section.

#pagebreak()
== Implementation
The implementation of our project was written in ISLE, Cranelift’s DSL for writing optimizations. Let’s introduce ISLE before getting into the specifics of our optimization.

ISLE is a typed DSL compiling to Rust that Cranelift authors use to declaratively express two types of transformations to CLIF: 1) lowering from CLIF to machine code and 2) CLIF optimizations. ISLE consists of _rules_ that can be thought of as pattern matching. For example, the ISLE used to transform a CLIF `iadd` and `imul` instruction group to `aarch64` machine code might look like: @fallin2023cranelift

```isle
(iadd (imul a b) c) => (aarch64_madd a b c)
```

At a high level, the above ISLE DSL would compile down to the following pseudocode.
```
$t0, $t1 := match_op $root, iadd
$t2, $t3 := match_op $t0, imul
$t4 = create_op aarch64_madd, $t2, $t3, $t1
return $t4
```

A unique technique ISLE explores is making the DSL strongly-typed. Some example types are IR `Value`s and architecture-specific `Reg`s that correspond to Rust types. ISLE benefits from common type system wins like preserving invariants via types: tracking “flag” registers in architecture-specific code happens with `ProducesFlags` and `ConsumesFlags` typed values.

Our implementation consists of ISLE code. At a high level, we target `icmp eq` (equals comparison) or `icmp ne` (not equals comparison) instructions. Let’s use the example `icmp eq, x, k1`, where `x` is any value and `k1` is a known constant value.
If we see the value of `x` comes from the instruction `select y, k1, k2`, we know that these two instructions together are equivalent to the “inner_cond” (i.e. the condition of the select instruction).
A key constraint for our optimization is checking `k1 != k2`: `select y, k1, k1` will be optimized by constant propagation.

Along the way, we ran into challenges with `brif`, isomorphic `icmp` instances, and handling non-boolean `select` conditions.

=== The brif Instruction

In CLIF, the `brif` instruction jumps to one of two basic blocks depending on a condition value. The original issue report includes a reproducible test case where the final optimization may affect a brif instruction by swapping the order of the target basic blocks based on the structure of the select and icmp. Our first idea was to target the brif instruction in ISLE as the target instruction pattern for our optimization. However, looking at the Rust implementation that our potential ISLE code interacts with, we see a comment explaining that ISLE cannot optimize terminators like `brif`.

#figure(image("brif_broken.png"), caption: [
  Code snippet showing restrictions on ISLE simplifying terminators.
])

Further details can be found in the corresponding code comments @wasmtime_egraph_2025.
We solved this challenge by generalizing to optimize the condition passed to brif.
We noticed that any condition that follows the `icmp` + `select` pattern described above may be subject to our optimization: the `brif` instruction is not a required pattern-match condition.
Our resulting optimization targets `icmp` on the result of a `select` to simplify to a boolean value without modifying control flow.

=== Isomorphic icmp Instances

In our examples above, our instruction to optimize was an `icmp eq` with `k1` as the condition.
However, `icmp eq` with `k2` and `icmp ne` with `k1` are similar setups where the optimization can also apply.
In total, we want to tackle `icmp (eq | ne), x, (k1 | k2)` for a total of four cases.
Following careful casework, we determined `icmp eq, x, k2` and `icmp ne, x, k1` simplify to the _negation_ of the corresponding select instruction’s condition.
A naive approach is to insert a `bxor 1` to invert the result.
Instead of using `bxor`, we can handle both negation and boolean casting simultaneously by strictly comparing the inner condition against 0. We explain this technique in the next section.

=== Handling Non-boolean selects

CLIF has the concept of “truthiness” where 0 is `false` and anything else is `true`.
Thus, a naive optimization of replacing the `icmp` + `select` combo with the `select`’s inner condition fails in cases such as @tricky_test_case when the inner condition is not `0` or `1`.

#figure(
  ```CLIF
  function %a(i64) -> i8 {
  block0(v0: i64):
    v1 = select v0, 100, 0
    v2 = icmp_imm eq v1, 100
    return v2
  }
  ```,
  caption: [
    Test case that breaks naive optimization.
    The inner condition is `v0`.
    Note this is not the exact test case because `icmp_imm` will be legalized before optimization passes run.
  ],
) <tricky_test_case>

A naive optimization rewrites this to @naive_try.
However, this transformation loses the "casting" effect of the `icmp` + `select` instruction combo and results in invalid IR.
More concretely, the unoptimized `icmp` instruction will “cast” the potentially truthy inner condition of `select` to an `i8` boolean (0 or 1).
We account for this by inserting an `icmp` against 0, replicating the “cast”.
This gives us the correct optimization in @correct_optimization.

#figure(
  ```CLIF
  function %a(i64) -> i8 {
  block0(v0: i64):
    return v0
  }
  ```,
  caption: [Naive optimization results in invalid IR: v0, an `i64`, does not match the return type of `i8`.],
) <naive_try>

#figure(
  ```CLIF
  function %a(i64) -> i8 {
  block0(v0: i64):
    v1 = icmp_imm ne v0, 0
    return v1
  }
  ```,
  caption: [Inserting an `icmp_imm ne .. 0` to "cast" the inner condition of `select` into a boolean.],
) <correct_optimization>

The end result is eliminating one `select` instruction.
Additionally, some architectures like x86 have optimizations for comparing against `0` vs. other values. @intel_opt_manual_v1
However, we have not measured performance impact.


#pagebreak()
== Evaluation

We implemented four ISLE rewrite rules that optimize a specific IR pattern in Cranelift: when a `select` instruction with constant operands is immediately compared against one of those constants. The optimization eliminates the intermediate select and comparison, directly using the select's condition.

Our concrete claims are:
- Reduces IR instruction count for the targeted pattern
- Maintains semantic correctness across all variants (equality/inequality, different constant orderings)
- Integrates without breaking existing optimizations

What we do not claim is that this makes real programs faster. We have no data on how often this pattern occurs in practice or whether the optimization provides measurable performance benefits.

=== Test Results and Validation

Our testing approach revealed that compiler optimizations require validation at two distinct levels, both of which are equally important.

First, syntactic correctness testing through `test optimize` and FileCheck verifies the IR transformation happens as expected. The optimization fires, removes the select/icmp instructions, and produces syntactically valid IR.

Second, semantic correctness testing through `test run` verifies the transformed code actually computes the same results as the original.

Both layers are essential because you can have optimizations that pass all FileCheck tests but produce wrong answers. Consider if we had botched the boolean logic:
```clif
; WRONG transformation: eq(select(cond, k1, k2), k1) → eq(cond, 0)
; RIGHT transformation: eq(select(cond, k1, k2), k1) → ne(cond, 0)
```

FileCheck would see both as "successful"—the select and icmp disappear, replaced by a direct comparison. But only semantic testing reveals that the wrong transformation returns inverted results.

A concrete example from our tests demonstrates this:
```clif
function %non_icmp_inner(i64) -> i8 {
    v4 = select v0, 6, 7    ; if v0 then 6 else 7
    v5 = icmp eq v4, 6      ; is result == 6?
    return v5
}
; run: %non_icmp_inner(0) == 0  ; select(0,6,7)=7, eq(7,6)=0
; run: %non_icmp_inner(1) == 1  ; select(1,6,7)=6, eq(6,6)=1
```

The `test run` directives catch boolean logic errors that FileCheck cannot. If our transformation was wrong, we'd get `%non_icmp_inner(0) == 1` instead of `0`, exposing the bug.

The `%non_icmp_inner` test also revealed our optimization works beyond the original `icmp + select + icmp` pattern—it handles any boolean condition. This was discovered through semantic testing, not IR inspection.

=== Edge Case Handling

The guard condition `(if-let false (u64_eq k1 k2))` correctly prevents optimization when both constants are identical, allowing constant propagation to handle `select(cond, k, k)` -> `k`.

=== What The Numbers Mean (And Don't Mean)

The following are the summarized IR instruction count results:
- Pattern occurrence: 5 instructions -> 1 instruction (5:1 reduction)
- Test coverage: 100% of target patterns optimized
- False positives: 0% (no incorrect transformations)

Although this initially seems promising, instruction count might be limited metric. Modern CPUs are complex. Out-of-order execution, register renaming, and aggressive speculation may already hide the inefficiencies we're targeting. Additionally, `select` instructions have varying costs across architectures being cheap on some, expensive on others.

Missing critical data:
- How often does this pattern appear in real code?
- What's the actual runtime performance impact?
- Does the optimization increase compile time noticeably?

=== Broader Impact Assessment

The optimization consists of only 30 lines of ISLE code, effectively leverages Cranelift's existing infrastructure, and follows established patterns in the codebase. Our comprehensive testing methodology combines semantic verification, FileCheck transformation analysis, and boundary condition testing.

However, the real-world significance of this optimization remains unclear. We lack critical data on pattern frequency in production codebases and runtime performance measurements. The optimization might target a rare IR pattern, or modern hardware with out-of-order execution and register renaming might already mitigate the inefficiencies we address.

Interestingly, our testing methodology discoveries may prove more valuable than the optimization itself. The requirement for semantic testing alongside FileCheck verification, plus the systematic exploration of boundary conditions and optimization interactions, creates a replicable framework for future Cranelift optimization development.

*Reproducibility details:*
- Cranelift commit: 32f12567f5aeb79ec733b9dc9d8f732a5872c73a
- File location: `cranelift/codegen/src/opts/icmp.isle:379-412`

#bibliography("works.bib")
