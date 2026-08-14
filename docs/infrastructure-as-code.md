# Architectural Insights & Lessons Learned

I originally built this project by clicking through the Azure portal to understand the resources, but I quickly realized why Infrastructure as Code (IaC) is mandatory: **the portal hides the truth.** Rebuilding this system in Bicep and reconciling the code against my manual setup turned out to be the most instructive part of the project.

Here is what building this taught me about real-world cloud engineering.

---

## 1. "What-If" is a state diff, not a syntax check

When adopting IaC over existing infrastructure, `az deployment group what-if` is your best tool. It caught three critical problems before I ever deployed:

- A regional mismatch
- A silent downgrade of my PowerShell runbook version
- A scheduled time that had been invisibly mangled by a timezone translation in the portal UI

The UI looked correct, but only a diff against the declared infrastructure surfaced the reality.

---

## 2. The most dangerous failures log as "Success"

During deployment, I had a job schedule that reported a `Succeeded` deployment status, but the link to the runbook was missing. Every job would log green, but absolutely nothing would be shut down.

The lesson generalized across the project: **verify the actual resource and its behavior, not the operation that created it.** An API returning `200 OK` doesn't mean the system works.

---

## 3. Defensive parsing prevents brittle automation

Azure budget alerts ship in two different JSON schemas — the legacy AIP shape and the newer Common Alert schema — depending on how they are deployed. Rather than assuming one shape and breaking on the other, the runbook inspects the raw payload, tries several known field paths, and never lets a parse failure block the shutdown.

When my Bicep deployment silently upgraded the alert schema, the system kept working without a single code change. Refusing to assume a single payload shape saved the circuit breaker.

---

## 4. Webhook rotation is a silent failure waiting to happen

The webhook URL is the credential for the emergency stop, and Azure only displays it once at creation. Because it cannot be dynamically pulled into a Bicep template as an ARM output, it must be passed in out-of-band.

Rotating it requires a fragile, multi-step manual process. If you delete the webhook but forget to update the action group, a real budget breach will POST into nothing — with no warning that your circuit breaker is dead.

This limitation proved exactly why enterprise environments rely on Managed Identities instead of shared secrets wherever possible.

---

## 5. Reconciling identity is the hardest part of IaC adoption

When importing manual infrastructure into templates, configuration is easy, but identity is hard.

Bicep generates role assignments using deterministic GUIDs based on the resource names. When this collided with the random GUID Azure generated during my manual setup, the deployment failed. Fixing it meant deleting the manual assignment and letting the template own it — leaving a brief window where the bot was unauthorized.

Understanding how to navigate this window is the reality of migrating legacy cloud setups into IaC.

## 6. GitHub's OIDC subject format wasn't what the docs showed

GitHub's immutable subject claims changed the OIDC subject format. My federated credential registered repo:owner/name:ref:refs/heads/main, but GitHub presented repo:owner@<ownerID>/name@<repoID>:ref:refs/heads/main.

The numeric IDs make the subject survive a repository or account rename, which the plain format doesn't — a rename would silently break authentication.

The AADSTS700213 error includes the presented subject, which is the fastest path to diagnosis: register what the platform actually sends rather than what the documentation example shows.