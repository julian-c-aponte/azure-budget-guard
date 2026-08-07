# Azure Budget Guard


Azure Cost Management lets you set budgets, but when you cross them, Azure just sends an email. There is no real enforcement, your resources keep running and charging you until you manually shut them down. Whether you are a student protecting limited cloud credits or a corporation with a forgotten dev environment racking up weekend bills, this is a massive gap. I built this project to be the missing enforcement layer: an automated, event-driven bot that watches your spending and actually stops your resources when a limit is breached.

## The Solution

This project implements a missing enforcement layer for Dev/Test and Sandbox environments using two deliberate triggers:

1. **Routine Hygiene (Scheduled):** Every night at 22:00, the bot deallocates any Virtual Machine tagged with `AutoShutdown=true`.
2. **The Circuit Breaker (Budget-Driven):** When spend crosses a defined threshold, an Azure Budget alert fires an Action Group. This posts to a webhook, triggering a runbook that stops everything *not* explicitly tagged as exempt. 

## Architecture 

The core of this system is built on **Azure Automation** (a managed PowerShell execution environment) prioritizing least-privilege security.

```mermaid
graph TD;
    A[Azure Cost Management] -->|Crosses Threshold| B(Action Group)
    B -->|POST Webhook| C[Azure Automation Runbook]
    
    D[Time Schedule: 22:00] -->|Triggers| C
    
    C -->|Authenticates via| E{System-Assigned Managed Identity}
    E -->|Virtual Machine Contributor RBAC| F[Target Resource Group]
    
    F -->|Shuts down| G[VMs missing 'Exempt' Tag]
    F -->|Ignores| H[Exempt VMs]
    
    C -->|Sends| I[Email/Chat Notification]
