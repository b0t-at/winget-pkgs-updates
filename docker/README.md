# Observability stack (Loki + Grafana + Alloy)

Implements decisions **D8–D10** and **D15**: Grafana Loki for logs, Grafana for dashboards and
alerting, and Grafana Alloy to tail the Windows Sandbox validation logs.

> ⚠️ **Not verified live in this environment.** These files were authored without a Docker host or
> secrets. Bring the stack up on the observability host and validate before relying on it.

## Layout

```
docker/
├── docker-compose.yml            # loki + grafana + alloy
├── .env.example                  # copy to .env and fill in secrets
├── loki/loki-config.yml          # single-binary Loki, filesystem storage, 31d retention
├── alloy/config.alloy            # tails sandbox logs → Loki
└── grafana/
    ├── provisioning/
    │   ├── datasources/loki.yml
    │   ├── dashboards/provider.yml
    │   └── alerting/{contactpoints,rules}.yml
    └── dashboards/               # 5 dashboards as code
```

## Run

```bash
cd docker
cp .env.example .env      # then edit secrets (Grafana admin, Loki auth, ntfy)
docker compose up -d
```

Grafana: http://localhost:3000 (admin / `GRAFANA_ADMIN_PASSWORD`).

## Label schema (D9)

Only **low-cardinality** labels are used: `app`, `environment`, `phase`, `host`, `level`.
High-cardinality values (`package_id`, `version`, `run_id`, `manifest_hash`, `error`) are emitted in
the **JSON log body** and queried via LogQL `| json`. This is enforced in code by
`WingetMaintainer.Core.Observability.LokiLabelSchema`.

## Authentication (D15 / D-AUTH)

Loki runs without built-in auth. **Do not expose port 3100 publicly.** Options:

- Restrict access with **Tailscale** (recommended to start), or
- Put Loki/Grafana behind a reverse proxy that terminates basic auth / OIDC.

Alloy and the .NET Serilog Loki sink authenticate using `LOKI_USERNAME` / `LOKI_PASSWORD` when a
proxy enforces basic auth.

## Dashboards

1. **Pipeline Overview** — processed/failed/submitted stats, results by phase, recent activity.
2. **Package Explorer** — `$pkg` textbox variable; logs and results for a single package.
3. **Failures & Alerts** — skip-threshold table, failure rate by phase, error/warn logs.
4. **Sandbox Validation** — validations, timeouts, pass/fail by host, sandbox logs.
5. **Catalog / Inventory** — total packages and catalog size over time from `inventory` events.

## Alerts (D10)

`provisioning/alerting/rules.yml` defines two rules (errors present; skip threshold reached) routed
to the **ntfy** contact point built from `NTFY_URL`/`NTFY_TOPIC`. Alert-rule provisioning is
environment-specific — validate and tune in the Grafana UI after first deploy.
