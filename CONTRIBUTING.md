# Contributing

The most useful contribution is a correction to a stack you run in production: a setting the docs recommend that we missed, a driver option, an idiom that is cheaper and that real projects use.

## What gets accepted
- **Production-realistic.** The change is something a production deployment of that stack would do, ideally with a link to the project's documentation. Benchmark-only tricks (disabling validation, hand-written serialisers in a framework stack, unsafe pooling) are not.
- **Same rules for everyone.** Database access follows the statement rule in [docs/rules.md](docs/rules.md); process and pool sizes follow the same formulas; the API and its responses do not change.
- **Responses stay identical.** `harness/verify-all.sh` must print `ok` for the stack on both databases.

## How
1. Open an issue describing the change and why (a link to docs or a production config helps), or a pull request against the implementation under `implementations/`.
2. The stack is re-measured on the same machine with the same harness; results and the change are recorded in the next results folder.

Implementations live in `implementations/<language>` (see its README); the stack configuration is in `harness/stack/up.sh`.
