# pg_tde QA — Executive Summary (slide deck)

> Full workflow: [qa_workflow.md](qa_workflow.md)  
> Test coverage: [qa_test_coverage_executive_summary.md](qa_test_coverage_executive_summary.md)  
> Modules by area: [qa_test_modules.md](qa_test_modules.md)  
> Use this document for management briefings. Each section = one slide.

---

## Slide 1 — Title

**pg_tde QA: From Build Handover to Production**

- Percona PostgreSQL Transparent Data Encryption
- Example platform: **Ubuntu 26.04 x86_64**
- Repo: `percona-qa/postgresql/pytest`

---

## Slide 2 — Why this matters

**Problem:** QA has been a black box for build and release teams.

**Goal:** Same transparency we brought to the build pipeline — a clear,
repeatable path from **packages in testing** to **production release**.

**Outcome:** Everyone knows what runs, in what order, who owns each step, and
what must pass before promotion.

---

## Slide 3 — Three teams, one pipeline

| Team | Delivers |
|------|----------|
| **Build** | PostgreSQL + pg_tde packages → `ppg-18.4` **testing** repo |
| **QA** | Validation report + vendor sign-off + promotion recommendation |
| **Release** | Move packages **testing → release** → customer mirrors |

**Handover =** “Packages are in testing; here is the build # and version.”

---

## Slide 4 — The QA cycle at a glance

```
Build → Install on lab VM → pytest regression → Key providers → Upgrades → Multi-OS smoke → Sign-off → Release
```

**~1–3 days** on a single Ubuntu VM for core + KMIP + upgrades (vendor labs add time).

**~500+ automated pytest scenarios** plus bash upgrade matrix and Vagrant OS smoke.

---

## Slide 5 — Where tests run

| Environment | Used for |
|-------------|----------|
| **QA Ubuntu VM** | Primary: pytest, upgrades, vendor KMS labs |
| **Jenkins** (`pg.cd.percona.com`) | CI parity: upgrade parallel, KMIP jobs |
| **Docker** | Isolated runs without host PostgreSQL |
| **Vagrant matrix** | Pre-release: Debian, OL, Ubuntu multi-version |

---

## Slide 6 — Phase 1: Environment (Day 0)

**Script:** `setup_test_env.sh`

1. Install Percona PG 18 + pg_tde from **testing** repo
2. Create Python test venv
3. Optional: Cosmian KMS + OpenBao for key-provider tests
4. Smoke: extension loads, cluster starts

**Alternative:** `build_from_source.sh` when validating source before packages exist.

---

## Slide 7 — Phase 2: Core regression (Day 1)

**Tool:** `pytest` — primary harness

| Area | What we prove |
|------|----------------|
| Encryption | TDE tables, keys, rotation |
| Rewind | `pg_tde_rewind` after failover |
| Backup / recovery | PITR, crash recovery with encrypted data |
| Replication | Streaming with pg_tde |
| pgBackRest | Backup tool integration |

**Skip controls:** `--skip-sections=rewind,upgrade` for partial runs.

---

## Slide 8 — Phase 3: Key providers (Day 1–2)

| Provider | CI (every build) | Vendor sign-off (scheduled) |
|----------|------------------|----------------------------|
| **Cosmian KMIP** | Yes — automated | — |
| **OpenBao / Vault KV** | Yes — automated | Enterprise Vault lab |
| **Fortanix** | — | Weekly / release |
| **Thales CipherTrust** | — | Weekly / release |
| **Akeyless** | — | Weekly / release |

**Production recommendation:** Vault **KV v2** or supported KMIP vendor — not Vault KMIP engine.

---

## Slide 9 — Phase 4: Upgrades (Day 2)

| Track | Scenario | Tooling |
|-------|----------|---------|
| **Major** | PG **17 → 18** + pg_tde | `run_tde_upgrade_parallel.sh`, Jenkins job |
| **Minor** | **18.4.1 → 18.4.2** in-place | `run_minor_upgrade_workflow.sh` |

Validates: data survives, keys work, `ALTER EXTENSION pg_tde UPDATE` succeeds.

---

## Slide 10 — Phase 5: Release smoke (before production)

**Multi-OS package install** — not only Ubuntu 26.04:

- `package_testing/` — apt/yum install smoke
- `tarball_testing/` — tarball + SSL variant smoke

Runs on Debian, Oracle Linux, Ubuntu LTS matrix.

---

## Slide 11 — Exit criteria (QA sign-off)

Before recommending **testing → release**:

- [ ] Core pytest green
- [ ] Cosmian KMIP revalidation green
- [ ] OpenBao / Vault KV (if in scope)
- [ ] Major upgrade matrix green
- [ ] Minor upgrade workflow green
- [ ] Vendor KMS checklist (Fortanix / Thales / Akeyless) for release
- [ ] Multi-OS package smoke green

---

## Slide 12 — What QA does *not* block on

- Upstream pg_tde unit/TAP tests (engineering CI in pg_tde repo)
- Customer-specific deployment (Ansible, K8s) — out of scope for this harness
- Every vendor KMS on every nightly build — vendors are **scheduled sign-off**, Cosmian is **every build**

---

## Slide 13 — Dependencies on build team

QA needs at handover:

1. Package version + git SHA
2. Repo tier (`testing` vs `release`)
3. `PG_MAJOR`, `PG_REPO_LINE`, patch level
4. Known limitations (e.g. missing `pg_tde_rewind` in a build)

Without packages in **testing**, QA can still run **source build** path — slower, not release-parity.

---

## Slide 14 — Metrics we can report

| Metric | Source |
|--------|--------|
| Tests executed | pytest `-v` / Jenkins |
| Pass / fail / skip | pytest HTML report |
| Coverage by section | `--list-test-sections` |
| Vendor KMS status | `vendor-signoff.md` table |
| Upgrade scenarios | `ci_upgrade_scenarios.md` checklist |

---

## Slide 15 — Next steps for transparency

1. **Adopt** [qa_workflow.md](qa_workflow.md) as the team runbook
2. **Attach** handover checklist to every build QA ticket
3. **Publish** Jenkins job links + last green build in team channel
4. **Schedule** vendor KMS sign-off on release calendar (Fortanix, Thales, Akeyless)

---

## Slide 16 — One sentence summary

> **Build ships packages to testing → QA installs, runs pytest + upgrades + KMS sign-off on Ubuntu (and Vagrant matrix) → QA recommends promotion → Release ships to production.**
