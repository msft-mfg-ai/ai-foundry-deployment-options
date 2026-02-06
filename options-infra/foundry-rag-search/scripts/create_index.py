#!/usr/bin/env python3
"""Create Azure AI Search index with PDF document processing pipeline.

This script:
1. Uploads PDF files to Azure Blob Storage
2. Extracts text and tables using Azure AI Document Intelligence
3. Extracts images and generates descriptions using Azure OpenAI
4. Indexes all content in Azure AI Search
"""

import argparse
import base64
import hashlib
import json
import logging
import re
import sys
from pathlib import Path
from typing import Generator

from tenacity import (
    retry,
    stop_after_attempt,
    wait_exponential,
    retry_if_exception_type,
    before_sleep_log,
)
from openai import RateLimitError, APIError, APIConnectionError, APITimeoutError

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContainerClient, ContentSettings
from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.ai.documentintelligence.models import DocumentContentFormat
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    SearchIndex,
    SearchField,
    SearchFieldDataType,
    SearchableField,
    SimpleField,
    VectorSearch,
    HnswAlgorithmConfiguration,
    VectorSearchProfile,
    AzureOpenAIVectorizer,
    AzureOpenAIVectorizerParameters,
    SemanticConfiguration,
    SemanticField,
    SemanticPrioritizedFields,
    SemanticSearch,
)
from openai import AzureOpenAI

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

# Retry configuration for transient errors
RETRY_ATTEMPTS = 3
RETRY_MIN_WAIT = 2  # seconds
RETRY_MAX_WAIT = 30  # seconds


