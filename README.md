# nix-proxmox-cattle

Build a service's whole operating system with Nix, ship it as a **Proxmox LXC
template**, and deploy it by **replacing the container**. No `nixos-rebuild` on
a running box, no configuration management, no drift: the container is cattle.

This repo is the reusable half of that pattern — a NixOS module, a `mkTemplate`
helper and a reusable GitHub Actions workflow. It is deliberately small. The
interesting parts are the **contract** below and the reasons behind it.

```
app repo ──CI──> release asset (.tar.xz)  ──poll──> hypervisor ──> container replaced
   flake                  filename = nixpkgs rev + app commit
```

---

## Using it

An app repo needs two things.

**1. Expose the template from its flake** — add `nix-proxmox-cattle` as an input
and call `mkTemplate`:

```nix
inputs.cattle.url = "github:charlesbaynham/nix-proxmox-cattle";

# ...in outputs, merged into the rest of the flake:
cattle.lib.mkTemplate {
  inherit nixpkgs;
  name = "myservice";
  stateDir = "/data";              # omit entirely if the service is stateless
  modules = [ self.nixosModules.myservice { services.myservice.enable = true; } ];
}
```

`mkTemplate` returns `nixosConfigurations.<name>-lxc` and
`packages.<system>.proxmoxLxcTemplate`, so merge it into the flake's other
outputs — with `nixpkgs.lib.recursiveUpdate` if they are built by
`flake-utils.lib.eachDefaultSystem`.

**2. Build it in CI** — call the reusable workflow:

```yaml
jobs:
  lxc-template:
    permissions:
      contents: write
    uses: charlesbaynham/nix-proxmox-cattle/.github/workflows/build-template.yml@v1
```

That is the entire overhead. Everything else about the service — its packages,
its units, its ports — is ordinary NixOS configuration in the app's own module.

---

## The service contract

A conforming service promises all of this. The deployer relies on every point.

**One `.tar.xz` asset per release.** The deployer refuses a release carrying
zero or several, because it has no way to choose. It verifies the asset against
the `digest` GitHub computes for it, so no separate checksum file exists or is
wanted.

**The template filename carries both revisions.** `<name>-<nixos-label>-<sha7>`.
The label supplies the nixpkgs revision, CI appends the app commit. A new
filename is what forces the container to be replaced, so *a change to either the
app or its nixpkgs pin must produce a new name*. Never flatten this to a fixed
name plus a "latest" pointer: rollback needs older generations to remain
distinct and downloadable.

**An HTTP endpoint answering 200 when healthy.** Plain HTTP, on the port the
registry declares, on the service's own address. **Backends never terminate
TLS** — that is the border router's job, and a backend with its own certificate
is a backend with its own inbound path.

**All state under `stateDir`, or none at all.** State lives on a Proxmox volume
mounted there. If the mount is missing, the shared module's preflight unit
**fails the boot** rather than let the service write to a rootfs that is about
to be discarded.

**Secrets at `<stateDir>/secrets/<name>.env`, mode 0600**, seeded out of band
and never in git, never in the image. The service **refuses to start** when a
required value is missing or still a placeholder. Coming up insecure is a worse
failure than not coming up.

**No password authentication and no sshd.** Access is `pct enter` from the
hypervisor. There is nothing inside worth logging into: the next deploy throws
it away. ⚠️ The shared module enforces this with `mkForce`, because upstream's
`proxmox-lxc` module turns sshd *on* — nothing could log in, but a listening
service nobody asked for is not what the contract says.

---

## Why it is shaped this way

### The filename is the deploy mechanism

Proxmox's `template_file_id` is ForceNew, so pointing a container at a different
template destroys and recreates it. That single property is the whole deploy
engine — no agent, no orchestration, no in-place upgrade path to keep working.
The cost is that the template name must be a faithful hash of *everything* that
went into the rootfs, which is why both revisions are in it.

### Pull, not push

