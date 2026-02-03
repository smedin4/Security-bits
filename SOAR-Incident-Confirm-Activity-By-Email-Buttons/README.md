# Incident-Confirm-Activity-By-Email

## Overview

This Azure Logic App playbook for Microsoft Sentinel SOAR sends an email to users involved in a security incident, asking them to confirm whether suspicious activity (such as traveling to multiple countries) was performed by them.

### Workflow

1. **Trigger**: Activates when a Microsoft Sentinel incident is created
2. **Extract Accounts**: Gets all account entities from the incident
3. **Send Confirmation Email**: For each user account, sends an approval email with two options:
   - "Yes - I was traveling"
   - "No - I wasn't traveling"
4. **Process Response**:
   - If user confirms traveling → Closes incident as Benign Positive (Suspicious but Expected)
   - If user denies traveling → Adds comment to incident and escalates to SOC team via email

## Prerequisites

- Microsoft Sentinel workspace
- Office 365 connection for sending emails
- Azure Sentinel connection with Managed Identity
- Appropriate permissions:
  - **Microsoft Sentinel Responder** role on the Sentinel workspace (for the Logic App Managed Identity)
  - Office 365 account with mail send permissions

## Deployment

### Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsmedin4%2FSecurity-bits%2Fmain%2FSOAR-Incident-Confirm-Activity-By-Email-Buttons%2Fazuredeploy.json)

### Manual Deployment

```powershell
# Connect to Azure
Connect-AzAccount

# Set variables
$resourceGroupName = "YourResourceGroup"
$location = "eastus"

# Deploy the template
New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroupName `
    -TemplateFile ".\azuredeploy.json" `
    -TemplateParameterFile ".\azuredeploy.parameters.json"
```

## Parameters

| Parameter | Description | Default Value |
|-----------|-------------|---------------|
| `PlaybookName` | Name of the Logic App playbook | `Incident-Confirm-Activity-By-Email` |
| `SOCEmailAddress` | Email address for SOC team escalations | `soc@contoso.com` |
| `OrganizationName` | Organization name displayed in emails | `Contoso` |
| `location` | Azure region for deployment | Resource group location |

## Post-Deployment Configuration

1. **Authorize API Connections**:
   - Navigate to the deployed Logic App in the Azure Portal
   - Go to **API connections**
   - Authorize both the **Azure Sentinel** and **Office 365** connections

2. **Assign Sentinel Permissions**:
   - Get the Logic App's Managed Identity Principal ID from the deployment outputs
   - Assign **Microsoft Sentinel Responder** role to the Managed Identity on your Sentinel workspace

3. **Configure Automation Rule** (Optional):
   - In Microsoft Sentinel, create an automation rule to trigger this playbook for specific incident types (e.g., "Impossible Travel" or "Atypical Travel" alerts)

## Customization

- Modify the email body in the Logic App definition to match your organization's communication style
- Adjust the approval options based on your use case
- Add additional actions based on user response (e.g., disable account, require MFA)

## Version History

| Version | Date | Description |
|---------|------|-------------|
| 1.0.0 | 2026-02-03 | Initial release |
