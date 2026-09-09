# Contributing

## Before you open a pull request

**Keep it read-only.** Every tool must be a `SELECT` or a `READ REPORT`. The
absence of a write path is the design; a PR that adds one will not be merged.

**NetWeaver 7.02 syntax only.** This project exists because 7.02 systems are
excluded from everything else, so it must actually compile there:

- no inline `DATA( )`
- no `VALUE #( )`, `NEW`, `CORRESPONDING #( )`
- no string templates `|{ }|`
- no `CONV`, `REDUCE`, `FILTER`
- no `LINE_EXISTS`, no table expressions `itab[ ]`

`IMPORTING` parameters typed against DDIC pass by reference, so lengths must
match exactly — route through a correctly typed local rather than assigning a
`STRING` into a `CHAR255`.

**State what you tested on.** Include the release and kernel. The release
matrix here is thin and that information is worth more than the code.

## What is most useful

1. **Testing on other releases.** 7.01, 7.31, 7.40 — does it activate, do the
   tools return sensible results.
2. **`SNAP` field verification.** The columns available for ST22 reading vary
   by release and nobody has mapped this properly.
3. **`CROSS-TYPE` codes.** F, P, R, T, U and K are mapped. Others fall through
   as a bare letter.
4. **Additional read-only tools.** Transport contents, object history, package
   trees — all deterministic, all useful.

## What is out of scope

- Write, activation, locking, transport operations
- Anything requiring ADT — that defeats the purpose
- Dependencies beyond ajson
