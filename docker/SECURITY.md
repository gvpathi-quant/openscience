# Security Model — OpenScience Docker Sandbox

This document describes the security posture of the OpenScience Docker sandbox,
the deliberate relaxations we accepted, and why they were necessary.

---

## Skill Set — No Offensive Content

All 151 bundled skills are research / science / ML / data / cloud / visualization.
Categories: biology, chemistry, physics, quantum, ML (training/inference),
data engineering, databases, cloud compute, visualization, coding (ML/math/stats),
scholar-evaluation, quantum, document-parsing, etc.

**Zero offensive / pentesting / red-team / exploit / malware / reverse-engineering
/ binary-exploitation / CTF / shellcode skills.** The skill set is purely
constructive (research, analysis, modeling, visualization, cloud compute).
Base image is Debian (glibc), not Kali — no offensive tooling installed.

---

## Sandbox Escape — Reality Check

| Escape Vector | Status | Mitigation |
|--------------|--------|------------|
| Container breakout (kernel exploit) | Possible | Same kernel; mitigated by userns-remap (container root ≠ host root) |
| Docker socket access | Blocked | No `/var/run/docker.sock` mounted |
| Host filesystem | Blocked | `read_only` rootfs; only two named volumes writable |
| Network egress | Open (by design) | No egress filter; add Cilium/iptables if needed |
| Volume data | Mutable | Volumes are host-backed; compromise = volume corruption |
| bubblewrap inner sandbox | Working | Verified: 3/3 self-test passes (write containment, network deny) |
| Docker socket / host processes | No access | No `/var/run/docker.sock`, no `--pid=host`, no `--privileged` |

**Bottom line:** The inner bubblewrap sandbox (what `openscience sandbox test`
verifies) correctly confines agent commands to the workspace. The Docker
container boundary adds another layer. The only realistic escape is a **kernel
exploit** (same kernel) — the fundamental limit of any container sandbox.

---

## Threat Model

**Protected against:**
- Accidental host filesystem pollution (container rootfs is `read_only`)
- Host process visibility (separate PID / network namespaces)
- Persistent host pollution (only two named volumes persist)
- Privilege escalation via dropped capabilities

**Not protected against (known gaps):**
- Kernel exploits from inside the container (same kernel)
- Volumes are host-backed storage — a compromised container can corrupt volume data
- The `socat` proxy on `SANDBOX_PORT` publishes the internal loopback server to the host
- Any vulnerability in `bubblewrap`, `openscience`, or the kernel can be exploited from inside

---

## Required Relaxations (Why We Can't Be Stricter)

| Relaxation | Why Needed |
|------------|------------|
| `user: "0:0"` (root in container) | Docker clears **all capabilities for non-root users** at exec. Bubblewrap needs `CAP_SYS_ADMIN` to create mount/PID/net namespaces. Only root retains caps. |
| `cap_add: SYS_ADMIN, DAC_OVERRIDE, DAC_READ_SEARCH` | `SYS_ADMIN` = mount/PID/net namespace creation for bubblewrap. `DAC_OVERRIDE` + `DAC_READ_SEARCH` = container root can access files owned by the previous uid 1000 in the volumes (Docker userns-remap maps container root to a high host UID; DAC caps let it bypass the host-UID mismatch). |
| `security_opt: [seccomp=unconfined, apparmor=unconfined]` | Docker's default seccomp blocks `unshare(CLONE_NEWNS/CLONE_NEWPID/CLONE_NEWNET)` etc. AppArmor default profile blocks unprivileged user-namespace creation. Both must be off for bubblewrap's nested namespaces to work. |
| `no-new-privileges` removed | Bubblewrap's setuid binary (or root exec) needs to gain capabilities in the new user namespace. `no-new-privileges` would block that. |
| `read_only: true` + volumes | Only `/home/openscience` (home + workspace) and `/tmp` are writable. Everything else is immutable. |

---

## What's Still Isolated

| Layer | What It Blocks |
|-------|----------------|
| Docker container | Host PID / network / mount namespace; host filesystem (except volumes) |
| Read-only rootfs | No persistence of binaries, config, or malware in container layer |
| Cap drop (ALL minus 3) | No `CAP_NET_RAW`, `CAP_SYS_PTRACE`, `CAP_SYS_MODULE`, etc. |
| `tini` PID 1 | Proper signal handling, reaping zombie children |
| Inner bubblewrap sandbox | Agent-executed commands are confined to `/home/openscience/workspace`; optional network deny; write-outside-workspace blocked (verified by `openscience sandbox test`) |

---

## What an Attacker Inside the Container Can Do

- Read/write anything in `/home/openscience` (both volumes)
- Make outbound network connections (no egress filtering)
- Exploit kernel vulnerabilities (shared host kernel)
- Corrupt the volume data (host-backed storage)
- Access the proxied web UI port on the host (`SANDBOX_PORT`)

## What an Attacker Cannot Do (without kernel exploit)

- Escape the container mount / PID / network namespaces
- Read host files outside the mounted volumes
- Persist changes to the container rootfs (read-only)
- Gain host root (container root ≠ host root due to userns-remap)

---

## When This Is Acceptable / Not Acceptable

**Acceptable for:**
- Local development with your own keys/data
- Reproducible, disposable research environments
- Running your own skills / code you trust

**Not acceptable for:**
- Running untrusted third-party code
- Multi-tenant or production workloads
- Environments requiring PCI/DSS, SOC2, or similar compliance

---

## Hardening Options (If You Need Stronger Isolation)

1. **Rootless Docker + userns-remap + custom seccomp profile** allowing only the specific syscalls bubblewrap needs (`unshare`, `mount`, `pivot_root`, `setns`, `clone` with specific flags). This restores seccomp protection while allowing bubblewrap.
2. **Run bubblewrap on the host** (outside Docker) and have the agent exec into it via a controlled RPC — keeps the container fully unprivileged.
3. **gVisor / Kata Containers** — run the container in a lightweight VM with its own kernel.
4. **Egress firewall** (Cilium, iptables, or sidecar proxy) to allowlist only required external endpoints.

---

## Verification Checklist (Run After Changes)

```bash
# 1. Build
docker compose build

# 2. Basic probe
docker compose exec openscience bwrap --ro-bind / / --dev /dev --proc /proc --unshare-pid -- true && echo "bwrap OK"

# 2. Full sandbox self-test
docker compose exec openscience openscience sandbox test
# Expect: 3 passes (write inside, write outside blocked, network denied)

# 3. Web UI reachable
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:18080/
# Expect: 200

# 4. Health
docker compose ps --format '{{.Name}} {{.Status}}'
# Expect: healthy
```

If any check fails, the relaxations may need adjustment.