# AGENTS.md - Jido.Sandbox

## Project Overview

Jido Sandbox provides a lightweight, pure-BEAM sandbox for LLM tool calls. It implements an in-memory virtual filesystem (VFS) and sandboxed Lua execution.

## Key Constraints (Features, not bugs)

- **No real filesystem access** - All files are virtual
- **No networking** - No HTTP, sockets, or external connections
- **No shell/process execution** - No System.cmd, ports, or NIFs
- **Lua-only scripting** - Sandboxed Lua with VFS bindings only
- **All paths are virtual and absolute** - Must start with `/`

## Common Commands

- `mix test` - Run tests
- `mix quality` - Run all quality checks
- `mix coveralls` - Run tests with coverage

## Public API

- `Jido.Sandbox.new/1` - Create a new sandbox
- `Jido.Sandbox.write/3` - Write file to VFS
- `Jido.Sandbox.read/2` - Read file from VFS
- `Jido.Sandbox.list/2` - List directory contents
- `Jido.Sandbox.delete/2` - Delete file from VFS
- `Jido.Sandbox.mkdir/2` - Create directory
- `Jido.Sandbox.snapshot/1` - Save VFS state
- `Jido.Sandbox.restore/2` - Restore VFS state
- `Jido.Sandbox.eval_lua/2` - Execute Lua code

## Architecture

- `Jido.Sandbox` - Public API module
- `Jido.Sandbox.Sandbox` - Core sandbox struct and operations
- `Jido.Sandbox.VFS` - VFS behavior
- `Jido.Sandbox.VFS.InMemory` - In-memory VFS implementation
- `Jido.Sandbox.Lua.Runtime` - Sandboxed Lua execution
