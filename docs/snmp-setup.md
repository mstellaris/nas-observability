# SNMP Setup

DSM-side runbook for enabling SNMP on the Synology NAS and populating the exporter's configuration, which together make Feature 002's NAS-specific metrics flow into Prometheus. Do this once per NAS; the F002 stack wiring is separate and documented in the PR that ships it.

## Prerequisites

- Feature 001 is deployed and running on the DS224+ (four containers healthy per `sudo bash scripts/diagnose.sh`).
- SSH access to the NAS with a `sudo`-capable admin account.
- A browser tab open to DSM's Control Panel.

## Step 1: Enable SNMP on DSM

1. **Control Panel → Terminal & SNMP → SNMP tab**.
2. Check **Enable SNMPv2c service**. (SNMPv3 is supported but introduces complexity without security benefit on a single-tenant LAN; see Constitution v1.1 Platform Constraints and F002 spec D1 for why we chose v2c.)
3. **Community**: pick any non-default string (avoid `public`, which every random SNMP scanner probes for). Suggestions: 16 characters of [a-zA-Z0-9], or a short memorable word + a random suffix. This lives only on your LAN; it's a namespace more than a password, but don't make it trivially guessable.
4. **Location** / **Contact**: optional, free-text. Useful if you run multiple NASes later.
5. Leave **Allowed source IP** empty for now (LAN-only), OR restrict to the NAS's own IP range for belt-and-suspenders.
6. Click **Apply**.

**DSM firewall prompt:** on Apply, DSM may open a "Firewall Notification" dialog about UDP 161 being blocked and ask whether to allow it. **Click OK** to allow. The SNMP exporter runs with `network_mode: host` and queries `localhost:161`; DSM's firewall applies to loopback too, so refusing the allow-rule would break the scrape even from inside the NAS. The LAN-only threat model (see Spec D1's SNMPv2c rationale) justifies allowing UDP 161 from LAN sources. If you want stricter scoping later, add a custom rule in **Control Panel → Security → Firewall** restricting UDP 161 to source `127.0.0.1` only — a post-feature hardening option, not required for F002.

Save the community string somewhere you can paste from. You'll use it in Step 3.

## Step 2: Verify SNMP is reachable

Over SSH on the NAS:

```bash
snmpwalk -v2c -c <your-community-string> localhost .1.3.6.1.4.1.6574 | head
```

**Expected**: 5–10 lines of Synology MIB output, each starting with an OID like `SNMPv2-SMI::enterprises.6574.1.1.0` and a value. This confirms the SNMP daemon is running and your community string works.

If `snmpwalk` is not installed on the NAS, install it via DSM's package manager or SSH:
```bash
sudo apt-get install snmp    # if DSM's package layer supports it
# or use `opkg install snmp-utils` if you have Entware
```

If this returns a timeout or authentication error, jump to **Troubleshooting** below.

## Step 3: Store the community string in a local file on the NAS

The SNMP exporter can't read environment variables from its `snmp.yml`; F002's plan resolves this by rendering `snmp.yml` on the NAS side via `envsubst` in the init script, which reads the community string from a local file. Create that file now:

```bash
sudo mkdir -p /volume1/docker/observability/snmp_exporter
sudo bash -c 'echo "<your-community-string>" > /volume1/docker/observability/snmp_exporter/.community'
sudo chmod 600 /volume1/docker/observability/snmp_exporter/.community
sudo chown 1026:100 /volume1/docker/observability/snmp_exporter/.community
```

Replace `<your-community-string>` with the actual string from Step 1. The file should end in a single newline; the `echo` form above handles that.

**Verify:**
```bash
sudo ls -ln /volume1/docker/observability/snmp_exporter/.community
# Expected: -rw-------  1 1026  100  <N>  <date>  .community
```

