# Site

The repository's Node service for the Sigil website. Run locally with Node 22 or
later:

```sh
npm --prefix Site ci --ignore-scripts
PUBLIC_ORIGIN=http://localhost:3000 PORT=3000 npm --prefix Site start
```

`PUBLIC_ORIGIN` must be an exact HTTPS origin; HTTP is allowed for loopback
development. `GET /health` returns no-store JSON with `status`, `revision`,
`gitSHA`, `dirty`, and `sourceSHA256`. Unstamped development reports
`revision: "development"` and null identity fields.

Use the [shared stamped deployment flow](../docs/deployment.md) for a separately
authorized upload. Site's production Docker build requires the staged manifest,
canonical revision loader and a valid stamp; the raw checkout is not an upload
bundle. A matching health stamp establishes source identity, not operational
health.

Verify with `npm --prefix Site test`. Deploy tests use only generated Git
repositories, a fake Railway executable, an isolated CLI home and loopback HTTP.
