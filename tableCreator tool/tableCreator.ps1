<#
.SYNOPSIS
    Creates a new Sentinel table with the same schema as an existing table, or BYOS (bring-your-own-schema).
    Supports cross-workspace cloning by specifying separate source and destination workspaces.

.DESCRIPTION
    This script queries the schema of an existing Sentinel table and creates a new table with the same schema.
    Alternatively, you can provide a JSON schema file (bring-your-own-schema).
    It supports Analytics, Auxiliary/Data Lake, and Basic table types, and allows for retention settings and conversion of dynamic columns to string for Auxiliary/Data Lake tables.
    The script prompts for any missing parameters and can be run interactively or with command-line arguments.

    Cross-Workspace Support:
    Use -SourceResourceId to read the schema (and optionally retention settings) from a source workspace,
    and -DestinationResourceId to specify where the new table should be created.
    If only -FullResourceId is provided, it is used as both source and destination (original behavior).
    The -CloneRetention switch automatically reads the source table's plan, retention, and total retention
    settings and applies them to the new table (can be overridden with explicit -retention/-totalRetention).

.PARAMETER FullResourceId
    The full resource ID of the Sentinel/Log Analytics Workspace used as BOTH source and destination.
    For cross-workspace scenarios, use -SourceResourceId and -DestinationResourceId instead.
    Resource ID can be found in Log Analytics Workspace > JSON View > Copy button.

.PARAMETER SourceResourceId
    The full resource ID of the SOURCE Sentinel/Log Analytics Workspace to read the schema from.
    If not provided, falls back to -FullResourceId.

.PARAMETER DestinationResourceId
    The full resource ID of the DESTINATION Sentinel/Log Analytics Workspace where the new table will be created.
    If not provided, falls back to -FullResourceId.

.PARAMETER tableName
    The name of the existing table to copy the schema from (e.g., SecurityEvent).

.PARAMETER newTableName
    The name of the new table to be created (e.g., MyNewTable_CL). Remember to include the _CL suffix for custom tables.

.PARAMETER type
    The table type: analytics (default), dl/datalake, aux/auxiliary, or basic. 

.PARAMETER retention
    Retention in days for analytics tables (4-730). If not provided, the workspace default is used.
    When -CloneRetention is used and -retention is not specified, the source table's retention is used.

.PARAMETER totalRetention
    Total retention in days for the table. 
    Allowed values: 4-730 days, 1095 (3 yr), 1460 (4 yr), 1826 (5 yr), 2191 (6 yr), 2556 (7 yr), 2922 (8 yr), 3288 (9 yr), 3653 (10 yr), 4018 (11 yr), 4383 (12 yr).
    When -CloneRetention is used and -totalRetention is not specified, the source table's total retention is used.

.PARAMETER ConvertToString
    For Auxiliary/Data Lake tables, converts dynamic columns to string. 
    PRO TIP: If the copied table has dynamic columns, you may create it initially as Analytics, and then change to Data Lake later. This will preserve the dynamic types.

.PARAMETER CloneRetention
    When specified, reads the source table's plan, retentionInDays, and totalRetentionInDays from the
    Tables API and applies them to the new table. Explicit -type, -retention, and -totalRetention
    parameters take precedence over the cloned values.

.PARAMETER TenantId
    Azure tenant ID. Required only if not running in Azure Cloud Shell.
    Requires the Az PowerShell module installed.

.PARAMETER SchemaFile
    Path to a JSON schema file (bring-your-own-schema). If provided, the schema will be read from this file instead of querying an existing table.

.EXAMPLE
    .\tableCreator.ps1 -tableName MyTable -newTableName MyNewTable_CL -type analytics -retention 180 -totalRetention 365

.EXAMPLE
    .\tableCreator.ps1 -TenantId YOUR_TENANT_ID -FullResourceId /subscriptions/YOUR_SUBSCRIPTION_ID/resourcegroups/YOUR_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/YOUR_WORKSPACE_NAME

.EXAMPLE
    .\tableCreator.ps1 -SchemaFile mySchema.json -newTableName MyNewTable_CL -type datalake

.EXAMPLE
    # Cross-workspace clone: read schema + retention from source, create in destination
    .\tableCreator.ps1 -SourceResourceId <SOURCE_RESOURCE_ID> -DestinationResourceId <DEST_RESOURCE_ID> -tableName SecurityEvent -newTableName SecurityEvent_CL -CloneRetention