CI has no route to a hypervisor behind domestic NAT. Pull-based deployment needs
no tunnel and no hypervisor credential in GitHub; the price is a polling delay
and no CI signal on a bad commit, which is why a health check and an automatic
rollback are part of the deployer rather than optional extras.

### State survives by belonging to somebody else

Proxmox refuses to free a mount-point volume that the container being destroyed
does not own:

```perl
if ($vmid == $owner) { PVE::Storage::vdisk_free($storage_cfg, $volume); }
else { warn "ignore deletion of '$volume', CT $vmid isn't the owner!\n"; }
```

So the state volume is allocated to a **reserved VMID that has no guest**. Every
deploy logs that warning. It is the guard working.

⚠️ The tempting alternative — a bind mount — also survives, and is a trap:
`mountpoint_backup_enabled` excludes any mount point whose type is not `volume`,
so a bind-mounted state directory is **structurally invisible to `vzdump`** no
matter what the backup job says. State goes in a managed volume with
`backup=1`, always.

### The preflight guard fails the boot, not the service

`cattle-state-preflight` is `RequiredBy=multi-user.target`, so a state volume
that failed to attach stops *everything*, rather than leaving one service to
discover the problem itself. A missing mount is not an error the application
should have to know about, and a service that writes state to the rootfs looks
perfectly healthy right up until the next deploy erases it.

### Unprivileged, and only modestly hardened

The containers are unprivileged with `nesting` on (systemd needs it). They are
not individually hardened, and that is a deliberate division of labour: the
security boundary is the border router in front of them. What the cattle model
buys instead is that every one of them is reproducible and disposable — a
compromised container is fixed by deploying it again.

---

## Keeping the storage bounded

A conforming repo publishes a release per build of its release branch and never
deletes one, so both a private repo's storage quota and the deployer's own
release scan run out eventually. A second reusable workflow prunes both, and
wants a daily schedule:

```yaml
jobs:
  prune:
    permissions:
      actions: write   # delete artifacts
      contents: write  # delete releases and their tags
    uses: charlesbaynham/nix-proxmox-cattle/.github/workflows/prune-storage.yml@v1
```

It deletes **build artifacts** over three days old — nothing downstream reads
one, since the deployer fetches release assets — and **releases** beyond the
newest ten per *asset family* and the last fourteen days. The family is the
asset filename up to its first version token, so a repo building templates for
several services keeps ten of each rather than ten in total: without that, a
rarely-touched service loses the only template it has to the daily churn of a
busy one. A release carrying no assets is never touched.

⚠️ Only the artifacts are billed, and only in a private repo. Release assets
cost nothing at any size — but `resolve_release` scans a single page of
`/releases`, so a repo that publishes past a hundred stops being able to see
its own older generations, which is the rollback path.

## Versioning

`v1` is a **moving major ref** — a branch, fast-forwarded from `master` on
compatible changes:

```bash
git push origin master:v1
```

Workflow callers pin `@v1`; flake consumers are pinned by their own
`flake.lock` and move when they choose to. Good enough for a single-owner
ecosystem, and it means a fix to the workflow reaches every service without
touching any of them. A breaking change gets `v2` and leaves `v1` where it is.

## Layout

| Path | What it is |
|---|---|
| `modules/cattle.nix` | The shared NixOS module: `cattle.name`, `cattle.stateDir`, the LXC fixups, the preflight guard. |
| `flake.nix` | `nixosModules.cattle` and `lib.mkTemplate`. |
| `.github/workflows/build-template.yml` | The reusable `workflow_call` build-and-publish workflow. |
| `.github/workflows/prune-storage.yml` | The reusable `workflow_call` storage prune: build artifacts, and releases past the newest few per service. |

The deploying half — the service registry, the OpenTofu, the poll loop — is
specific to one home lab and lives in a private `homelab-infra` repo. This repo
does not depend on it, and a different deployer that honours the contract above
would work just as well.
