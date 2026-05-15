# pgxntool Development Guidelines

Guidelines for contributors working on pgxntool itself. This file is loaded by
Claude Code when working in the pgxntool repository.

## Makefile Variable Assignment Rules

**RULE: Do not use `:=` (simply expanded) unless you have a specific need for immediate evaluation.**

Use `=` (recursively expanded) for standard variable assignments. Reserve `:=` for cases where the right-hand side must be evaluated exactly once at assignment time — for example, when assigning the result of a `$(call ...)` function that references the variable being set (which would cause infinite recursion with `=`).

When a variable must also override command-line values, combine `override` with `:=` — but only where `override` is genuinely needed.

## Debug Level Rules (lib.sh `debug` function)

The `debug` function in `lib.sh` uses a range-based numeric level scheme. The order of magnitude gives a rough sense of verbosity; room within each decade allows fine-tuning without renumbering.

- **1–9**: High-level script context — script arguments (1), top-level entry/exit (2–3), lower-level helper calls (4–5). Use sparingly.
- **10–19**: Per-loop-iteration detail — exit with status (10), entry (11), intermediate results (15).
- **20–29**: Nesting inside loop-level detail.
- Higher ranges follow the same pattern.

A non-trivial script with loops should have debug calls spanning multiple ranges.

The commit skill checks for unusual distributions (e.g., a script with loops that only uses single-digit levels).

Note: The BATS test helper `debug` function (in `test/lib/helpers.bash`) uses a separate 1–5 scale controlled by `$TESTDEBUG`. The two systems are independent.