.EXAMPLE
    # Cross-workspace clone with type/retention override
    .\tableCreator.ps1 -SourceResourceId <SOURCE_RESOURCE_ID> -DestinationResourceId <DEST_RESOURCE_ID> -tableName SecurityEvent -newTableName SecurityEvent_CL -CloneRetention -type datalake -totalRetention 365

#>

# Define parameters for the script
param (
    [string]$TenantId,
    [string]$tableName,
    [string]$newTableName,
    [string]$type,
    [int]$retention,
    [int]$totalRetention,
    [switch]$ConvertToString,
    [switch]$CloneRetention,                # New: clone retention settings from source table
    [string]$SchemaFile,                    # Path to a JSON schema file (bring-your-own-schema)
    [ValidateScript({
        if ($_ -match '^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/resourcegroups/[a-zA-Z0-9-_]+/providers/microsoft.operationalinsights/workspaces/[a-zA-Z0-9-_]+$') {
            $true
        } else {
            throw "`n'$_' doesn't look like a valid full resource ID.`nExpected format: /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/microsoft.operationalinsights/workspaces/<workspace-name>"
        }
    })]
    [string] $FullResourceId,               # Used as both source and destination when SourceResourceId/DestinationResourceId are not set.
    [ValidateScript({
        if ($_ -match '^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/resourcegroups/[a-zA-Z0-9-_]+/providers/microsoft.operationalinsights/workspaces/[a-zA-Z0-9-_]+$') {
            $true
        } else {
            throw "`n'$_' doesn't look like a valid source resource ID.`nExpected format: /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/microsoft.operationalinsights/workspaces/<workspace-name>"
        }
    })]
    [string] $SourceResourceId,             # Source workspace to read schema (and optionally retention) from.
    [ValidateScript({
        if ($_ -match '^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/resourcegroups/[a-zA-Z0-9-_]+/providers/microsoft.operationalinsights/workspaces/[a-zA-Z0-9-_]+$') {
            $true
        } else {
            throw "`n'$_' doesn't look like a valid destination resource ID.`nExpected format: /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/microsoft.operationalinsights/workspaces/<workspace-name>"
        }
    })]
    [string] $DestinationResourceId         # Destination workspace where the new table will be created.
)

##################################################################################################################
# Resource ID resolution — supports three modes:
#   1. -SourceResourceId + -DestinationResourceId  (cross-workspace)
#   2. -FullResourceId                              (same workspace for both, original behavior)
#   3. Hardcoded $srcResourceId / $dstResourceId below (edit once, reuse)
#
# Priority: explicit params > FullResourceId > hardcoded defaults > interactive prompt

$defaultResourceId = "/subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/YOUR_WORKSPACE_NAME"

$srcResourceId = $defaultResourceId
$dstResourceId = $defaultResourceId

# Apply FullResourceId as a fallback for both if provided
if ($FullResourceId) {
    $srcResourceId = $FullResourceId
    $dstResourceId = $FullResourceId
}

# Override individually when explicit source/destination are given
if ($SourceResourceId) {
    $srcResourceId = $SourceResourceId
}
if ($DestinationResourceId) {
    $dstResourceId = $DestinationResourceId
}
##################################################################################################################

# Immediately read/validate SchemaFile (fail early)
if ($SchemaFile) {
    if (-not (Test-Path -Path $SchemaFile)) {
        Write-Host "[Error] Schema file '$SchemaFile' not found." -ForegroundColor Red
        exit 1
    }

    Write-Host "[Using schema from file: $SchemaFile]" -ForegroundColor Green

    try {
        $raw = Get-Content -Raw -Path $SchemaFile
        $schemaArray = $raw | ConvertFrom-Json
    } catch {
        Write-Host "[Error] Failed to read/parse JSON schema file: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if (-not ($schemaArray -is [System.Array])) {
        Write-Host "[Error] Schema file must contain a JSON array of objects with 'name' and 'type' properties." -ForegroundColor Red
        exit 1
    }

    # Normalize to the same structure the script expects from getschema
    $queryResult = $schemaArray | ForEach-Object {
        [pscustomobject]@{
            ColumnName = $_.name
            ColumnType = $_.type
        }
    }
}
# End SchemaFile handling

