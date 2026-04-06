# Security Policy

## Supported Scope

Security issues are especially relevant for:

- API key handling
- TLS configuration
- exposed service ports
- container runtime configuration
- deployment scripts
- monitoring and log collection

## Reporting A Vulnerability

Please do not open public issues for sensitive security problems.

Instead, report them privately to the maintainer before public disclosure. Include:

- a clear description of the issue
- affected files or components
- reproduction steps if available
- impact assessment
- any suggested remediation

## Secret Handling

This repository should not contain:

- real API keys
- private TLS materials
- production `.env` files
- live webhook URLs
- real credentials embedded in scripts or config

Use placeholders in committed examples and inject real values only on the target system.

## Hardening Expectations

Before exposing a deployment publicly, make sure to:

- replace any self-signed bootstrap certs with real certificates
- rotate temporary passwords
- prefer SSH key authentication
- restrict access to Grafana, Prometheus, Alertmanager, and Loki
- review rate limits and auth settings
- verify Docker and NVIDIA runtime behavior on the target host
