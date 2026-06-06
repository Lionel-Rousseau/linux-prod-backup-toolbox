# Multi-host Linux backup orchestration with restore verification

> Multi-host backup orchestration scripts for a small Linux infrastructure
> operated 24/7 since 2018. `rsync`, LUKS containers, idempotent remote operations,
> SHA-256 verified config sync, and a verification loop that has actually
> caught silent failures in production.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-5.x-1f425f.svg)](#)
[![Status: production](https://img.shields.io/badge/status-production-success.svg)](#)

---

## Why this repository exists

This is the operational backup layer of a small but real production
infrastructure that I have administered in autonomy since late 2018 ‒
three physical sites interconnected over a Tailscale mesh, up to three dedicated
servers hosted at OVH for the Internet-facing services (web, mail, MX
secondary). It supports a 24/7 e-commerce activity. The full architecture
is documented in a companion repository:

- [`Lionel-Rousseau/laflanelle-secops-architecture`](https://github.com/Lionel-Rousseau/laflanelle-secops-architecture)

This repository is narrower: it shows **how the data actually gets backed
up, encrypted, replicated, verified, and how silent failures are caught**.
Operating this stack for seven years has produced a handful of opinions 
that you will find embedded in the code:

- **Backing up goes along tested restoration.** A backup needs to be restored to prove it is fully effective. See
  [`docs/restoration-runbook.md`](docs/restoration-runbook.md) and
  [`verification/`](verification/).
- **Idempotency for backups = peace of mind.** Every LUKS operation in
  [`orchestrator/luks_functions.sh`](orchestrator/luks_functions.sh)
  cleans up after itself, on the success path **and** on the error path.
- **Errors that go unread are silent killers.** The orchestrator pulls remote
  logs back, scans them for negative markers, and only the abnormal
  outcome reaches the inbox. See
  [`docs/log-marker-strategy.md`](docs/log-marker-strategy.md).

A short list of real incidents these techniques have caught in the wild
is in [`docs/real-incidents.md`](docs/real-incidents.md).

---

## What is in this repository

```
linux-prod-backup-toolbox/
├── README.md                           This file
├── LICENSE                             MIT for code, CC-BY-SA 4.0 for docs
├── docs/
│   ├── architecture.md                 Topology, hosts, data flows
│   ├── threat-model.md                 What we protect against
│   ├── 3-2-1-strategy.md               How 3-2-1 methodology is applied
│   ├── log-marker-strategy.md          Hunt for failures in logs
│   ├── restoration-runbook.md          Recovery actions
│   └── real-incidents.md               Silent failures detected
├── orchestrator/                       The backup conductor (Debian VM)
│   ├── backup-nightly.sh               Main scheduler, run by systemd
│   ├── luks_functions.sh               Idempotent LUKS open/close library
│   ├── backup-nightly.service          Systemd unit
│   ├── backup-nightly.timer            Systemd timer (00:30 daily)
│   └── .smtp_pass.example              SMTP password file template
├── nodes/                              Per-node backup logic
│   ├── nas-core/                       Synology NAS (DSM 7.3.x, ash shell)
│   │   ├── backup.sh                   Nightly script
│   │   └── mv2usb.sh                   Daily mirror to detachable 8TB USB
│   ├── web-mail/                       Web + mail Server (Ubuntu LTS)
│   │   ├── backup.sh                   System backup
│   │   ├── backup_webapp.sh            Web & MySQL daily backups
│   │   ├── backup_monthly_sql.sh       MySQL monthly specific backup
│   │   └── log_healthcheck.sh          Log checks
│   ├── mx-secondary/                   secondary MX + offsite storage (Ubuntu LTS)
│   │   ├── backup.sh                   System backup
│   │   └── log_healthcheck.sh          Log checks
│   └── raspberry-pi/                   IoT-automation Pi nodes
│       └── backup_image.sh             Imaging script example
├── verification/                       restoration test scripts
│   ├── README.md
│   ├── restore-test-rsync.sh           pulls a sample from a backup, diffs it
│   └── restore-test-mysql.sh           replays a SQL dump on a throwaway DB
├── extras/                             optional add-ons
│   ├── README.md
│   ├── security-onion-config-backup.sh dump SO rules + config (no PCAPs)
│   └── rpi-image-luks-wrapper.sh       wrap RonR Pi images in a LUKS volume
└── examples/
    ├── env.example                     all required variables
    └── crontab.example                 minimal scheduling without systemd
```

---

## The Architecture

A nightly orchestrator running on a hardened internal VM (Debian) connects
over SSH to three centrally-driven backup endpoints: the Synology NAS at
the core site, the Internet-facing combined web + mail server, and the
secondary MX. Raspberry Pi nodes run their own image-backup cron job and
land their images on the offsite storage. Each endpoint runs its own backup
logic. The orchestrator does three things on its own: it **synchronizes the
shared library and credentials** to every centrally-driven node with SHA-256 verification
to prevent silent drift, it **launches each remote backup with a deadline
and a hard kill**, and it **fetches the resulting log files back, scans
them for errors message and stale dates, and decides whether to send
mail at all**. A normal night produces no email; you only hear from it
when something is wrong.

Cross-site replication uses `rsync` over SSH on non-default ports, with
LUKS-encrypted containers on the destination side, opened just-in-time
with a key fetched from a third host (so a single host compromise does
not give the attacker the LUKS key). Check
[`docs/architecture.md`](docs/architecture.md) for the full topology.

---

## Headline features

- **Window-based execution.** Each job declares a hard deadline; if the
  remaining window is shorter than the requested timeout, the timeout
  shrinks. After the global window closes, queued jobs are skipped and
  flagged.
- **Single-execution locking.** `flock` on the orchestrator side, per-job
  `mkdir` locking on the remote side, so a missed run cannot collide
  with the next one.
- **SHA-256 verified config sync.** When the orchestrator pushes
  `luks_functions.sh` or `.smtp_pass` to a node, it computes the local
  hash, compares it to the remote hash, and only transfers when they
  differ and re-verifies the hash on the destination after upload.
- **Idempotent LUKS cycles.** `prepare_luks_mount` and
  `close_luks_mount` always start by cleaning up any previously-open
  mapper or stuck mount on the same path; the error trap on every entry
  point also performs an emergency close so a crashed run never leaves a
  decrypted volume mounted.
- **Just-in-time key retrieval.** LUKS keys never live on the destination
  host. The mapper-open command fetches the key over SSH from a separate
  host, pipes it into `cryptsetup` on stdin, never writes it to disk.
- **Alerting.** The orchestrator pulls remote logs after
  each job, check if the file exists, check its date matches today,
  check the success marker is present, and finally that no known error strings
  appear (`scp:`, `rsync:`, `ERROR:`, `Permission denied`,
  `Connection timed out`, `Broken pipe`, `not mounted`, `LOCK_BUSY`,
  `No such file or directory`). Anything failing those checks mark
  the run as `FAIL`, and only `FAIL` triggers an email. Node-level mail
  alerts are kept as a fallback, while the orchestrator remains the
  primary notification source.

---

## The Run

The orchestrator is driven by a systemd timer that fires once a day at
00:30. The unit file is in
[`orchestrator/backup-nightly.timer`](orchestrator/backup-nightly.timer);
copy it to `/etc/systemd/system/`, enable it with
`systemctl enable --now backup-nightly.timer`, and you are done.

Per-node scripts are designed to be invokable independently as well.
Each one accepts no arguments, reads its configuration from environment
variables (or hardcoded paths if you prefer), writes structured logs to
`/var/log/`, and exits with a non-zero status on failure. `rsync` exit 
code 24 is treated as a benign condition by node wrappers and does 
not make the job fail.

The minimum-viable configuration is described in
[`examples/env.example`](examples/env.example).

---

## What this is not

- **This is not a backup product.** You will need `rsync`,
  `cryptsetup`, `restic`, `swaks`, `ssh`, `flock` to be present on the
  hosts. They are not included here.
- **Not multi-tenant.** It is sized for a small infrastructure with a
  handful of nodes. Past that, look at proper backup
  software (BorgBackup with a backup server, Bareos, restic with
  `rest-server`, …) or orchestrators like Ansible AWX driving a real
  backup tool.
- **Not a complete defense.** It is one layer of a defense-in-depth
  posture (see the [architecture repository](https://github.com/Lionel-Rousseau/laflanelle-secops-architecture)
  for the full picture: WAF, NGFW with IPS, NSM with Suricata + Zeek,
  XDR/SIEM with Wazuh, host hardening per CIS benchmarks).
- **Not a public Ansible role.** Productionising this for any
  infrastructure that is not exactly mine is a decent week of work, with
  parametrisation, secret-store integration (Vault), proper handlers,
  and tests. A roadmap entry, not a finished product.

---

## Anonymisation notes

This repository is published from a real production codebase. Hostnames,
IP addresses, user names, paths, and email addresses have been replaced
with documentation placeholders (`example.org`, `example.net`,
`10.0.0.0/8`, `admin@example.org`). The structure, control flow, error
handling, and verification logic are unchanged. Any secret or credential
file referenced by these scripts (`.smtp_pass`, MySQL credentials, LUKS
keys) is **never** included; their expected shape is documented in the
`*.example` files.

---

## On the production of this repository
The infrastructure and scripts described here have been built along and run
in production since 2018. The code, design choices, and operational
decisions, including the verification loop, the LUKS key custody
pattern, and the multi-host orchestration, are the author's,
accumulated over at least seven years of running this stack. The anonymisation 
of the data shown and the formatting of the code and text for 
publication were carried out with the assistance of Claude 
(Anthropic). Everything was reviewed and validated by the author 
before publication. The original code, the architecture, and the 
technical choices are entirely the author's.

---

## License

Source code: [MIT](LICENSE).

Reuse in your own infrastructure is welcome; attribution is appreciated 
but not required. Pull requests with improvements (especially around portability, 
secret management, and testing) are welcome.

---

## About

Maintained by **Lionel Rousseau** - Linux administrator and SecOps
practitioner, CompTIA Security+ and CySA+ certified.
[`lionel@rousseau.kr`](mailto:lionel@rousseau.kr) ·
[LinkedIn](https://www.linkedin.com/in/lionel-rousseau-kr/) ·
[GitHub](https://github.com/Lionel-Rousseau).
