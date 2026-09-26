# Repository-wide Copilot Instructions

This repository contains production-oriented infrastructure automation
for a Coder server on Debian 13.

## General

Prioritize:

1. Security
2. Correctness
3. Reliability
4. Idempotency
5. Recoverability
6. Testability
7. Maintainability
8. Performance

Do not optimize for brevity or elegance at the expense of operational safety.

## Bash

For shell code:

- assume Bash, not generic sh
- preserve safe quoting
- consider `set -Eeuo pipefail`
- check exit-code behavior carefully
- avoid accidental word splitting
- avoid unsafe command construction
- consider partial failures
- consider repeated execution
- consider interrupted execution
- prefer explicit error handling over implicit behavior

## Infrastructure

Every change must be evaluated for:

- privilege requirements
- network exposure
- filesystem permissions
- service lifecycle
- reboot behavior
- Docker behavior
- IPv4/IPv6 behavior
- failure recovery
- rollback

## Security

Treat workspace users as untrusted.

Pay special attention to:

- Docker socket access
- Docker privilege boundaries
- sudo
- SSH
- UFW
- fail2ban
- TLS
- secrets
- container escape
- destructive commands

## Review behavior

When asked to review code:

- do not immediately rewrite it
- first identify findings
- provide evidence
- distinguish confirmed problems from assumptions
- assign severity
- propose tests

## Implementation behavior

When implementing an approved plan:

- implement only planned changes
- avoid unrelated refactoring
- do not silently change application behavior
- run appropriate static checks
- report tests honestly
- show the final diff

## Production

Never execute commands against a production server as part of code analysis.

Use isolated test environments instead.