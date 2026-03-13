using 'main.bicep'

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT', '')
param projectsCount = empty(projectsCountValue) ? null : int(projectsCountValue)

// Parameters for the main Bicep template
var principalIdValue = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param deployerPrincipalId = empty(principalIdValue) ? null : principalIdValue

var groupPrincipalIdValue = readEnvironmentVariable('AZURE_GROUP_PRINCIPAL_ID', '')
param groupPrincipalId = empty(groupPrincipalIdValue) ? null : groupPrincipalIdValue

var studentsInitialsValue = readEnvironmentVariable('STUDENTS_INITIALS', '')
param studentsInitials = empty(studentsInitialsValue) ? null : studentsInitialsValue
