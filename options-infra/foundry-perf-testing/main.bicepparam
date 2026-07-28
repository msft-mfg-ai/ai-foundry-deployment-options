using 'main.bicep'

var chatModelValue = readEnvironmentVariable('CHAT_MODEL', '')
param chatModelName = empty(chatModelValue) ? 'gpt-5-mini' : chatModelValue

var chatModelVersionValue = readEnvironmentVariable('CHAT_MODEL_VERSION', '')
param chatModelVersion = empty(chatModelVersionValue) ? '2025-08-07' : chatModelVersionValue

var chatModelCapacityValue = readEnvironmentVariable('CHAT_MODEL_CAPACITY', '')
param chatModelCapacity = empty(chatModelCapacityValue) ? 50 : int(chatModelCapacityValue)
