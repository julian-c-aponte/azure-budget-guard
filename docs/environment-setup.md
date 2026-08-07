# Build Log

Notes from building Azure Budget Guard, Written as I build my 1st ever project.

---

## 2026-08-07 - Provisioning the two VMs

**Goal:** two B1s VMs in eastus, one tagged `AutoShutdown=true`, one `exempt`.

**What happened:** four seperate failures before anything deployed.

1. `az vm create` in eastus -> `RequestDisallowedByAzure`. An Azure-managed policy restricts what regions my free student subscription can deploy to.

2. Switched to eastus2 -> got past policy, failed on `SkuNotAvailable` for `Standard_B1s`.

3. Queried `az vm list-skus` for eastus2 - every B-series size returned `NotAvailableForSubscription`.

4. Tried northcentralus because list-skus showed B2ats_v2 available there -> `RequestDisallowedByAzure` again.

**My mistake:** I thought that "SKU is available in region X" and "my subscription can deploy to region X" as one constraint. They're two, and they're indepenent of each other. `list-skus` answers the first. Only the policy answers the second.

**How I solved it:** Checked each region by creating and deleting a throwaway vnet (free, instant) to find the policy-allowed set, then ran `list-skus` filtered to `length(restrictions)==0` and `vCPUS <= 2` against only those regions, and took the intersection.

Allowed regions: eastus2, westus, westus2, canadacentral.
Only burstable SKU available in any of them: the `B2p*` family - which is ARM64, so `Ubuntu2404` wouldn't work. Had to switch the image to `Canonical:ubuntu-24_04-lts:server-arm64:latest`.

**Landed on:** westus2 (finally), `Standard_B2pts_v2` (2 vCPU / 1 GB, ~0.02/hr).

**Cost note:** B2pts_v2 is 2x the vCPU of the B1s I had planned for, so ~$0.04/hr for the pair. Deallocating between sessions.
