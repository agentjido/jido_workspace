# Contributing to Jido Workspace

Thank you for your interest in contributing to Jido Workspace!

## Development Setup

1. Clone the repository
2. Run `mix setup` to install dependencies and git hooks
3. Run `mix test` to verify everything works

## Quality Standards

Before submitting a PR, ensure:

- `mix quality` passes (format, compile warnings, strict Credo, Dialyzer, and Doctor).
- `mix test.coverage` reports at least 90% coverage.
- All tests pass

`mix test` runs the unit tests. `mix test.integration` runs each integration
example in a separate BEAM instance. `mix test.coverage` preserves this separation
and combines the example coverage with the unit test coverage. The report is
`cover/excoveralls.json`. Each run removes the old example coverage data first.

Coverage from services that run in a separate BEAM instance is not collected by
the controller report. Tests that require unavailable services remain skipped.
Read the test counts and exclusions with the coverage result.

Use a matching Elixir and OTP build for Dialyzer. The shared CI quality job uses
Elixir 1.20 and OTP 29. A build compiled for a different OTP version can cause
errors when Dialyzer reads protocol debug data.

## Commit Messages

We use conventional commits:

- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `test:` - Test changes
- `chore:` - Maintenance tasks

## Code Style

- Follow standard Elixir conventions
- Keep functions small and focused
- Add typespecs to public functions
- Document public modules and functions
