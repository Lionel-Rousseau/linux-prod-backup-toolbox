# 3-2-1 Strategy

The 3-2-1 backup rule is quite well known and effective: **3 copies of your
data, on 2 different media types, with 1 copy offsite**. This
document is an accounting of how this repository's setup actually
maps onto each leg, including the spots where it stretches the
definition.

## The three copies

For any given customer database row written today, by tomorrow morning
there are five distinct copies of it in the system:

1. The **live** copy on `web-mail` (production MySQL).
2. The **rsync mirror** on `mx-secondary` (rolling daily, LUKS at rest).
3. The **rsync mirror** on `nas-core` (rolling daily, cleartext).
4. The **dated SQL dump** on `web-mail` (kept for 3 days locally).
5. The **dated SQL dump** on `mx-secondary` (kept for 14 days, LUKS at
   rest).
6. The **monthly SQL archive** for compliance / accounting (kept for 12
   months, separate retention pipeline).
7. The **USB mirror** on `nas-core`, rsync'd daily to match the live
   consolidated dataset.

That is comfortably more than three. The point of having more is **independence**: each
copy is reachable through a different path. A bug in one path
(rsync exclusions wrong, SQL dump truncated, sshfs deadlock) leaves the
others intact.

## Two different media types

The 3-2-1 rule says **two different media types**. Different media types 
fail in different ways, with different failure modes:

| Media                                          | Where in this setup                                       |
|------------------------------------------------|-----------------------------------------------------------|
| Network-attached spinning disks (SHR1)         | `nas-core` Synology, internal storage pool                |
| Server-class disks at OVH                      | `web-mail` and `mx-secondary` system + data partitions    |
| **USB drive (permanently attached)**           | `nas-core`, daily rsync mirror via `mv2usb.sh`            |

The USB drive satisfies the "different media" leg in the strict sense,
it is a mechanically distinct device from the NAS internal pool and
fails independently of it. The two OVH servers, even though they are in
different datacenters, are still roughly the same media class.

A stricter interpretation would add tape (LTO) or write-once optical.
For the current scale (single-digit TB) and the threat model
(opportunistic ransomware, single-host failures), the USB mirror is the
sized response.

## One copy offsite

Two things qualify as offsite, by different definitions:

- **Geographically offsite.** `web-mail` and `mx-secondary` are at OVH,
  a hundred-plus kilometres from the core site and from each other. A
  flood at the core site leaves these untouched; a flood at OVH leaves
  the core site untouched.
- **Logically offsite.** The LUKS containers on the OVH destinations
  are not mounted between runs. Even if an attacker has root on
  `mx-secondary` between 00:30 and 06:00, the containers are closed; the
  attacker sees ciphertext.

The USB drive does **not** qualify as offsite as it is permanently
attached to the NAS and mirrors the live data. It is a fast local
restore point, not a geographically or logically independent copy.

## Where this stretches the definition

Reality facts.

- **The USB mirror window** is less than an hour per day. Because the drive is mounted
  only during the rsync run and unmounted immediately after, a ransomware process 
  on the NAS has a narrow window to reach it, only while mv2usb.sh is actively 
  writing. Outside that window, the drive is offline at the OS level. This makes 
  it a point-in-time safe copy rather than a permanently-exposed mirror.
- **The two OVH copies are correlated.** A vendor-side compromise of
  OVH would hit both.
  The NAS at the core site is the real independence for that scenario.
- **Verification is not free.** The orchestrator catches failures during
  the run and the log healthcheck catches them an hour later, but the
  third part of the verification is a manual process documented in
  [`restoration-runbook.md`](restoration-runbook.md), not a fully
  automated job. Two manual restores per month, on rotating
  hosts/datasets, is the price for confidence in the backups.
