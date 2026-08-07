# Azure Budget Guard

[![Deploy to Azure](https://github.com/julian-c-aponte/azure-budget-guard/actions/workflows/deploy.yml/badge.svg)](https://github.com/julian-c-aponte/azure-budget-guard/actions)
[![Bicep](https://img.shields.io/badge/IaC-Bicep-0078D4?logo=microsoftazure)](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> Azure Cost Management allows you to set budgets, but when you cross them, Azure only sends an email. I built this project as the missing enforcement layer: an automated, event-driven bot that watches spending and actively halts resources when limits are breached.

## The Problem

Azure's native budget tools lack enforcement power. When a budget is exceeded, your resources keep running and keep charging you. For a dev environment left running over the weekend, this can be an expensive mistake. Azure will warn you about overspending, but it won't physically stop it.

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