# Connect Azure Account, no need to run in Cloud Shell, but you do need the Az module installed. 
if ($TenantId) {
    try {
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop
    }
    catch {
        Write-Host "[Error] Failed to connect to Azure: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Display the banner
Write-Host " +=======================+" -ForegroundColor Green
Write-Host " | tableCreator.ps1 v3.0 |" -ForegroundColor Green
Write-Host " +=======================+" -ForegroundColor Green
Write-Host ""

# Function to repeatedly prompt for input until a valid value is entered
function PromptForInput {
    param (
        [string]$promptMessage
    )

    $inputValue = ""
    while (-not $inputValue) {
        $inputValue = Read-Host -Prompt $promptMessage
        if (-not $inputValue) {
            Write-Host "This value is required. Please provide a valid input."
        }
    }

    return $inputValue
}

# Helper function to validate a resource ID format
function ValidateResourceId {
    param ([string]$id, [string]$label)
    if ($id -notmatch '^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/resourcegroups/[a-zA-Z0-9-_]+/providers/microsoft.operationalinsights/workspaces/[a-zA-Z0-9-_]+$') {
        Write-Host "`n'$id' doesn't look like a valid $label resource id. Please provide the full resource ID in the correct format." -ForegroundColor Red
        Write-Host "(format: /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/microsoft.operationalinsights/workspaces/<workspace-name>)" -ForegroundColor Red
        exit
    }
}

# Check if the sourceResourceId is still the default placeholder value
if ($srcResourceId -eq $defaultResourceId) {
    $srcResourceId = PromptForInput "Enter SOURCE Sentinel Resource Id (workspace to read schema from)"
    ValidateResourceId $srcResourceId "source"
}

# Check if the dstResourceId is still the default placeholder value
if ($dstResourceId -eq $defaultResourceId) {
    # Offer to reuse the source if in same-workspace mode
    $useSame = Read-Host -Prompt "Enter DESTINATION Sentinel Resource Id (or press Enter to use same as source)"
    if (-not $useSame) {
        $dstResourceId = $srcResourceId
    } else {
        $dstResourceId = $useSame
        ValidateResourceId $dstResourceId "destination"
    }
}

# Display workspace info
if ($srcResourceId -eq $dstResourceId) {
    $srcWs = ($srcResourceId -split '/')[-1]
    Write-Host "[Mode: Same-workspace — $srcWs]" -ForegroundColor Cyan
} else {
    $srcWs = ($srcResourceId -split '/')[-1]
    $dstWs = ($dstResourceId -split '/')[-1]
    Write-Host "[Mode: Cross-workspace — Source: $srcWs → Destination: $dstWs]" -ForegroundColor Cyan
}

# Prompt for input if necessary
# If SchemaFile is provided we don't need the source $tableName.
if (-not $SchemaFile) {
    if (-not $tableName) {
        $tableName = PromptForInput "Enter table name to get schema from"
    } 
}

if (-not $newTableName) {
    $newTableName = PromptForInput "Enter new table name to be created with the schema (remember _CL -suffix)"
}

# --- CloneRetention: read source table metadata from the Tables API ---
$clonedType = $null
$clonedRetention = 0
$clonedTotalRetention = 0

if ($CloneRetention -and -not $SchemaFile) {
    Write-Host "[CloneRetention: reading source table '$tableName' settings from Tables API...]"
    $tableApiPath = "$srcResourceId/tables/${tableName}?api-version=2023-01-01-preview"
    $tableResponse = Invoke-AzRestMethod -Path $tableApiPath -Method GET

    if ($tableResponse.StatusCode -eq 200) {
        $tableInfo = $tableResponse.Content | ConvertFrom-Json
        $clonedType = $tableInfo.properties.plan
        $clonedRetention = $tableInfo.properties.retentionInDays
        $clonedTotalRetention = $tableInfo.properties.totalRetentionInDays

        Write-Host "[CloneRetention: Source table plan=$clonedType, retention=$clonedRetention days, totalRetention=$clonedTotalRetention days]" -ForegroundColor Cyan
    } else {
        Write-Host "[Warning] CloneRetention: Failed to read source table metadata (status $($tableResponse.StatusCode)). Falling back to manual settings." -ForegroundColor Yellow
    }
}

# Prompt for table type, defaulting to 'analytics' if not provided
# CloneRetention values are used as defaults when not explicitly overridden
if (-not $type) {
    if ($clonedType) {
        $type = $clonedType
        Write-Host "[Table type inherited from source: $type]" -ForegroundColor Cyan
    } else {
        $type = Read-Host -Prompt "Enter table type (analytics, dl/datalake, aux/auxiliary or basic, or press Enter for default 'analytics')"
    }
}

$datalake = $false

if ($type.ToLower() -eq "datalake" -or $type.ToLower() -eq "dl") {
    $datalake = $true
    $type = "auxiliary"
}

if ($type.ToLower() -eq "aux") { $type = "auxiliary" }

# Define an array of valid types
$validTypes = @("auxiliary", "basic", "analytics")

$type = $type.ToLower()

# If $type is not valid, default it to 'analytics'
if (-not $type -or -not ($validTypes -contains $type)) {
    $type = 'analytics'
    Write-Host "Invalid or no table type provided. Defaulting to 'analytics'."
}

# Prompt for retention values if not provided
# CloneRetention values are used as defaults when not explicitly overridden
if (-not $retention -and $type -eq "analytics") {
    if ($clonedRetention -gt 0) {
        $retention = $clonedRetention
        Write-Host "[Retention inherited from source: $retention days]" -ForegroundColor Cyan
    } else {
        $retention = Read-Host -Prompt "Enter analytics retention in days (4-730) or press Enter for workspace default"
    }
}

if (-not $totalRetention) {
    if ($clonedTotalRetention -gt 0) {
        $totalRetention = $clonedTotalRetention
        Write-Host "[Total retention inherited from source: $totalRetention days]" -ForegroundColor Cyan
    } else {
        if ($type -ne "analytics") {
            Write-Host "Allowed values for total retention: 30-730 days, 1095 (3 yr), 1460 (4 yr), 1826 (5 yr), 2191 (6 yr), 2556 (7 yr), 2922 (8 yr), 3288 (9 yr), 3653 (10 yr), 4018 (11 yr), 4383 (12 yr)"
        } else {
            Write-Host "Allowed values for total retention: $retention-730 days, 1095 (3 yr), 1460 (4 yr), 1826 (5 yr), 2191 (6 yr), 2556 (7 yr), 2922 (8 yr), 3288 (9 yr), 3653 (10 yr), 4018 (11 yr), 4383 (12 yr)"
        }
        $totalRetention = Read-Host -Prompt "Enter total retention in days or press Enter for table default"
    }
}

# Set query to get the schema of the specified table
# If $queryResult is already populated (from SchemaFile), skip querying the workspace.
if ($queryResult) {
    # Schema already loaded from file; nothing to do here.
} else {
    $query = "$tableName | getschema | project ColumnName, ColumnType"

    # Query the workspace to get the schema
    Write-Host "[Querying $tableName table schema from source workspace...]"

    # Construct the request body
    $body = @{
        query = $query
    } | ConvertTo-Json -Depth 2

    $response = Invoke-AzRestMethod -Path "$srcResourceId/query?api-version=2017-10-01" -Method POST  -Payload $body

    # Convert Content from JSON string to PowerShell object
    $data = $response.Content | ConvertFrom-Json

    # Check if the response is successful
    if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 202) {
        Write-Host "[Table schema successfully captured]"
    }
    else {
        # Output error details if the creation failed
        Write-Host "[Error] Failed to query the table '$TableName'. Status code: $($response.StatusCode)" -ForegroundColor Red

        exit
    }

    # do the mapping to queryResult
    $columns = $data.tables[0].columns
    $rows = $data.tables[0].rows

    $queryResult = $rows | ForEach-Object {
        $object = @{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $object[$columns[$i].name] = $_[$i]
        }
        [pscustomobject]$object
    }
}

## Prepare an array to hold names of columns converted to string
$StringList = @()

# Exclude specific columns by name and prepare the columns for tableParams
$columns = $queryResult | Where-Object {
    $_.ColumnName -notin @("TenantId", "Type", "Id", "MG")
} | ForEach-Object {

    ## Aux/datalake uses column type boolean istead of bool
    if ($type -eq "auxiliary" -and $_.ColumnType -eq "bool") { 
        $_.ColumnType = "boolean" 
    }

    # Check if the column type is dynamic and if ConvertToString is set
    if ($type -eq "auxiliary" -and $_.ColumnType -eq "dynamic") {
        if ($ConvertToString) { 

            $StringList += $_.ColumnName  # Add to array for later processing

            $_.ColumnName = $_.ColumnName + "_str"
            $_.ColumnType = "string"

            #Write-Host "[DEBUG - CONVERTED $($_.ColumnName) - $($_.ColumnType)"        
        } 
    }

    # Check if the table name is "SecurityEvent" and specific columns which are type guid. Getschema fails to report these properly, so it needs some manual intervention.
    if ($_.ColumnName -in @("InterfaceUuid", "LogonGuid", "SourceComputerId", "SubcategoryGuid", "TargetLogonGuid") -and $tableName -eq "SecurityEvent") {
        $_.ColumnType = "guid"
    }
    # Check if the table name is "SigninLogs" and specific columns which are type guid. Getschema fails to report these properly, so it needs some manual intervention.
    if ($_.ColumnName -in @("OriginalRequestId") -and $tableName -eq "SigninLogs") {
        $_.ColumnType = "guid"
    }

     ## Aux do not support dynamic tables
    if ($type -eq "auxiliary" -and $_.ColumnType -eq "dynamic" -and !($ConvertToString)) {

        # Log the skipping message
        Write-Host "[SKIPPING $($_.ColumnName) due to Dynamic type which is not supported by Data lake/Auxiliary table, use -ConvertToString to convert it to String]" -ForegroundColor Yellow

    } else {
        # Include the column in the result
        @{
            "name" = $_.ColumnName
            "type" = $_.ColumnType
        }
        #Write-Host "[DEBUG - INCL $($_.ColumnName) - $($_.ColumnType)"

    }

}

# Construct the base tableParams for the new table
$tableParams = @{
    "properties" = @{
        "schema" = @{
            "name"    = $newTableName
            "columns" = $columns
        }
    }
}

# Normalize the type input and add details if set
switch ($type.ToLower()) {
    "auxiliary" {
        $tableParams.properties.plan = "Auxiliary"

        if ($datalake) {
            Write-Host "[Plan set to Data Lake]"
        } else {
            Write-Host "[Plan set to Auxiliary]"
            Write-Host "[Interactive retention is set to 30 days]"
        }

    }
    "analytics" {
        $tableParams.properties.plan = "Analytics"
        Write-Host "[Plan set to Analytics]"
        if ($retention -ge 4 -and $retention -le 730) {
            $tableParams.properties.retentionInDays = $retention
            Write-Host "[Analytics retention set to $retention days]"
        }
    }
    "basic" {
        $tableParams.properties.plan = "Basic"
        Write-Host "[Plan set to Basic]"
        Write-Host "[Interactive retention is set to 30 days]"
    }
    default {
        Write-Host "Invalid type provided. Using default 'analytics'."
        $tableParams.properties.plan = "Analytics"
        Write-Host "[Plan set to Analytics]"
        if ($retention -ge 4 -and $retention -le 730) {
            $tableParams.properties.retentionInDays = $retention
            Write-Host "[Analytics retention set to $retention days]"
        }
    }
}

# Set totalRetentionInDays based on the input condition
if ($totalRetention -ge 4 -and $totalRetention -le 4383) { 
    $tableParams.properties.totalRetentionInDays = $totalRetention 
    Write-Host "[Total retention set to $totalRetention days]"    
} 

# Convert tableParams to JSON for the API call
$tableParamsJson = $tableParams | ConvertTo-Json -Depth 10
#Write-Host "$tableParamsJson"

Write-Host "[Initiating new table $newTableName creation (or updating if it exists) in destination workspace]"

# Create the new Sentinel table in the DESTINATION workspace
$response = Invoke-AzRestMethod -Path "$dstResourceId/tables/${newTableName}?api-version=2023-01-01-preview" -Method PUT -Payload $tableParamsJson

# Check if the response is successful
if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 202) {
    Write-Host "[Success] Table '$newTableName' created successfully with status code: $($response.StatusCode)" -ForegroundColor Green
}
else {
    # Output error details if the creation failed
    Write-Host "[Error] Failed to create table '$newTableName'. Status code: $($response.StatusCode)" -ForegroundColor Red
    
    # Convert Content from JSON string to PowerShell object
    $content = $response.Content | ConvertFrom-Json

    # Check if the error object is present and output the message
    if ($content.error) {
        Write-Host "[Error] Code: $($content.error.code)" -ForegroundColor Red
        Write-Host "[Error] Message: $($content.error.message)" -ForegroundColor Red
    }
    else {
        Write-Host "[Error] No detailed error information available." -ForegroundColor Red
    }
}

# Check if there are any columns to converted to string and output the transformation KQL
if ($StringList) {
    $extendParts = ""
    foreach ($col in $StringList) {
        $newCol = $col + "_str"
        $extendParts += "$newCol = tostring($col), "
    }
    $transformKql = "source | extend $extendParts"
    $transformKql = $transformKql.Substring(0, $transformKql.Length - 2)
    Write-Host ""
    Write-Host "NOTICE: There were Dynamic columns in the table and they were converted to String (as requested). Please include this in the DCR:" -ForegroundColor Yellow
    Write-Host "`"transformKql`": `"$transformKql`"" -ForegroundColor Yellow
}
