# Coder Server Setup – AI Agent Instructions

## Project

This repository contains the setup and maintenance automation for a
Coder server running on Debian 13.

The project manages:

- Docker
- Coder
- PostgreSQL
- Caddy
- Prometheus
- Grafana
- node-exporter
- UFW
- fail2ban
- unattended-upgrades
- backups
- update and reset procedures

## Critical rule

Never assume that a change is safe merely because it looks cleaner.

Infrastructure and security correctness take priority over code style.

## Security model

Treat Coder workspace users as untrusted.

Pay particular attention to:

- Docker socket access
- container-to-host isolation
- privilege escalation
- secrets
- SSH
- firewall rules
- publicly exposed ports
- TLS
- Caddy On-Demand TLS
- destructive operations

## Production safety

Never execute destructive operations against a production server.

Never:

- delete Docker volumes
- delete databases
- reset Coder
- modify SSH authentication
- modify firewall policy
- reboot a production server
- rotate production credentials

unless explicitly requested by the human operator.

## Secrets

Never commit:

- passwords
- API tokens
- private keys
- credentials
- .env files
- backup contents

Never print secrets unnecessarily.

## Change policy

Before changing infrastructure behavior:

1. Explain the current behavior.
2. Identify the problem.
3. Explain the proposed change.
4. Identify possible regressions.
5. Define a test.

Do not make unrelated changes.

## Idempotency

The setup must be safe to execute repeatedly.

Always consider:

- first run
- second run
- interrupted run
- partially completed run
- reboot
- failed package installation
- unavailable network
- existing configuration

## Backups

A successful backup file is not sufficient evidence of a successful backup.

Restore testing is required.

## Testing

Prefer:

- bash syntax checks
- ShellCheck
- Docker Compose validation
- configuration validation
- isolated VM testing
- idempotency testing
- backup restore testing

Never claim a test passed unless it was actually executed.

## Documentation

Keep comments synchronized with actual behavior.

If a comment claims that software behaves a certain way, verify the claim before relying on it.

## AI workflow

During the review phase:

- do not modify production configuration
- do not directly rewrite the original script
- distinguish facts from assumptions
- document uncertainty
- prefer official upstream documentation for software behavior

The original script is the baseline until an explicit implementation step is approved.