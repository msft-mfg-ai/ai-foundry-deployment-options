#!/usr/bin/env python3
"""Create Azure AI Search index and upload data using managed identity."""

import argparse
import csv
import io
import httpx
from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    SearchIndex,
    SearchField,
    SearchFieldDataType,
    SearchableField,
    SimpleField,
)


def create_book_index(endpoint: str, index_name: str) -> None:
    """Create or update the books search index."""
    credential = DefaultAzureCredential()
    client = SearchIndexClient(endpoint=endpoint, credential=credential)

    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True),
        SearchableField(name="goodreads_book_id", type=SearchFieldDataType.String, filterable=True),
        SearchableField(name="best_book_id", type=SearchFieldDataType.String),
        SearchableField(name="work_id", type=SearchFieldDataType.String),
        SimpleField(name="books_count", type=SearchFieldDataType.Int32, filterable=True),
        SearchableField(name="isbn", type=SearchFieldDataType.String, filterable=True),
        SearchableField(name="isbn13", type=SearchFieldDataType.String),
        SearchableField(name="authors", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SimpleField(name="original_publication_year", type=SearchFieldDataType.Double, filterable=True, facetable=True),
        SearchableField(name="original_title", type=SearchFieldDataType.String),
        SearchableField(name="title", type=SearchFieldDataType.String),
        SearchableField(name="language_code", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SimpleField(name="average_rating", type=SearchFieldDataType.Double, filterable=True, sortable=True),
        SimpleField(name="ratings_count", type=SearchFieldDataType.Int32, filterable=True, sortable=True),
        SimpleField(name="work_ratings_count", type=SearchFieldDataType.Int32),
        SimpleField(name="work_text_reviews_count", type=SearchFieldDataType.Int32),
        SimpleField(name="ratings_1", type=SearchFieldDataType.Int32),
        SimpleField(name="ratings_2", type=SearchFieldDataType.Int32),
        SimpleField(name="ratings_3", type=SearchFieldDataType.Int32),
        SimpleField(name="ratings_4", type=SearchFieldDataType.Int32),
        SimpleField(name="ratings_5", type=SearchFieldDataType.Int32),
        SearchableField(name="image_url", type=SearchFieldDataType.String),
        SearchableField(name="small_image_url", type=SearchFieldDataType.String),
    ]

    index = SearchIndex(name=index_name, fields=fields)
    result = client.create_or_update_index(index)
    print(f"Created index: {result.name}")


def upload_books(endpoint: str, index_name: str, books_url: str) -> None:
    """Download CSV and upload documents to the index."""
    credential = DefaultAzureCredential()
    client = SearchClient(endpoint=endpoint, index_name=index_name, credential=credential)

    print("Downloading data file...")
    response = httpx.get(books_url)
    response.raise_for_status()

    print("Parsing CSV data...")
    # Replace 'book_id' with 'id' for the key field
    csv_text = response.text.replace("book_id", "id", 1)
    reader = csv.DictReader(io.StringIO(csv_text))
    
    documents = []
    for row in reader:
        # Convert numeric fields, handle empty strings
        for field in ["books_count", "ratings_count", "work_ratings_count", 
                      "work_text_reviews_count", "ratings_1", "ratings_2", 
                      "ratings_3", "ratings_4", "ratings_5"]:
            if row.get(field) and row[field].strip():
                row[field] = int(row[field])
            else:
                row[field] = None
        for field in ["average_rating", "original_publication_year"]:
            if row.get(field) and row[field].strip():
                row[field] = float(row[field])
            else:
                row[field] = None
        documents.append(row)

    print(f"Uploading {len(documents)} documents...")
    result = client.upload_documents(documents)
    succeeded = sum(1 for r in result if r.succeeded)
    print(f"Uploaded {succeeded}/{len(documents)} documents")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Create Azure AI Search index using managed identity")
    parser.add_argument("endpoint", help="Azure Search endpoint URL")
    parser.add_argument("--index", default="good-books", help="Index name (default: good-books)")
    parser.add_argument("--books-url", 
                        default="https://raw.githubusercontent.com/Azure-Samples/azure-search-sample-data/main/good-books/books.csv",
                        help="URL to books CSV file")
    args = parser.parse_args()

    create_book_index(args.endpoint, args.index)
    upload_books(args.endpoint, args.index, args.books_url)
