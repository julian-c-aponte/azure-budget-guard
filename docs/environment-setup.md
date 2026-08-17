# Environment Setup & Architecture Decisions

Setting up this lab wasn't a standard deployment. Because I built this on an Azure for Students subscription, I hit restrictions you'd never see on a pay-as-you-go account. Where those constraints forced me to pivot, I've noted my workarounds below.

---

## The Security Boundary: Resource Group

I created a single resource group, `rg-budgetguard-lab` in `westus2`, to hold everything.

```bash
az group create --name rg-budgetguard-lab --location westus2
```

This isn't just cosmetic organization — it is the strict security boundary for the project. I scoped the automation identity's RBAC exactly to this group. By doing this, the blast radius of a compromised runbook is contained entirely within the lab.

The resource group itself is free, and its location is just metadata; it can hold resources deployed in other regions.

---

## The Targets: Lab Virtual Machines

To test the bot, I spun up two VMs: `Standard_B2pts_v2` (2 vCPU / 1 GB, ARM64) running Ubuntu 24.04, with no public IPs.

| VM | Tag | Role |
|---|---|---|
| `vm-lab-01` | `AutoShutdown=true` | Target — the bot should stop this |
| `vm-lab-02` | `AutoShutdown=exempt` | Control — the bot should leave this alone |

```bash
az vm create \
  --resource-group rg-budgetguard-lab \
  --name vm-lab-01 \
  --location westus2 \
  --image Canonical:ubuntu-24_04-lts:server-arm64:latest \
  --size Standard_B2pts_v2 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-address "" \
  --nsg-rule NONE \
  --os-disk-size-gb 30 \
  --storage-sku StandardSSD_LRS \
  --tags AutoShutdown=true Environment=lab Owner=julian-aponte
```

`vm-lab-02` is identical apart from the name and the `exempt` tag.

Every configuration choice here was deliberate:

**Why two VMs?** I didn't just want to prove the bot could turn something off; I needed to prove it discriminates. By setting a control VM, I validated that the bot actively reads the tags rather than just blindly terminating everything in its scope.

**Why no public IP?** These VMs are never logged into. The runbook acts on them through the Azure control plane, making the guest OS irrelevant and network access unnecessary. Exposing SSH to `0.0.0.0/0` guarantees the machine will be brute-forced within hours. Leaving a vulnerability like that in a repository dedicated to cloud governance would completely undercut the project's message.

**Why ARM64?** This wasn't a preference. Every single x64 B-series size I tried returned `NotAvailableForSubscription`. The Ampere-based `B2p*` family was my only burstable option, forcing me to use an explicit ARM64 URN instead of the standard Ubuntu alias.

**Why use tags?** Tag-driven governance scales in a way that hardcoded resource lists never will. The runbook never asks for a VM by name; it queries the environment for a tag. If I want to add a new machine to the shutdown policy tomorrow, I just add a tag — no code changes or republishing required.

---

## The Engine: Automation Account

I created `aa-budgetguard` in `eastus2` with a system-assigned managed identity.

You can retrieve the principal ID without needing the preview CLI extension:

```bash
PRINCIPAL_ID=$(az resource show \
  --resource-group rg-budgetguard-lab \
  --name aa-budgetguard \
  --resource-type "Microsoft.Automation/automationAccounts" \
  --query identity.principalId -o tsv)
```

You might notice the region mismatch — the VMs are in `westus2`, but the automation account is in `eastus2`. This wasn't a design choice. Azure Automation enforces its own separate region allowlist for student subscriptions, and `eastus2` was the only overlap. Fortunately, it doesn't matter: the Automation Account manages the VMs flawlessly because RBAC scope is independent of geography, and runbooks operate via the global ARM control plane.

The system-assigned managed identity is the security core of this project. It is a service principal in Entra ID that lives and dies with the resource. Azure handles all internal credential rotation. Because the runbook authenticates by simply calling `Connect-AzAccount -Identity`, there are **zero passwords, keys, certificates, or connection strings in this entire solution.** Nothing can be leaked, and nothing can be accidentally committed to GitHub.


---

## The Permissions: RBAC

I assigned the identity the **Virtual Machine Contributor** role, strictly scoped to `rg-budgetguard-lab`.

