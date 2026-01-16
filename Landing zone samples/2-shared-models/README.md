# About

Deploy AI Foundry with a link to another AI Foundry in the same region but different subscription hosting AI Models.

## Infrastructure

Deployed using [Bicep](../../options-infra/foundry-external-ai/main.bicep).

## Results

Chat playground works with external AI Foundry hosting models.

**Agent Service works**
![Agent Service](./foundry-working-0.png)

Without any models deployed

![No models](./foundry-working-1.png)

With connection to AI Foundry in another subscription (same region).

![Connection](./foundry-working-2.png)

> [!WARNING]
> Chat playground doesn't work
> ![Chat Playground](./foundry-working-3.png)