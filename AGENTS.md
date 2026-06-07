# AGENTS.md - Jido.Workspace

## Project Overview

Jido.Workspace provides a unified artifact workspace for agent sessions.
It uses `jido_shell` for workspace/session orchestration and `jido_vfs` for
filesystem adapter support.

## Core Responsibilities

- Mount and manage workspace filesystems through `Jido.Shell.VFS`
- Provide a simple artifact API (`write`, `read`, `list`, `mkdir`, `delete`)
- Support snapshot/restore of workspace artifacts
- Optionally run shell commands in a workspace-bound session

## Out of Scope

- Provider orchestration and adapter policy
- Harness runtime bootstrap/validation logic
- Sprite workflow orchestration scenarios

## Common Commands

- `mix test` - Run tests
- `mix quality` - Run all quality checks
- `mix coveralls` - Run tests with coverage

## Public API

- `Jido.Workspace.new/1` - Create and mount a workspace
- `Jido.Workspace.write/3` - Write artifact content
- `Jido.Workspace.read/2` - Read artifact content
- `Jido.Workspace.list/2` - List entries
- `Jido.Workspace.delete/2` - Delete artifact path
- `Jido.Workspace.mkdir/2` - Create directory
- `Jido.Workspace.snapshot/1` - Capture workspace snapshot
- `Jido.Workspace.restore/2` - Restore snapshot
- `Jido.Workspace.start_session/2` - Start shell session
- `Jido.Workspace.run/3` - Run shell command
- `Jido.Workspace.stop_session/1` - Stop shell session
- `Jido.Workspace.close/1` - Stop session and unmount workspace

## Architecture

- `Jido.Workspace` - Public API module
- `Jido.Workspace.Workspace` - Core workspace struct and operations
- `Jido.Workspace.Schemas` - Zoi validation schemas

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
