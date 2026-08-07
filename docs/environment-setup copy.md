## Current State

| Component | Status | Notes |
|---|---|---|
| Resource group `rg-budgetguard-lab` | ✅ | westus2 |
| Lab VMs (`vm-lab-01`, `vm-lab-02`) | ✅ | `Standard_B2pts_v2`, ARM64, no public IP |
| Automation Account `aa-budgetguard` | ✅ | eastus2 — separate region allowlist from VMs |
| System-assigned managed identity | ✅ | Virtual Machine Contributor, RG scope only |
| Runbook `Stop-TaggedVMs` | ✅ | Published, tested dry-run + live + idempotent |
| Nightly schedule | ⬜ | Phase 5 |
| Emergency-stop runbook + webhook | ⬜ | Phase 6 |
| Budget + action group | ⬜ | Phase 7 |
| Bicep IaC | ⬜ | Phase 10 |
| GitHub Actions (OIDC) | ⬜ | Phase 11 |

## Environment Constraints

This was built on an Azure for Students subscription, which imposes restrictions
absent from pay-as-you-go accounts. Anyone reproducing this will likely need to
re-derive their own values.

**Region policy.** An Azure-managed policy limits deployable regions. Probing
with throwaway vnets gave: eastus2, westus, westus2, canadacentral.

**SKU restrictions.** All 41 x64 B-series sizes returned
`NotAvailableForSubscription`. The only burstable family available was `B2p*`
— ARM64 (Ampere) — which forced the image to
`Canonical:ubuntu-24_04-lts:server-arm64:latest`.

**Automation has its own allowlist.** Creating the Automation Account in westus2
failed; the error named a different set of regions (eastus, eastus2, westus,
northeurope, southeastasia, japanwest). eastus2 was the only overlap. The
Automation Account manages VMs in westus2 without issue, since RBAC scope is
independent of region.

**Runtime version.** Runbooks target PowerShell 7.2 because the Runtime
Environment experience needed for 7.4 wasn't available here. 7.2 is past
upstream end-of-support; the runbooks are version-agnostic and would run
unmodified on 7.4.

**CLI extension.** `az extension add --name automation` fails to build against
the Homebrew CLI's Python 3.14. Worked around with `az resource show` against
the generic ARM endpoint — no extension required.

## Reproducing

Region-allowed probe:

\`\`\`bash
for r in eastus eastus2 westus westus2 canadacentral; do
  if az network vnet create -g $RG -n probe-$r -l $r --address-prefix 10.0.0.0/24 -o none 2>/dev/null; then
    echo "ALLOWED $r"; az network vnet delete -g $RG -n probe-$r -o none
  else echo "blocked $r"; fi
done
\`\`\`

Unrestricted small SKUs in an allowed region:

\`\`\`bash
az vm list-skus --location westus2 --resource-type virtualMachines \
  --query "[?length(restrictions)==\`0\`].{Size:name, vCPU:capabilities[?name=='vCPUs'].value|[0]}" \
  -o tsv | awk '$2 <= 2' | sort
\`\`\`