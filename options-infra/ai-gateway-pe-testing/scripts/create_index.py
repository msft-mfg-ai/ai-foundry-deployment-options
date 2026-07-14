#!/usr/bin/env python3
"""Create the byom-test AI Search index and seed a handful of documents.

Used by the ai-gateway-pe-testing postprovision hook so the
`tool-azure-ai-search` BYOM feature has something to query.
"""

import argparse
import sys

from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    SearchableField,
    SearchFieldDataType,
    SearchIndex,
    SimpleField,
)


DOCS = [
    {
        "id": "1",
        "title": "Azure AI Foundry",
        "content": "Azure AI Foundry is a unified platform for building, evaluating, and operating agents on Azure.",
    },
    {
        "id": "2",
        "title": "Bring Your Own Model",
        "content": "BYOM lets Foundry agents call models fronted by an API Management gateway instead of native Foundry deployments.",
    },
    {
        "id": "3",
        "title": "Private networking",
        "content": "APIM with a private endpoint keeps agent-to-model traffic on the virtual network end to end.",
    },
]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", required=True, help="https://<search>.search.windows.net")
    p.add_argument("--index", default="byom-test")
    args = p.parse_args()

    cred = DefaultAzureCredential()

    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True),
        SearchableField(name="title", type=SearchFieldDataType.String),
        SearchableField(name="content", type=SearchFieldDataType.String),
    ]

    idx_client = SearchIndexClient(endpoint=args.endpoint, credential=cred)
    idx_client.create_or_update_index(SearchIndex(name=args.index, fields=fields))
    print(f"index '{args.index}' ready on {args.endpoint}")

    doc_client = SearchClient(endpoint=args.endpoint, index_name=args.index, credential=cred)
    result = doc_client.upload_documents(documents=DOCS)
    print(f"uploaded {sum(1 for r in result if r.succeeded)}/{len(DOCS)} documents")
    return 0


if __name__ == "__main__":
    sys.exit(main())
