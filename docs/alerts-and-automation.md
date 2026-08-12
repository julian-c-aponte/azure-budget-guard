# Alerts & Automation

I built this project with two independent triggers: a nightly schedule for routine hygiene, and a budget threshold for emergency stops. I did this deliberately — if one fails, the other acts as a backstop. A cost-control system that relies on a single trigger isn't real control.

---

## The Nightly Schedule (Routine Hygiene)

Every night at 22:00, the bot deallocates any VM tagged `AutoShutdown=true`.

The trap I nearly walked into here is that scheduled runbooks in Azure take their parameters from the **schedule link**, not the runbook's defaults. My script deliberately defaults to `DryRun=true` for safety. If I hadn't explicitly overridden this in the schedule, the job would run successfully every night, turn nothing off, and give me a false sense of security.

**The lesson:** a silently skipping job still logs as a success. You have to check the actual job record to prove it armed correctly.

---

## The Circuit Breaker (Emergency Stop)

When a budget is breached, this runbook stops everything unless it is explicitly tagged `AutoShutdown=exempt`.

Notice the inverted logic:

| Trigger | Filter | Dry-run default | Reasoning |
|---|---|---|---|
| Nightly schedule | Opt-in | `true` | Accidentally shutting down capacity on a routine Tuesday is worse than doing nothing |
| Circuit breaker | Opt-out | `false` | If you are actively bleeding money, a manual-arming requirement makes the tool useless |

---

## Bridging the Gap: Webhooks & Action Groups

To connect the budget alert to the runbook, I used an Azure Action Group posting to a webhook.

The webhook URL **is** the credential, and Azure only shows it to you once. You cannot retrieve it later, and you cannot generate it dynamically via Bicep templates. It has to be passed into the infrastructure-as-code securely, out-of-band.

---

# Engineering Insights & Constraints

Building this required navigating several real-world cloud constraints that you don't encounter in standard tutorials.

**Budget evaluation lags reality.** Azure evaluates budgets against cost data that trails actual usage by 8–24 hours. Because of this, alerts cannot be forced to fire on demand. To verify the system end-to-end, I couldn't just click a test button; I had to deploy a $1 "tripwire" budget scoped specifically to my lab resource group and wait for the usage API to catch up.

**Resource providers are opt-in.** My first attempt at the Action Group failed because `Microsoft.Insights` wasn't registered on my subscription. An unregistered provider looks exactly like a permissions error until you know what you are looking for.

**Defensive parsing is mandatory.** Azure budget alerts have shipped in multiple JSON schemas over time. Rather than assuming a specific shape and breaking if it changes, my runbook dumps the raw request body and tries several known paths. It never lets a parse failure block the actual shutdown loop.

**Repo-to-Azure Drift.** A major issue that I dealt with while adding the discord webhook functionality to the runbooks, is that I forgot my local files in Visual Studio Code don't sync with the Azure Portal. This led to me trying to debug an issue that didn't exist, because I forgot to update the runbook in the Azure Portal to match what I already have in my files.

**Notifications must not block actions.** The Discord chat webhook runs in a `try/catch` block *after* the VMs are deallocated. A bot that announces what it's about to do, fails to send the message, and then halts the shutdown process is worse than a bot that stays quiet and stops the billing.