The `.community` file is gitignored at the repo level (via `.gitignore`'s `*.community` rule) and never leaves the NAS. It's the entire secret surface for SNMP auth.

## Step 4: Generate `snmp.yml` from the NAS's MIB tree (forks only, optional for this NAS)

This repo already commits `config/snmp_exporter/snmp.yml.template` that's known to work with DS224+ on DSM 7.3 (per Spec D2). **If you're on this specific NAS, skip Step 4** — the init script (Step 5) uses the committed template. Proceed to Step 5.

**If you're forking this repo onto a different Synology model or a much newer/older DSM**, the MIB tree may differ. Regenerate the template with these steps:

1. Download Synology's SNMP MIB files from Synology's support site. Search "Synology SNMP MIB download" in Synology Knowledge Center; the canonical link changes occasionally, so navigate from there rather than hard-coding a URL.
2. Place the `.mib` files in `/volume1/docker/observability/snmp_exporter/mibs/` on the NAS.
3. Run the walkgen inside `snmp_exporter`'s generator image:
   ```bash
   docker run --rm \
     -v /volume1/docker/observability/snmp_exporter/mibs:/mibs:ro \
     -v /volume1/docker/observability/snmp_exporter:/out \
     prom/snmp-exporter:v0.28.0-generator \
     generate \
       --snmp-mibs=/mibs \
       --fail-on-parse-errors \
       --output=/out/snmp.yml.raw
   ```
4. Review `/volume1/docker/observability/snmp_exporter/snmp.yml.raw`: prune OIDs the F002 dashboards don't consume (see `specs/002-synology-nas-scraping/plan.md` §D4 traceability table), strip v3-only auth fields (`security_level`, `auth_protocol`, `priv_protocol`) per Spec D1 since we're v2c, and templatize the community string to `${SYNOLOGY_SNMP_COMMUNITY}`.
5. Commit the result as `config/snmp_exporter/snmp.yml.template`, replacing the existing committed template.

**Fallback if walkgen tooling blocks you** (MIB parse errors, generator version misalignment, DSM-shell environment issues): use a well-maintained community `snmp.yml` (e.g., wozniakpawel's or RedEchidnaUK's Synology templates). Templatize its community line the same way, commit with a `# TODO: replace with walkgen output` header comment, and open a follow-up issue to circle back. F002's Spec D2 explicitly sanctions this fallback so the feature isn't blocked by SNMP-tooling friction.

## Step 5: Re-run the init script on the NAS

Once `.community` is in place and `snmp.yml.template` is committed to `main`:

```bash
curl -fsSL -o /tmp/init-nas-paths.sh https://raw.githubusercontent.com/mstellaris/nas-observability/main/scripts/init-nas-paths.sh
sudo bash /tmp/init-nas-paths.sh
```

**Expected output** (five lines once F002 is merged):

```
  /volume1/docker/observability/prometheus/data  (owner 1026:100)
  /volume1/docker/observability/grafana/data  (owner 1026:100)
  /volume1/docker/observability/snmp_exporter  (owner 1026:100)
  /volume1/docker/observability/prometheus/prometheus.yml  (owner 1026:100, mode 644)
  /volume1/docker/observability/snmp_exporter/snmp.yml  (owner 1026:100, mode 644)
```

If `.community` is missing when the script runs, it exits with an inline recovery snippet pointing back to Step 3 — no need to re-read this doc, just copy the commands from the error output.

## Step 6: Redeploy the stack in Portainer

In Portainer:

1. **Stacks → nas-observability → Editor** (or whichever stack name you used).
2. Click **Pull and redeploy** with **Re-pull image** enabled.
3. Wait 1–3 minutes. A fifth container (`snmp-exporter`) should appear and enter `Up`.

Portainer's "deploy from repository" method picks up the new compose definition from `main` automatically on re-pull.

## Verification

```bash
sudo bash /tmp/diagnose.sh    # re-fetch if needed
```

Expected summary: `HEALTHY — all 5 services running`.

Then, in a browser:

1. `http://<nas-ip>:9090/targets` → a fourth scrape job (`synology`) with state `UP` and recent scrape duration below 10 seconds.
2. `http://<nas-ip>:3030` → Grafana login; Dashboards browser now shows four dashboards (`Stack Health` from F001 plus `NAS Overview`, `Storage & Volumes`, `Network & Temperature` from F002, filterable by the `synology` tag).

## Troubleshooting

### `snmpwalk` returns "Timeout: No Response from localhost"

**Cause:** SNMP service isn't running, or the firewall blocks localhost from reaching the SNMP UDP port (161).

**Recovery:** Re-check Step 1 — confirm **Enable SNMPv2c service** is checked and Applied. If yes, check DSM's firewall (Control Panel → Security → Firewall) for any rule blocking UDP 161 on `localhost` / `lo`.

### `snmpwalk` returns "Authentication failure (incorrect community name)"

**Cause:** The community string you passed doesn't match what's configured in DSM.

**Recovery:** Re-check the community value in Control Panel → Terminal & SNMP → SNMP tab. Case-sensitive. Update `.community` on the NAS if you picked a different string than what's configured.

### Generator fails with "MIB parse error"

**Cause:** Synology's MIB files ship with occasional syntax quirks that `snmp_exporter`'s generator's underlying MIB parser (libsmi or netsnmp-mibs) doesn't tolerate.

**Recovery:** Drop to the community-snmp.yml fallback in Step 4. Most users don't hit this, but when they do, the fallback unblocks them without losing F002.

### `diagnose.sh` still shows `snmp-exporter` as "not deployed" after Step 6

**Cause:** Portainer didn't actually pull the new compose; it may have cached the previous deploy.

**Recovery:** In Portainer, explicitly click **Stop** on the stack, then **Start** again with "Pull and redeploy" checked. Or delete and recreate the stack. Watch Portainer's deploy log for the line "Creating nas-observability_snmp-exporter_1" or similar — its absence means the new compose wasn't read.

### Port 9116 reports "not bound" in `diagnose.sh` §5 even though snmp-exporter is running

**Cause:** If the SNMP exporter container started but crashed quickly, it may show as `Up` for a second then `Restarting`. Section 1's state column will show this; cross-check.

**Recovery:** Check `docker logs snmp-exporter` for the actual error (community string mismatch, malformed `snmp.yml`, etc.) and work from there.