@retry(
    stop=stop_after_attempt(RETRY_ATTEMPTS),
    wait=wait_exponential(multiplier=1, min=RETRY_MIN_WAIT, max=RETRY_MAX_WAIT),
    retry=retry_if_exception_type((RateLimitError, APIConnectionError, APITimeoutError)),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _call_embedding_api(
    openai_client: AzureOpenAI,
    text: str,
    deployment_name: str,
) -> list[float]:
    """Internal function to call embedding API with retry logic."""
    response = openai_client.embeddings.create(
        model=deployment_name,
        input=text,
    )
    return response.data[0].embedding


def generate_embedding(
    openai_client: AzureOpenAI,
    text: str,
    deployment_name: str,
) -> list[float] | None:
    """Generate embedding vector for text using Azure OpenAI or Cohere."""
    if not text or not text.strip():
        return None

    try:
        # Truncate text if too long (most models have 8192 token limit)
        max_chars = 30000  # Approximate safe limit
        if len(text) > max_chars:
            logger.warning(
                f"Text truncated from {len(text)} to {max_chars} characters for embedding generation"
            )
            text = text[:max_chars]

        return _call_embedding_api(openai_client, text, deployment_name)
    except RateLimitError as e:
        logger.error(
            f"Rate limit exceeded for embedding generation after {RETRY_ATTEMPTS} retries: {e}"
        )
        return None
    except (APIConnectionError, APITimeoutError) as e:
        logger.error(
            f"Connection/timeout error for embedding after {RETRY_ATTEMPTS} retries: {e}"
        )
        return None
    except APIError as e:
        logger.error(
            f"API error generating embedding (status={e.status_code}): {e.message}"
        )
        return None
    except Exception as e:
        logger.exception(f"Unexpected error generating embedding: {type(e).__name__}: {e}")
        return None


@retry(
    stop=stop_after_attempt(RETRY_ATTEMPTS),
    wait=wait_exponential(multiplier=1, min=RETRY_MIN_WAIT, max=RETRY_MAX_WAIT),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def create_document_index(
    endpoint: str,
    index_name: str,
    use_vectors: bool = False,
    vector_dimensions: int = 1536,
    embedding_endpoint: str | None = None,
    embedding_deployment: str | None = None,
    embedding_model_name: str | None = None,
) -> None:
    """Create or update the document search index with support for PDFs.

    Args:
        endpoint: Azure AI Search endpoint URL
        index_name: Name of the search index
        use_vectors: Enable vector search
        vector_dimensions: Dimensions for vector field
        embedding_endpoint: Azure OpenAI/Cohere endpoint for query vectorization
        embedding_deployment: Deployment name for embeddings
        embedding_model_name: Model name (e.g., text-embedding-3-small, embed-v-4-0)
    """
    logger.info(f"Creating/updating search index '{index_name}' at {endpoint}")
    credential = DefaultAzureCredential()
    client = SearchIndexClient(endpoint=endpoint, credential=credential)

    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True),
        SimpleField(
            name="document_id",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        SearchableField(
            name="file_name", type=SearchFieldDataType.String, filterable=True
        ),
        SimpleField(name="file_path", type=SearchFieldDataType.String),
        SimpleField(name="blob_url", type=SearchFieldDataType.String),
        SimpleField(
            name="page_number",
            type=SearchFieldDataType.Int32,
            filterable=True,
            sortable=True,
        ),
        SimpleField(name="chunk_index", type=SearchFieldDataType.Int32, sortable=True),
        SearchableField(
            name="chunk_type",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        SearchableField(name="content", type=SearchFieldDataType.String),
        SearchableField(name="content_markdown", type=SearchFieldDataType.String),
        SearchableField(name="table_markdown", type=SearchFieldDataType.String),
        SearchableField(name="image_description", type=SearchFieldDataType.String),
        SimpleField(name="image_base64", type=SearchFieldDataType.String),
        SearchableField(name="metadata", type=SearchFieldDataType.String),
        SearchableField(
            name="citation",
            type=SearchFieldDataType.String,
            filterable=False,
        ),  # Combined citation: "[file_name](blob_url) - Page N"
        SimpleField(
            name="created_at",
            type=SearchFieldDataType.DateTimeOffset,
            filterable=True,
            sortable=True,
        ),
    ]

    vector_search = None
    if use_vectors:
        # Primary vector field - used by Azure AI Foundry Search tool
        fields.append(
            SearchField(
                name="content_vector",
                type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
                searchable=True,
                vector_search_dimensions=vector_dimensions,
                vector_search_profile_name="vector-profile",
            )
        )
        # Secondary vector for table content (optional, improves table search)
        fields.append(
            SearchField(
                name="table_vector",
                type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
                searchable=True,
                vector_search_dimensions=vector_dimensions,
                vector_search_profile_name="vector-profile",
            )
        )
        # Secondary vector for image descriptions (optional, improves image search)
        fields.append(
            SearchField(
                name="image_vector",
                type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
                searchable=True,
                vector_search_dimensions=vector_dimensions,
                vector_search_profile_name="vector-profile",
            )
        )

        # Configure vectorizer for query-time embedding
        vectorizers = []
        if embedding_endpoint and embedding_deployment:
            vectorizers.append(
                AzureOpenAIVectorizer(
                    vectorizer_name="text-vectorizer",
                    parameters=AzureOpenAIVectorizerParameters(
                        resource_url=embedding_endpoint,
                        deployment_name=embedding_deployment,
                        model_name=embedding_model_name or embedding_deployment,
                    ),
                )
            )
            logger.info(
                f"Vectorizer configured: {embedding_deployment} at {embedding_endpoint}"
            )

        vector_search = VectorSearch(
            algorithms=[HnswAlgorithmConfiguration(name="hnsw-algorithm")],
            profiles=[
                VectorSearchProfile(
                    name="vector-profile",
                    algorithm_configuration_name="hnsw-algorithm",
                    vectorizer_name="text-vectorizer" if vectorizers else None,
                )
            ],
            vectorizers=vectorizers if vectorizers else None,
        )
        logger.info(f"Vector search enabled with {vector_dimensions} dimensions")

    # Configure semantic search for better ranking
    # NOTE: Semantic ranker must be enabled on your Azure AI Search resource for this to work
    # Azure Portal -> AI Search -> Settings -> Semantic ranker -> Enable (Free: 1000 queries/month)
    semantic_config = SemanticConfiguration(
        name="semantic-config",
        prioritized_fields=SemanticPrioritizedFields(
            content_fields=[
                SemanticField(field_name="content"),
                SemanticField(field_name="content_markdown"),
                SemanticField(field_name="table_markdown"),
                SemanticField(field_name="image_description"),
            ],
            title_field=SemanticField(field_name="file_name"),
            keywords_fields=[SemanticField(field_name="chunk_type")],
        ),
    )
    semantic_search = SemanticSearch(
        configurations=[semantic_config],
        default_configuration_name="semantic-config",  # Set as default for queries
    )

    index = SearchIndex(
        name=index_name,
        fields=fields,
        vector_search=vector_search,
        semantic_search=semantic_search,
    )
    result = client.create_or_update_index(index)
    logger.info(f"Successfully created/updated index: {result.name}")


@retry(
    stop=stop_after_attempt(RETRY_ATTEMPTS),
    wait=wait_exponential(multiplier=1, min=RETRY_MIN_WAIT, max=RETRY_MAX_WAIT),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def upload_pdf_to_blob(
    container_client: ContainerClient,
    file_path: Path,
    prefix: str = "documents",
) -> str:
    """Upload a PDF file to blob storage and return the blob URL."""
    blob_name = f"{prefix}/{file_path.name}"
    blob_client = container_client.get_blob_client(blob_name)

    logger.debug(f"Uploading {file_path.name} to blob storage...")
    with open(file_path, "rb") as f:
        blob_client.upload_blob(
            f,
            overwrite=True,
            content_settings=ContentSettings(content_type="application/pdf"),
        )

    logger.info(f"Uploaded: {file_path.name} -> {blob_name}")
    return blob_client.url


@retry(
    stop=stop_after_attempt(RETRY_ATTEMPTS),
    wait=wait_exponential(multiplier=1, min=RETRY_MIN_WAIT, max=RETRY_MAX_WAIT),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def extract_document_content(
    doc_intelligence_client: DocumentIntelligenceClient,
    file_path: Path,
) -> dict:
    """Extract text, tables, and figures from a PDF using Document Intelligence."""
    logger.info(f"Analyzing document with Document Intelligence: {file_path.name}")

    with open(file_path, "rb") as f:
        pdf_bytes = f.read()
        logger.debug(f"Document size: {len(pdf_bytes)} bytes")
        poller = doc_intelligence_client.begin_analyze_document(
            model_id="prebuilt-layout",
            body=pdf_bytes,
            output_content_format=DocumentContentFormat.MARKDOWN,
        )

    result = poller.result()
    logger.debug(f"Document analysis complete: {len(result.pages) if result.pages else 0} pages")

    extracted = {
        "content": result.content,
        "pages": [],
        "tables": [],
        "figures": [],
    }

    # Extract page-level content
    if result.pages:
        for page in result.pages:
            page_data = {
                "page_number": page.page_number,
                "width": page.width,
                "height": page.height,
                "lines": [],
            }
            if page.lines:
                for line in page.lines:
                    page_data["lines"].append(line.content)
            extracted["pages"].append(page_data)

    # Extract tables with markdown formatting
    if result.tables:
        for idx, table in enumerate(result.tables):
            table_md = convert_table_to_markdown(table)
            page_num = (
                table.bounding_regions[0].page_number if table.bounding_regions else 1
            )
            extracted["tables"].append(
                {
                    "index": idx,
                    "page_number": page_num,
                    "row_count": table.row_count,
                    "column_count": table.column_count,
                    "markdown": table_md,
                }
            )

    # Extract figures/images
    if hasattr(result, "figures") and result.figures:
        for idx, figure in enumerate(result.figures):
            page_num = (
                figure.bounding_regions[0].page_number if figure.bounding_regions else 1
            )
            extracted["figures"].append(
                {
                    "index": idx,
                    "page_number": page_num,
                    "caption": figure.caption.content if figure.caption else None,
                    "bounding_box": (
                        figure.bounding_regions[0].polygon
                        if figure.bounding_regions
                        else None
                    ),
                }
            )

    return extracted


def convert_table_to_markdown(table) -> str:
    """Convert a Document Intelligence table to markdown format."""
    if not table.cells:
        return ""

    # Build a grid
    grid = {}
    for cell in table.cells:
        row_idx = cell.row_index
        col_idx = cell.column_index
        grid[(row_idx, col_idx)] = cell.content or ""

    # Generate markdown
    md_lines = []
    for row in range(table.row_count):
        row_cells = [grid.get((row, col), "") for col in range(table.column_count)]
        md_lines.append("| " + " | ".join(row_cells) + " |")
        if row == 0:
            md_lines.append("| " + " | ".join(["---"] * table.column_count) + " |")

    return "\n".join(md_lines)


def extract_images_from_pdf(file_path: Path) -> list[dict]:
    """Extract images from PDF using PyMuPDF (fitz)."""
    try:
        import fitz  # PyMuPDF
    except ImportError:
        logger.warning("PyMuPDF not installed. Skipping image extraction. Install with: pip install pymupdf")
        return []

    images = []
    doc = fitz.open(file_path)

    for page_num, page in enumerate(doc, start=1):
        image_list = page.get_images()
        for img_idx, img in enumerate(image_list):
            xref = img[0]
            base_image = doc.extract_image(xref)
            if base_image:
                image_data = base_image["image"]
                image_ext = base_image["ext"]
                images.append(
                    {
                        "page_number": page_num,
                        "index": img_idx,
                        "extension": image_ext,
                        "base64": base64.b64encode(image_data).decode("utf-8"),
                        "size": len(image_data),
                    }
                )

    doc.close()
    return images


@retry(
    stop=stop_after_attempt(RETRY_ATTEMPTS),
    wait=wait_exponential(multiplier=1, min=RETRY_MIN_WAIT, max=RETRY_MAX_WAIT),
    retry=retry_if_exception_type((RateLimitError, APIConnectionError, APITimeoutError)),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _call_vision_api(
    openai_client: AzureOpenAI,
    mime_type: str,
    image_base64: str,
    deployment_name: str,
) -> str:
    """Internal function to call vision API with retry logic."""
    response = openai_client.chat.completions.create(
        model=deployment_name,
        messages=[
            {
                "role": "system",
                "content": "You are an expert at analyzing images and providing detailed, accurate descriptions. Focus on key information, data, charts, diagrams, or any text visible in the image.",
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "Please describe this image in detail. If it contains a chart, graph, or diagram, explain what it shows. If it contains text, transcribe the key information.",
                    },
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:{mime_type};base64,{image_base64}",
                            "detail": "high",
                        },
                    },
                ],
            },
        ],
        max_tokens=1000,
    )
    return response.choices[0].message.content


def generate_image_description(
    openai_client: AzureOpenAI,
    image_base64: str,
    image_ext: str,
    deployment_name: str,
    context: str = "",
) -> str:
    """Generate a description for an image using Azure OpenAI GPT-4 Vision."""
    mime_type = f"image/{image_ext}" if image_ext != "jpg" else "image/jpeg"

    try:
        result = _call_vision_api(openai_client, mime_type, image_base64, deployment_name)
        # Check for empty response (API succeeded but returned no content)
        if not result or not result.strip():
            logger.warning(
                f"Empty response from vision API. Context: {context}. "
                "The model may have refused to describe the image or encountered content filtering."
            )
            return ""
        return result
    except RateLimitError as e:
        logger.error(
            f"Rate limit exceeded for image description after {RETRY_ATTEMPTS} retries. "
            f"Context: {context}. Error: {e}"
        )
        return ""
    except (APIConnectionError, APITimeoutError) as e:
        logger.error(
            f"Connection/timeout error for image description after {RETRY_ATTEMPTS} retries. "
            f"Context: {context}. Error: {e}"
        )
        return ""
    except APIError as e:
        logger.error(
            f"API error generating image description (status={e.status_code}). "
            f"Context: {context}. Message: {e.message}"
        )
        return ""
    except Exception as e:
        logger.exception(
            f"Unexpected error generating image description. "
            f"Context: {context}. Error: {type(e).__name__}: {e}"
        )
        return ""


def chunk_content(
    content: str, chunk_size: int = 2000, overlap: int = 200
) -> Generator[tuple[int, str], None, None]:
    """Split content into overlapping chunks."""
    if not content:
        yield 0, ""
        return

    # Split by paragraphs first
    paragraphs = re.split(r"\n\s*\n", content)
    current_chunk = ""
    chunk_idx = 0

    for para in paragraphs:
        if len(current_chunk) + len(para) <= chunk_size:
            current_chunk += para + "\n\n"
        else:
            if current_chunk:
                yield chunk_idx, current_chunk.strip()
                chunk_idx += 1
                # Keep overlap
                overlap_text = (
                    current_chunk[-overlap:]
                    if len(current_chunk) > overlap
                    else current_chunk
                )
                current_chunk = overlap_text + para + "\n\n"
            else:
                # Single paragraph larger than chunk_size
                for i in range(0, len(para), chunk_size - overlap):
                    yield chunk_idx, para[i : i + chunk_size]
                    chunk_idx += 1
                current_chunk = ""

    if current_chunk.strip():
        yield chunk_idx, current_chunk.strip()


def generate_document_id(file_path: Path) -> str:
    """Generate a unique document ID from file path."""
    return hashlib.md5(str(file_path).encode()).hexdigest()[:16]


def process_pdf(
    file_path: Path,
    container_client: ContainerClient,
    doc_intelligence_client: DocumentIntelligenceClient,
    openai_client: AzureOpenAI | None,
    openai_deployment: str | None,
    embedding_client: AzureOpenAI | None = None,
    embedding_deployment: str | None = None,
    include_images: bool = True,
) -> list[dict]:
    """Process a single PDF and return search documents."""
    documents = []
    document_id = generate_document_id(file_path)

    # Upload to blob storage
    blob_url = upload_pdf_to_blob(container_client, file_path)

    # Extract content using Document Intelligence
    extracted = extract_document_content(doc_intelligence_client, file_path)

    # Process main content chunks
    for chunk_idx, chunk_content_text in chunk_content(extracted["content"]):
        doc = {
            "id": f"{document_id}-content-{chunk_idx}",
            "document_id": document_id,
            "file_name": file_path.name,
            "file_path": str(file_path),
            "blob_url": blob_url,
            "page_number": 1,  # Content spans multiple pages
            "chunk_index": chunk_idx,
            "chunk_type": "content",
            "content": chunk_content_text,
            "content_markdown": chunk_content_text,
            "table_markdown": None,
            "image_description": None,
            "image_base64": None,
            "metadata": json.dumps(
                {"source": "document_intelligence", "format": "markdown"}
            ),
            "citation": f"[{file_path.name}]({blob_url})",
            "created_at": None,  # Will be set by Search
        }
        # Generate embedding if enabled (stored in primary content_vector for Foundry compatibility)
        if embedding_client and embedding_deployment:
            embedding = generate_embedding(
                embedding_client, chunk_content_text, embedding_deployment
            )
            if embedding:
                doc["content_vector"] = embedding
                # Note: table_vector and image_vector are omitted (not set to None)
                # because Azure AI Search doesn't allow null values for vector fields
        documents.append(doc)

    # Process tables as separate documents
    for table in extracted["tables"]:
        page_num = table["page_number"]
        doc = {
            "id": f"{document_id}-table-{table['index']}",
            "document_id": document_id,
            "file_name": file_path.name,
            "file_path": str(file_path),
            "blob_url": blob_url,
            "page_number": page_num,
            "chunk_index": table["index"],
            "chunk_type": "table",
            "content": table["markdown"],
            "content_markdown": None,
            "table_markdown": table["markdown"],
            "image_description": None,
            "image_base64": None,
            "metadata": json.dumps(
                {
                    "source": "document_intelligence",
                    "rows": table["row_count"],
                    "columns": table["column_count"],
                }
            ),
            "citation": f"[{file_path.name}]({blob_url}) - Page {page_num}",
            "created_at": None,
        }
        # Generate embedding for table content (dual-stored in content_vector for Foundry + table_vector for specialized queries)
        if embedding_client and embedding_deployment:
            embedding = generate_embedding(
                embedding_client, table["markdown"], embedding_deployment
            )
            if embedding:
                doc["content_vector"] = (
                    embedding  # Primary vector for Foundry compatibility
                )
                doc["table_vector"] = embedding  # Specialized table vector
                # Note: image_vector is omitted (not set to None)
        documents.append(doc)

    # Process images if enabled
    if include_images and openai_client and openai_deployment:
        images = extract_images_from_pdf(file_path)
        for img in images:
            # Skip very small images (likely icons or artifacts)
            if img["size"] < 5000:
                continue

            image_context = f"file={file_path.name}, page={img['page_number']}, index={img['index']}"
            description = generate_image_description(
                openai_client, img["base64"], img["extension"], openai_deployment,
                context=image_context
            )
            if description:
                logger.info(
                    f"🖼️  Image description generated for '{file_path.name}' - Page {img['page_number']}: "
                    f"{description[:100]}..." if len(description) > 100 else description
                )
            else:
                logger.warning(
                    f"⚠️  No description generated for image in '{file_path.name}' - Page {img['page_number']}"
                )

            doc = {
                "id": f"{document_id}-image-p{img['page_number']}-{img['index']}",
                "document_id": document_id,
                "file_name": file_path.name,
                "file_path": str(file_path),
                "blob_url": blob_url,
                "page_number": img["page_number"],
                "chunk_index": img["index"],
                "chunk_type": "image",
                "content": description,
                "content_markdown": None,
                "table_markdown": None,
                "image_description": description,
                "image_base64": (
                    img["base64"][:1000] + "..."
                    if len(img["base64"]) > 1000
                    else img["base64"]
                ),
                "metadata": json.dumps(
                    {
                        "source": "image_extraction",
                        "extension": img["extension"],
                        "size": img["size"],
                    }
                ),
                "citation": f"[{file_path.name}]({blob_url}) - Page {img['page_number']}",
                "created_at": None,
            }
            # Generate embedding for image description (dual-stored in content_vector for Foundry + image_vector for specialized queries)
            if embedding_client and embedding_deployment and description:
                embedding = generate_embedding(
                    embedding_client, description, embedding_deployment
                )
                if embedding:
                    doc["content_vector"] = (
                        embedding  # Primary vector for Foundry compatibility
                    )
                    doc["image_vector"] = embedding  # Specialized image vector
                    # Note: table_vector is omitted (not set to None)
            documents.append(doc)

    return documents


@retry(
    stop=stop_after_attempt(RETRY_ATTEMPTS),
    wait=wait_exponential(multiplier=1, min=RETRY_MIN_WAIT, max=RETRY_MAX_WAIT),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _upload_batch(client: SearchClient, batch: list[dict], batch_num: int) -> int:
    """Upload a single batch with retry logic."""
    result = client.upload_documents(batch)
    succeeded = sum(1 for r in result if r.succeeded)
    failed = [r for r in result if not r.succeeded]
    
    if failed:
        for f in failed[:5]:  # Log first 5 failures
            logger.warning(
                f"Failed to upload document '{f.key}': {f.error_message}"
            )
        if len(failed) > 5:
            logger.warning(f"... and {len(failed) - 5} more failures in batch {batch_num}")
    
    return succeeded


def upload_documents(endpoint: str, index_name: str, documents: list[dict]) -> None:
    """Upload documents to the search index."""
    credential = DefaultAzureCredential()
    client = SearchClient(
        endpoint=endpoint, index_name=index_name, credential=credential
    )

    # Upload in batches
    batch_size = 100
    total_succeeded = 0
    total_failed = 0

    logger.info(f"Uploading {len(documents)} documents in batches of {batch_size}...")
    
    for i in range(0, len(documents), batch_size):
        batch = documents[i : i + batch_size]
        batch_num = i // batch_size + 1
        try:
            succeeded = _upload_batch(client, batch, batch_num)
            total_succeeded += succeeded
            total_failed += len(batch) - succeeded
            logger.info(
                f"Batch {batch_num}: {succeeded}/{len(batch)} documents uploaded"
            )
        except Exception as e:
            total_failed += len(batch)
            logger.error(
                f"Failed to upload batch {batch_num} after {RETRY_ATTEMPTS} retries: {e}"
            )

    if total_failed > 0:
        logger.warning(f"Upload complete: {total_succeeded} succeeded, {total_failed} failed")
    else:
        logger.info(f"Upload complete: {total_succeeded}/{len(documents)} documents succeeded")


def main():
    parser = argparse.ArgumentParser(
        description="Create Azure AI Search index with PDF document processing"
    )
    parser.add_argument(
        "--search-endpoint", required=True, help="Azure AI Search endpoint URL"
    )
    parser.add_argument("--index-name", default="documents", help="Search index name")
    parser.add_argument(
        "--storage-account", required=True, help="Azure Storage account name"
    )
    parser.add_argument("--container", default="documents", help="Blob container name")
    parser.add_argument(
        "--doc-intelligence-endpoint",
        required=True,
        help="Azure AI Document Intelligence endpoint",
    )
    parser.add_argument(
        "--openai-endpoint", help="Azure OpenAI endpoint (for image descriptions)"
    )
    parser.add_argument(
        "--openai-deployment",
        default="gpt-4o",
        help="Azure OpenAI deployment name for vision",
    )
    parser.add_argument(
        "--embedding-endpoint",
        help="Embedding model endpoint (Azure OpenAI or Cohere serverless). Defaults to --openai-endpoint if not specified.",
    )
    parser.add_argument(
        "--embedding-deployment",
        default="text-embedding-3-small",
        help="Embedding deployment name (e.g., text-embedding-3-small, text-embedding-ada-002, Cohere-embed-v3-english)",
    )
    parser.add_argument(
        "--embedding-dimensions",
        type=int,
        default=1536,
        help="Vector dimensions for the embedding model (default: 1536 for text-embedding-3-small)",
    )
    parser.add_argument(
        "--embedding-model-name",
        help="Model name for vectorizer (e.g., text-embedding-3-small, embed-v-4-0). Defaults to --embedding-deployment value.",
    )
    parser.add_argument(
        "--pdf-folder", required=True, help="Folder containing PDF files to process"
    )
    parser.add_argument(
        "--use-vectors",
        action="store_true",
        help="Enable vector search (requires --embedding-endpoint or --openai-endpoint)",
    )
    parser.add_argument(
        "--skip-images",
        action="store_true",
        help="Skip image extraction and description",
    )
    parser.add_argument(
        "--create-index-only",
        action="store_true",
        help="Only create the index, don't process files",
    )

    args = parser.parse_args()

    credential = DefaultAzureCredential()

    # Determine embedding endpoint for vectorizer configuration
    embedding_endpoint_for_vectorizer = args.embedding_endpoint or args.openai_endpoint

    # Create the search index
    logger.info("Creating search index...")
    create_document_index(
        endpoint=args.search_endpoint,
        index_name=args.index_name,
        use_vectors=args.use_vectors,
        vector_dimensions=args.embedding_dimensions,
        embedding_endpoint=(
            embedding_endpoint_for_vectorizer if args.use_vectors else None
        ),
        embedding_deployment=args.embedding_deployment if args.use_vectors else None,
        embedding_model_name=(
            args.embedding_model_name or args.embedding_deployment
            if args.use_vectors
            else None
        ),
    )

    if args.create_index_only:
        logger.info("Index created. Exiting (--create-index-only specified).")
        return

    # Initialize clients
    blob_service_client = BlobServiceClient(
        account_url=f"https://{args.storage_account}.blob.core.windows.net",
        credential=credential,
    )
    container_client = blob_service_client.get_container_client(args.container)

    # Create container if it doesn't exist
    try:
        container_client.create_container()
        logger.info(f"Created container: {args.container}")
    except Exception:
        logger.debug(f"Container already exists: {args.container}")

    doc_intelligence_client = DocumentIntelligenceClient(
        endpoint=args.doc_intelligence_endpoint,
        credential=credential,
    )

    openai_client = None
    if args.openai_endpoint and not args.skip_images:
        openai_client = AzureOpenAI(
            azure_endpoint=args.openai_endpoint,
            azure_ad_token_provider=lambda: credential.get_token(
                "https://cognitiveservices.azure.com/.default"
            ).token,
            api_version="2024-02-15-preview",
        )

    # Initialize embedding client (can be same as OpenAI or separate endpoint like Cohere)
    embedding_client = None
    embedding_deployment = None
    if args.use_vectors:
        embedding_endpoint = args.embedding_endpoint or args.openai_endpoint
        if embedding_endpoint:
            embedding_client = AzureOpenAI(
                azure_endpoint=embedding_endpoint,
                azure_ad_token_provider=lambda: credential.get_token(
                    "https://cognitiveservices.azure.com/.default"
                ).token,
                api_version="2024-02-15-preview",
            )
            embedding_deployment = args.embedding_deployment
            logger.info(
                f"Embeddings enabled: {embedding_deployment} ({args.embedding_dimensions} dimensions)"
            )
        else:
            logger.warning("--use-vectors specified but no embedding endpoint provided")

    # Process PDF files
    pdf_folder = Path(args.pdf_folder)
    pdf_files = list(pdf_folder.glob("*.pdf"))

    if not pdf_files:
        logger.warning(f"No PDF files found in {pdf_folder}")
        return

    logger.info(f"Found {len(pdf_files)} PDF files to process")

    all_documents = []
    failed_files = []
    for pdf_file in pdf_files:
        logger.info(f"Processing: {pdf_file.name}")
        try:
            docs = process_pdf(
                pdf_file,
                container_client,
                doc_intelligence_client,
                openai_client,
                args.openai_deployment,
                embedding_client=embedding_client,
                embedding_deployment=embedding_deployment,
                include_images=not args.skip_images,
            )
            all_documents.extend(docs)
            logger.info(f"  Generated {len(docs)} search documents from {pdf_file.name}")
        except Exception as e:
            failed_files.append(pdf_file.name)
            logger.exception(f"Error processing {pdf_file.name}: {type(e).__name__}: {e}")

    # Upload all documents to search
    if all_documents:
        logger.info(f"Uploading {len(all_documents)} documents to search index...")
        upload_documents(args.search_endpoint, args.index_name, all_documents)

    # Summary
    if failed_files:
        logger.warning(f"Completed with {len(failed_files)} failed files: {', '.join(failed_files)}")
    else:
        logger.info(f"Successfully processed all {len(pdf_files)} PDF files")
    
    logger.info("Done!")


if __name__ == "__main__":
    main()
