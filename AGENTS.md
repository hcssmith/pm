# General Instructions

## Environment Constraints

This agent runs inside a container **without buila tools**. You must NOT attempt to:

- Install packages or dependencies without ensuring the go.mod file is updated, or any third party dependencies.
- Start dev servers or long-running processes

## What you CAN do

- Read, write, and edit source files
- Run lightweight shell commands (`ls`, `grep`, `find`, `git`, `cat`, etc.)
- Analyze code, write new code, refactor, and review
- Use `bash` for read-only inspection of the project
- In this container you do have access to the `go` command.
- Run tests that require compilation or a runtime build step

When a task would normally require building or installing dependencies, **skip that step** and explain what you would have done instead.