```bash
RG_ID=$(az group show --name rg-budgetguard-lab --query id -o tsv)

az role assignment create \
  --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" \
  --scope $RG_ID
```

The path of least resistance is assigning Contributor at the subscription scope. That is also the wrong answer. I intentionally constrained the bot in two ways:

**Narrow Role.** Virtual Machine Contributor can manage power states, but it cannot touch networking, storage, identity, or grant access to others. It is the absolute minimum permission required to do the job.

**Narrow Scope.** By assigning it to the resource group, the identity is completely blind to anything outside the lab. Even if the runbook code was swapped with malware, it couldn't touch the rest of my subscription.

If you were to deploy this across an entire organization, the correct architecture would be `Reader` at the subscription scope for discovery, combined with `Virtual Machine Contributor` strictly on the target resource groups.

---

## The Logic: Runbook `Stop-TaggedVMs`

I authored `Stop-TaggedVMs.ps1` locally and published it to the Automation Account. The repository remains the source of truth; the portal is just the execution environment.

I designed this runbook to **deallocate**, not just stop. This is a critical distinction. If you stop a VM from inside the guest OS, Azure still holds your compute reservation and keeps billing you. Deallocating releases the hardware and stops the meter. If I had used the `-StayProvisioned` switch, the bot would have generated perfect logs and saved exactly zero dollars.

I also built in a deliberate safety asymmetry:

- **Dry-run defaults to true.** A cost-control tool that accidentally deletes production capacity is worse than having no tool at all. The scheduled nightly runbook must be explicitly armed with `DryRun=false`.
- **Emergency stop is always armed.** In Phase 6, the emergency circuit breaker bypasses this. A circuit breaker that needs manual arming during a budget overrun is useless.

Finally, I ensured the runbook logs every VM it scans, not just the ones it shuts down. When a nightly job does nothing, I need to know if it found zero machines, or if it successfully filtered out exempt ones. I also made it idempotent — if it runs against an already-deallocated VM, it cleanly exits with `Nothing to do` rather than throwing an error and generating alert fatigue.

---

## Cost & Budgets (Upcoming)

In Phase 7, I will wire up a monthly budget (50% / 80% / 100% thresholds) to an action group that triggers the emergency webhook. Because Azure's cost data lags by 8–24 hours, this acts as a final backstop, while the nightly schedule serves as the primary control.

Currently, the lab costs look like this:

| Component | Cost |
|---|---|
| Resource group, tags, RBAC, budgets, action groups | Free |
| Automation Account | Free to exist; job runtime billed per minute (runbooks take <1 min, well within free tier) |
| VMs (`B2pts_v2` × 2) | ~$0.02/hr each, only while running |
| Managed disks (30 GB StandardSSD × 2) | ~$2–3/month each — billed whether or not the VM is deallocated |

The disks are the trap. Deallocating stops compute billing, but storage costs accrue indefinitely. I park the VMs between sessions, but I have to tear down the environment entirely when I'm done.

There is an obvious irony in manually deleting VMs while building an automated bot to save money, but that is exactly why this project is necessary.

---

## Reproducing the Constraint Discovery

If you are reproducing this on a restricted student account, do not copy my region and SKU values, you must derive your own.

I wrote a quick probe to figure out my allowed regions by spinning up free, instant virtual networks:

```bash
for r in eastus eastus2 westus westus2 westus3 centralus southcentralus northcentralus westeurope northeurope; do
  if az network vnet create -g $RG -n probe-$r -l $r --address-prefix 10.0.0.0/24 -o none 2>/dev/null; then
    echo "ALLOWED   $r"
    az network vnet delete -g $RG -n probe-$r -o none
  else
    echo "blocked   $r"
  fi
done
```

Once I knew `westus2` was allowed, I used this query to find unrestricted small SKUs (under 2 vCPUs) that I was actually permitted to deploy:

```bash
az vm list-skus --location westus2 --resource-type virtualMachines \
  --query "[?length(restrictions)==\`0\`].{Size:name, vCPU:capabilities[?name=='vCPUs'].value|[0]}" \
  -o tsv | awk '$2 <= 2' | sort
```

Conflating region policy and SKU availability cost me hours. A SKU can exist in a region where you are forbidden to deploy, and vice versa. You have to find the intersection.
