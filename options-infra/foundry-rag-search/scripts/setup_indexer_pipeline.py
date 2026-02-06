#!/usr/bin/env python3
"""Set up Azure AI Search indexer pipeline with skillsets for automatic PDF processing.

This script creates:
1. Data source connection to Azure Blob Storage
2. Skillset with:
   - Document Intelligence for text/table extraction (markdown)
   - Azure OpenAI GPT-4o for image descriptions
   - Azure OpenAI/Cohere for embeddings
3. Index with vector and semantic search
4. Indexer that orchestrates the pipeline

Once configured, any PDF uploaded to the blob container will be automatically processed.
"""

import argparse
import os
from pathlib import Path
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.search.documents.indexes import SearchIndexClient, SearchIndexerClient
from azure.search.documents.indexes.models import (
    # Index models
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
    # Data source models
    SearchIndexerDataContainer,
    SearchIndexerDataSourceConnection,
    # Skillset models
    SearchIndexerSkillset,
    DocumentIntelligenceLayoutSkill,
    AzureOpenAIEmbeddingSkill,
    SplitSkill,
    ImageAnalysisSkill,
    MergeSkill,
    WebApiSkill,
    InputFieldMappingEntry,
    OutputFieldMappingEntry,
    SearchIndexerIndexProjection,
    SearchIndexerIndexProjectionSelector,
    SearchIndexerIndexProjectionsParameters,
    CognitiveServicesAccountKey,
    # Indexer models
    SearchIndexer,
    FieldMapping,
    IndexingParameters,
)


def upload_pdfs_to_container(
    storage_account_name: str,
    container_name: str,
    pdf_folder: str,
    credential: DefaultAzureCredential,
) -> int:
    """Create container if needed and upload PDFs from a folder.

    Returns:
        Number of PDFs uploaded.
    """
    blob_service_url = f"https://{storage_account_name}.blob.core.windows.net"
    blob_service_client = BlobServiceClient(blob_service_url, credential=credential)

    # Create container if it doesn't exist
    container_client = blob_service_client.get_container_client(container_name)
    try:
        container_client.create_container()
        print(f"Created container: {container_name}")
    except Exception as e:
        if "ContainerAlreadyExists" in str(e):
            print(f"Container already exists: {container_name}")
        else:
            raise

    # Upload PDFs
    pdf_path = Path(pdf_folder)
    if not pdf_path.exists():
        print(f"Warning: PDF folder not found: {pdf_folder}")
        return 0

    pdf_files = list(pdf_path.glob("*.pdf"))
    if not pdf_files:
        print(f"Warning: No PDFs found in {pdf_folder}")
        return 0

    print(f"Uploading {len(pdf_files)} PDFs to container '{container_name}'...")
    for pdf_file in pdf_files:
        blob_client = container_client.get_blob_client(pdf_file.name)
        with open(pdf_file, "rb") as f:
            blob_client.upload_blob(f, overwrite=True)
        print(f"  Uploaded: {pdf_file.name}")

    return len(pdf_files)


def create_data_source(
    client: SearchIndexerClient,
    data_source_name: str,
    storage_account_name: str,
    container_name: str,
    use_managed_identity: bool = True,
    storage_connection_string: str | None = None,
    subscription_id: str | None = None,
    resource_group: str | None = None,
) -> None:
    """Create or update blob storage data source.

    Args:
        use_managed_identity: If True, uses system-assigned managed identity.
                             If False, requires storage_connection_string.
        subscription_id: Azure subscription ID (required for managed identity).
        resource_group: Azure resource group name (required for managed identity).
    """
    if use_managed_identity:
        if not subscription_id or not resource_group:
            raise ValueError(
                "subscription_id and resource_group required when using managed identity"
            )
        # Use managed identity - requires Search service to have Storage Blob Data Reader role
        resource_id = f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.Storage/storageAccounts/{storage_account_name}"
        data_source = SearchIndexerDataSourceConnection(
            name=data_source_name,
            type="azureblob",
            connection_string=f"ResourceId={resource_id};",
            container=SearchIndexerDataContainer(name=container_name),
        )
    else:
        if not storage_connection_string:
            raise ValueError(
                "storage_connection_string required when not using managed identity"
            )
        data_source = SearchIndexerDataSourceConnection(
            name=data_source_name,
            type="azureblob",
            connection_string=storage_connection_string,
            container=SearchIndexerDataContainer(name=container_name),
        )

    client.create_or_update_data_source_connection(data_source)
    print(f"Created data source: {data_source_name}")
    if use_managed_identity:
        print(f"  Using managed identity for storage account: {storage_account_name}")
        print(f"  Resource ID: {resource_id}")


def create_index(
    client: SearchIndexClient,
    index_name: str,
    vector_dimensions: int,
    embedding_endpoint: str,
    embedding_deployment: str,
    embedding_model_name: str,
) -> None:
    """Create or update the search index with vector and semantic search."""

    # Chunk fields with header hierarchy from Document Layout skill
    chunk_fields = [
        SearchField(
            name="chunk_id",
            type=SearchFieldDataType.String,
            key=True,
            searchable=True,
            filterable=False,
            sortable=False,
            facetable=False,
            analyzer_name="keyword",
        ),
        SimpleField(
            name="parent_id",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        # Content type discriminator for filtering (text, image, table)
        SearchableField(
            name="chunk_type",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        SearchableField(name="chunk", type=SearchFieldDataType.String),
        SearchableField(name="title", type=SearchFieldDataType.String, filterable=True),
        # Image-specific fields (populated for image chunks only)
        SearchableField(name="image_description", type=SearchFieldDataType.String),
        SearchableField(name="image_ocr_text", type=SearchFieldDataType.String),
        SimpleField(
            name="image_tags", type=SearchFieldDataType.String
        ),  # JSON array of tags
        # Header hierarchy from Document Layout skill (markdown sections)
        SearchableField(
            name="header_1",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        SearchableField(
            name="header_2",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        SearchableField(
            name="header_3",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        SimpleField(
            name="page_number",
            type=SearchFieldDataType.Int32,
            filterable=True,
            sortable=True,
        ),
        SearchField(
            name="vector",
            type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
            searchable=True,
            vector_search_dimensions=vector_dimensions,
            vector_search_profile_name="vector-profile",
        ),
    ]

    # Configure vectorizer for query-time embedding
    vectorizer = AzureOpenAIVectorizer(
        vectorizer_name="text-vectorizer",
        parameters=AzureOpenAIVectorizerParameters(
            resource_url=embedding_endpoint,
            deployment_name=embedding_deployment,
            model_name=embedding_model_name,
        ),
    )

    vector_search = VectorSearch(
        algorithms=[HnswAlgorithmConfiguration(name="hnsw-algorithm")],
        profiles=[
            VectorSearchProfile(
                name="vector-profile",
                algorithm_configuration_name="hnsw-algorithm",
                vectorizer_name="text-vectorizer",
            )
        ],
        vectorizers=[vectorizer],
    )

    # Semantic configuration for better ranking
    # Includes all content fields for comprehensive hybrid search
    semantic_config = SemanticConfiguration(
        name="semantic-config",
        prioritized_fields=SemanticPrioritizedFields(
            content_fields=[
                SemanticField(field_name="chunk"),
                SemanticField(field_name="image_description"),
                SemanticField(field_name="image_ocr_text"),
            ],
            title_field=SemanticField(field_name="title"),
            keywords_fields=[
                SemanticField(field_name="chunk_type"),
                SemanticField(field_name="header_1"),
                SemanticField(field_name="header_2"),
            ],
        ),
    )
    semantic_search = SemanticSearch(configurations=[semantic_config])

    index = SearchIndex(
        name=index_name,
        fields=chunk_fields,
        vector_search=vector_search,
        semantic_search=semantic_search,
    )

    client.create_or_update_index(index)
    print(f"Created index: {index_name}")
    print(f"  Vector dimensions: {vector_dimensions}")
    print(f"  Vectorizer: {embedding_deployment} at {embedding_endpoint}")
    print("  Header fields: header_1, header_2, header_3 (from document structure)")


def create_image_skills_verbalization(
    vision_endpoint: str,
    vision_deployment: str,
) -> list:
    """Create image processing skills using GPT-4o Vision for rich descriptions.

    Returns a list of skills for image processing with verbalization (LLM-based descriptions).
    No OCR - the LLM directly describes the image content.
    """
    skills = []

    # Image Verbalization using Azure OpenAI GPT-4o Vision
    # The skill generates rich descriptions using vision LLM capabilities
    # Note: WebApiSkill calls Azure OpenAI directly - you may need an Azure Function
    # wrapper for production use as the chat completions API expects a specific format
    verbalization_skill = WebApiSkill(
        name="image-verbalization-skill",
        description="Generate rich image descriptions using Azure OpenAI GPT-4o Vision",
        context="/document/normalized_images/*",
        uri=f"{vision_endpoint}/openai/deployments/{vision_deployment}/chat/completions?api-version=2024-02-15-preview",
        http_method="POST",
        timeout="PT60S",
        batch_size=1,
        degree_of_parallelism=2,
        inputs=[
            InputFieldMappingEntry(
                name="image", source="/document/normalized_images/*"
            ),
        ],
        outputs=[
            OutputFieldMappingEntry(
                name="description", target_name="image_description"
            ),
        ],
        auth_resource_id="https://cognitiveservices.azure.com",
    )
    skills.append(verbalization_skill)

    return skills


def create_image_skills_vision_api(
    cognitive_services_key: str | None = None,
) -> list:
    """Create image processing skills using Azure AI Vision API (basic descriptions).

    Returns a list of skills for image processing with Vision API.
    No OCR - uses Image Analysis for descriptions.
    """
    skills = []

    # Image Analysis skill using Azure AI Vision - generates descriptions directly
    image_analysis_skill = ImageAnalysisSkill(
        name="image-analysis-skill",
        description="Analyze images and generate descriptions using Azure AI Vision",
        context="/document/normalized_images/*",
        inputs=[
            InputFieldMappingEntry(
                name="image", source="/document/normalized_images/*"
            ),
        ],
        outputs=[
            OutputFieldMappingEntry(
                name="description", target_name="image_description"
            ),
            OutputFieldMappingEntry(name="tags", target_name="image_tags"),
        ],
        visual_features=["description", "tags", "objects"],
        default_language_code="en",
    )
    skills.append(image_analysis_skill)

    return skills


def create_skillset(
    client: SearchIndexerClient,
    skillset_name: str,
    index_name: str,
    doc_intelligence_endpoint: str,
    embedding_endpoint: str,
    embedding_deployment: str,
    embedding_model_name: str,
    vector_dimensions: int,
    cognitive_services_key: str | None = None,
    openai_endpoint: str | None = None,
    openai_deployment: str | None = None,
    process_images: bool = True,
    chunking_strategy: str = "layout",
    image_skill_mode: str = "verbalization",
    vision_endpoint: str | None = None,
    vision_deployment: str = "gpt-4o",
) -> None:
    """Create skillset with Document Intelligence layout-based chunking and embedding skills.

    Args:
        chunking_strategy: "layout" for smart structure-based, "fixed" for character-based
        image_skill_mode: "verbalization" for GPT-4o Vision (rich), "vision-api" for basic
        vision_endpoint: Azure OpenAI endpoint for image verbalization
        vision_deployment: Azure OpenAI deployment name for vision (default: gpt-4o)
    """

    skills = []

    # Skill 1: Document Intelligence Layout - extracts structure as markdown sections
    # The skill outputs markdown with headers (h1, h2, h3) that preserve document structure
    # With oneToMany output_mode, each section becomes a separate enrichment node
    # Output fields per section: content, h1, h2, h3, h4, h5, h6
    doc_intel_skill = DocumentIntelligenceLayoutSkill(
        name="document-intelligence-layout",
        description="Extract text, tables, and structure from PDFs using Document Intelligence",
        context="/document",
        inputs=[
            InputFieldMappingEntry(name="file_data", source="/document/file_data"),
        ],
        outputs=[
            OutputFieldMappingEntry(
                name="markdown_document", target_name="layoutSections"
            ),
        ],
        output_mode="oneToMany",
        markdown_header_depth="h3",  # Capture up to 3 levels of headers
    )
    skills.append(doc_intel_skill)

    # Image processing skills (description generation - no OCR)
    if process_images:
        if image_skill_mode == "verbalization":
            # Use GPT-4o Vision for rich image descriptions (Preview)
            effective_vision_endpoint = vision_endpoint or embedding_endpoint
            image_skills = create_image_skills_verbalization(
                vision_endpoint=effective_vision_endpoint,
                vision_deployment=vision_deployment,
            )
            print(
                f"  Image mode: verbalization (GPT-4o Vision at {effective_vision_endpoint})"
            )
        else:
            # Use Azure AI Vision API for basic descriptions
            image_skills = create_image_skills_vision_api(
                cognitive_services_key=cognitive_services_key,
            )
            print("  Image mode: vision-api (Azure AI Vision)")

        skills.extend(image_skills)

        # Merge image descriptions into document content
        # This ensures image descriptions are searchable alongside text
        merge_skill = MergeSkill(
            name="merge-image-descriptions",
            description="Merge image descriptions into document content for unified search",
            context="/document",
            inputs=[
                InputFieldMappingEntry(
                    name="text", source="/document/layoutSections/*/content"
                ),
                InputFieldMappingEntry(
                    name="itemsToInsert",
                    source="/document/normalized_images/*/image_description/captions/0/text",
                ),
            ],
            outputs=[
                OutputFieldMappingEntry(
                    name="mergedText", target_name="merged_content"
                ),
            ],
            insert_pre_tag=" [Image: ",
            insert_post_tag="] ",
        )
        skills.append(merge_skill)

    if chunking_strategy == "layout":
        # Smart chunking based on document structure
        # If images were processed, use merged content; otherwise use layout sections directly

        if process_images:
            # Use merged content (text + image descriptions)
            split_skill = SplitSkill(
                name="text-split",
                description="Split merged content (text + image descriptions) into chunks",
                context="/document",
                inputs=[
                    InputFieldMappingEntry(
                        name="text", source="/document/merged_content"
                    ),
                ],
                outputs=[
                    OutputFieldMappingEntry(name="textItems", target_name="chunks"),
                ],
                text_split_mode="pages",
                maximum_page_length=2000,
                page_overlap_length=200,  # Add overlap since we're not using semantic boundaries
            )
            skills.append(split_skill)

            # Embedding for merged content chunks
            embedding_skill = AzureOpenAIEmbeddingSkill(
                name="embedding-skill",
                description="Generate embeddings for each chunk",
                context="/document/chunks/*",
                inputs=[
                    InputFieldMappingEntry(name="text", source="/document/chunks/*"),
                ],
                outputs=[
                    OutputFieldMappingEntry(name="embedding", target_name="vector"),
                ],
                resource_url=embedding_endpoint,
                deployment_name=embedding_deployment,
                model_name=embedding_model_name,
                dimensions=vector_dimensions,
            )
            skills.append(embedding_skill)

            # Projection for merged content
            projection_selectors = [
                SearchIndexerIndexProjectionSelector(
                    target_index_name=index_name,
                    parent_key_field_name="parent_id",
                    source_context="/document/chunks/*",
                    mappings=[
                        InputFieldMappingEntry(
                            name="chunk", source="/document/chunks/*"
                        ),
                        InputFieldMappingEntry(
                            name="vector", source="/document/chunks/*/vector"
                        ),
                        InputFieldMappingEntry(
                            name="title", source="/document/metadata_storage_name"
                        ),
                        InputFieldMappingEntry(name="chunk_type", source="='text'"),
                    ],
                )
            ]
        else:
            # No images - use layout sections directly for semantic chunking
            split_skill = SplitSkill(
                name="text-split",
                description="Split large sections while preserving structure",
                context="/document/layoutSections/*",
                inputs=[
                    InputFieldMappingEntry(
                        name="text", source="/document/layoutSections/*/content"
                    ),
                ],
                outputs=[
                    OutputFieldMappingEntry(name="textItems", target_name="chunks"),
                ],
                text_split_mode="pages",
                maximum_page_length=2000,
                page_overlap_length=0,  # No overlap needed - sections are semantic boundaries
            )
            skills.append(split_skill)

            # Embedding for layout section chunks
            embedding_skill = AzureOpenAIEmbeddingSkill(
                name="embedding-skill",
                description="Generate embeddings for each text chunk",
                context="/document/layoutSections/*/chunks/*",
                inputs=[
                    InputFieldMappingEntry(
                        name="text", source="/document/layoutSections/*/chunks/*"
                    ),
                ],
                outputs=[
                    OutputFieldMappingEntry(name="embedding", target_name="vector"),
                ],
                resource_url=embedding_endpoint,
                deployment_name=embedding_deployment,
                model_name=embedding_model_name,
                dimensions=vector_dimensions,
            )
            skills.append(embedding_skill)

            # Projection for layout sections
            projection_selectors = [
                SearchIndexerIndexProjectionSelector(
                    target_index_name=index_name,
                    parent_key_field_name="parent_id",
                    source_context="/document/layoutSections/*/chunks/*",
                    mappings=[
                        InputFieldMappingEntry(
                            name="chunk",
                            source="/document/layoutSections/*/chunks/*",
                        ),
                        InputFieldMappingEntry(
                            name="vector",
                            source="/document/layoutSections/*/chunks/*/vector",
                        ),
                        InputFieldMappingEntry(
                            name="title", source="/document/metadata_storage_name"
                        ),
                        InputFieldMappingEntry(name="chunk_type", source="='text'"),
                    ],
                )
            ]

        # Index projection
        index_projections = SearchIndexerIndexProjection(
            selectors=projection_selectors,
            parameters=SearchIndexerIndexProjectionsParameters(
                projection_mode="skipIndexingParentDocuments",
            ),
        )
    else:
        # Fixed-size chunking (original approach)
        # Merge content first if processing images
        if process_images:
            merge_skill = MergeSkill(
                name="merge-content-skill",
                description="Merge document content with image descriptions",
                context="/document",
                inputs=[
                    InputFieldMappingEntry(
                        name="text", source="/document/layoutSections/*/content"
                    ),
                    InputFieldMappingEntry(
                        name="itemsToInsert",
                        source="/document/normalized_images/*/image_description/captions/*/text",
                    ),
                ],
                outputs=[
                    OutputFieldMappingEntry(
                        name="mergedText", target_name="merged_content"
                    ),
                ],
                insert_pre_tag=" [Image: ",
                insert_post_tag="] ",
            )
            skills.append(merge_skill)

        split_skill = SplitSkill(
            name="text-split",
            description="Split content into fixed-size chunks",
            context="/document",
            inputs=[
                InputFieldMappingEntry(
                    name="text",
                    source=(
                        "/document/merged_content"
                        if process_images
                        else "/document/layoutSections/*/content"
                    ),
                ),
            ],
            outputs=[
                OutputFieldMappingEntry(name="textItems", target_name="chunks"),
            ],
            text_split_mode="pages",
            maximum_page_length=2000,
            page_overlap_length=200,
        )
        skills.append(split_skill)

        embedding_skill = AzureOpenAIEmbeddingSkill(
            name="embedding-skill",
            description="Generate embeddings for each chunk",
            context="/document/chunks/*",
            inputs=[
                InputFieldMappingEntry(name="text", source="/document/chunks/*"),
            ],
            outputs=[
                OutputFieldMappingEntry(name="embedding", target_name="vector"),
            ],
            resource_url=embedding_endpoint,
            deployment_name=embedding_deployment,
            model_name=embedding_model_name,
            dimensions=vector_dimensions,
        )
        skills.append(embedding_skill)

        index_projections = SearchIndexerIndexProjection(
            selectors=[
                SearchIndexerIndexProjectionSelector(
                    target_index_name=index_name,
                    parent_key_field_name="parent_id",
                    source_context="/document/chunks/*",
                    mappings=[
                        InputFieldMappingEntry(
                            name="chunk", source="/document/chunks/*"
                        ),
                        InputFieldMappingEntry(
                            name="vector", source="/document/chunks/*/vector"
                        ),
                        InputFieldMappingEntry(
                            name="title", source="/document/metadata_storage_name"
                        ),
                        InputFieldMappingEntry(name="chunk_type", source="='text'"),
                    ],
                )
            ],
            parameters=SearchIndexerIndexProjectionsParameters(
                projection_mode="skipIndexingParentDocuments",
            ),
        )

    # Cognitive services for billing (required for Image Analysis and OCR)
    cognitive_services = None
    if cognitive_services_key:
        cognitive_services = CognitiveServicesAccountKey(key=cognitive_services_key)

    skillset = SearchIndexerSkillset(
        name=skillset_name,
        description=f"Skillset for PDF processing with {chunking_strategy} chunking",
        skills=skills,
        index_projection=index_projections,
        cognitive_services_account=cognitive_services,
    )

    client.create_or_update_skillset(skillset)
    print(f"Created skillset: {skillset_name}")
    print(f"  Chunking strategy: {chunking_strategy}")
    skill_names = ["Document Intelligence Layout"]
    if process_images:
        if image_skill_mode == "verbalization":
            skill_names.append("Image Verbalization (GPT-4o)")
        else:
            skill_names.append("Image Analysis (Vision API)")
        skill_names.append("Merge Image Descriptions")
    skill_names.append("Text Split")
    skill_names.append("Text Embedding")
    print(f"  Skills: {', '.join(skill_names)}")
    if process_images:
        print("  ✅ Image descriptions merged into content for unified search")


def create_indexer(
    client: SearchIndexerClient,
    indexer_name: str,
    data_source_name: str,
    skillset_name: str,
    index_name: str,
) -> None:
    """Create indexer that orchestrates the pipeline."""

    indexer = SearchIndexer(
        name=indexer_name,
        description="Indexer for automatic PDF processing",
        data_source_name=data_source_name,
        skillset_name=skillset_name,
        target_index_name=index_name,
        parameters=IndexingParameters(
            configuration={
                "parsingMode": "default",
                "dataToExtract": "contentAndMetadata",
                "imageAction": "generateNormalizedImages",
                "allowSkillsetToReadFileData": True,  # Required for DocumentIntelligenceLayoutSkill
            }
        ),
        field_mappings=[
            FieldMapping(
                source_field_name="metadata_storage_path", target_field_name="parent_id"
            ),
            FieldMapping(
                source_field_name="metadata_storage_name", target_field_name="title"
            ),
        ],
    )

    client.create_or_update_indexer(indexer)
    print(f"Created indexer: {indexer_name}")
    print(f"  Data source: {data_source_name}")
    print(f"  Skillset: {skillset_name}")
    print(f"  Target index: {index_name}")


def run_indexer(client: SearchIndexerClient, indexer_name: str) -> None:
    """Trigger the indexer to run."""
    client.run_indexer(indexer_name)
    print(
        f"Indexer '{indexer_name}' started. Check status with: az search indexer show-status --name {indexer_name}"
    )


def print_required_permissions():
    """Print the required RBAC permissions for managed identity setup."""
    print("""
================================================================================
REQUIRED RBAC ROLE ASSIGNMENTS FOR MANAGED IDENTITY
================================================================================

Assign these roles to the Azure AI Search service's system-assigned managed identity:

1. BLOB STORAGE (for reading PDFs)
   Role: Storage Blob Data Reader
   Scope: Storage Account or Container
   
2. DOCUMENT INTELLIGENCE (for layout skill)
   Role: Cognitive Services User
   Scope: Document Intelligence resource
   
3. AZURE OPENAI (for embeddings)
   Role: Cognitive Services OpenAI User
   Scope: Azure OpenAI resource

4. AZURE AI FOUNDRY (if using Foundry-deployed models)
   Role: Cognitive Services User
   Scope: AI Foundry resource

Example Azure CLI commands:
--------------------------------------------------------------------------------
# Get Search service principal ID
SEARCH_PRINCIPAL=$(az search service show --name <search-name> -g <rg> --query identity.principalId -o tsv)

# Blob Storage
az role assignment create --assignee $SEARCH_PRINCIPAL \\
    --role "Storage Blob Data Reader" \\
    --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>

# Document Intelligence  
az role assignment create --assignee $SEARCH_PRINCIPAL \\
    --role "Cognitive Services User" \\
    --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<doc-intel>

# Azure OpenAI / AI Foundry
az role assignment create --assignee $SEARCH_PRINCIPAL \\
    --role "Cognitive Services OpenAI User" \\
    --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<openai>
================================================================================
""")


def main():
    parser = argparse.ArgumentParser(
        description="Set up Azure AI Search indexer pipeline for automatic PDF processing"
    )

    # Required endpoints
    parser.add_argument(
        "--search-endpoint", required=True, help="Azure AI Search endpoint URL"
    )
    parser.add_argument(
        "--storage-account", required=True, help="Azure Storage account name"
    )
    parser.add_argument(
        "--subscription-id",
        help="Azure subscription ID (required for managed identity, or set AZURE_SUBSCRIPTION_ID env var)",
    )
    parser.add_argument(
        "--resource-group",
        help="Azure resource group name (required for managed identity, or set AZURE_RESOURCE_GROUP env var)",
    )
    parser.add_argument(
        "--storage-connection-string",
        help="Azure Storage connection string (optional - use if not using managed identity)",
    )
    parser.add_argument(
        "--doc-intelligence-endpoint",
        required=True,
        help="Azure AI Document Intelligence endpoint",
    )
    parser.add_argument(
        "--embedding-endpoint",
        required=True,
        help="Azure OpenAI or Cohere endpoint for embeddings",
    )

    # Resource names
    parser.add_argument(
        "--container",
        default="documents-for-indexer",
        help="Blob container name for PDFs",
    )
    parser.add_argument(
        "--pdf-folder",
        help="Folder containing PDFs to upload to the container (optional)",
    )
    parser.add_argument(
        "--index-name", default="documents-indexer", help="Search index name"
    )
    parser.add_argument(
        "--data-source-name",
        default="pdf-datasource",
        help="Data source connection name",
    )
    parser.add_argument("--skillset-name", default="pdf-skillset", help="Skillset name")
    parser.add_argument("--indexer-name", default="pdf-indexer", help="Indexer name")

    # Embedding configuration
    parser.add_argument(
        "--embedding-deployment",
        default="text-embedding-3-small",
        help="Embedding deployment name",
    )
    parser.add_argument(
        "--embedding-model-name",
        help="Model name for vectorizer (defaults to --embedding-deployment)",
    )
    parser.add_argument(
        "--embedding-dimensions", type=int, default=1536, help="Vector dimensions"
    )

    # Image processing configuration
    parser.add_argument(
        "--cognitive-services-key",
        help="Cognitive Services key for image analysis (use @env:VAR_NAME to read from env)",
    )
    parser.add_argument(
        "--skip-images",
        action="store_true",
        help="Skip image processing (OCR and Image Analysis)",
    )
    parser.add_argument(
        "--image-skill-mode",
        choices=["verbalization", "vision-api"],
        default="verbalization",
        help="Image description mode: 'verbalization' uses GPT-4o for rich descriptions (default, preview), "
        "'vision-api' uses Azure AI Vision API (basic descriptions)",
    )
    parser.add_argument(
        "--vision-endpoint",
        help="Azure OpenAI endpoint for image verbalization (defaults to --embedding-endpoint)",
    )
    parser.add_argument(
        "--vision-deployment",
        default="gpt-4o",
        help="Azure OpenAI deployment for image verbalization (default: gpt-4o)",
    )

    # Chunking configuration
    parser.add_argument(
        "--chunking-strategy",
        choices=["layout", "fixed"],
        default="layout",
        help="Chunking strategy: 'layout' for smart structure-based chunking (sections, paragraphs), "
        "'fixed' for character-based chunks with overlap (default: layout)",
    )

    # Actions
    parser.add_argument(
        "--run-indexer", action="store_true", help="Run the indexer after creation"
    )
    parser.add_argument(
        "--create-only",
        choices=["datasource", "index", "skillset", "indexer"],
        help="Only create a specific component",
    )
    parser.add_argument(
        "--show-permissions",
        action="store_true",
        help="Show required RBAC permissions for managed identity setup and exit",
    )

    args = parser.parse_args()

    # Show permissions and exit if requested
    if args.show_permissions:
        print_required_permissions()
        return

    # Determine if using managed identity or connection string
    use_managed_identity = not args.storage_connection_string

    # Get subscription_id and resource_group for managed identity
    subscription_id = args.subscription_id or os.environ.get("AZURE_SUBSCRIPTION_ID")
    resource_group = args.resource_group or os.environ.get("AZURE_RESOURCE_GROUP")

    if use_managed_identity and (not subscription_id or not resource_group):
        raise ValueError(
            "subscription_id and resource_group are required when using managed identity. "
            "Provide via --subscription-id/--resource-group or set AZURE_SUBSCRIPTION_ID/AZURE_RESOURCE_GROUP env vars."
        )

    # Handle connection string from environment variable if provided
    connection_string = None
    if args.storage_connection_string:
        connection_string = args.storage_connection_string
        if connection_string.startswith("@env:"):
            env_var = connection_string[5:]
            connection_string = os.environ.get(env_var)
            if not connection_string:
                raise ValueError(f"Environment variable {env_var} not set")

    # Handle cognitive services key from environment variable
    cognitive_services_key = args.cognitive_services_key
    if cognitive_services_key and cognitive_services_key.startswith("@env:"):
        env_var = cognitive_services_key[5:]
        cognitive_services_key = os.environ.get(env_var)

    process_images = not args.skip_images

    credential = DefaultAzureCredential()
    index_client = SearchIndexClient(
        endpoint=args.search_endpoint, credential=credential
    )
    indexer_client = SearchIndexerClient(
        endpoint=args.search_endpoint, credential=credential
    )

    embedding_model = args.embedding_model_name or args.embedding_deployment

    print("=" * 60)
    print("Azure AI Search Indexer Pipeline Setup")
    print("=" * 60)
    print(
        f"Authentication: {'Managed Identity' if use_managed_identity else 'Connection String'}"
    )
    print(f"Image processing: {'enabled' if process_images else 'disabled'}")
    if process_images:
        print(f"  Image skill mode: {args.image_skill_mode}")
        if args.image_skill_mode == "verbalization":
            print(f"  Vision deployment: {args.vision_deployment}")
    print(f"Chunking strategy: {args.chunking_strategy}")

    if use_managed_identity:
        print(
            "\n⚠️  Make sure RBAC roles are assigned! Run with --show-permissions to see required roles."
        )

    # Upload PDFs if folder specified
    if args.pdf_folder:
        print(f"\n0. Uploading PDFs from {args.pdf_folder}...")
        uploaded_count = upload_pdfs_to_container(
            args.storage_account,
            args.container,
            args.pdf_folder,
            credential,
        )
        print(f"  Uploaded {uploaded_count} PDFs to container '{args.container}'")

    if args.create_only:
        # Create only specific component
        if args.create_only == "datasource":
            create_data_source(
                indexer_client,
                args.data_source_name,
                args.storage_account,
                args.container,
                use_managed_identity=use_managed_identity,
                storage_connection_string=connection_string,
                subscription_id=subscription_id,
                resource_group=resource_group,
            )
        elif args.create_only == "index":
            create_index(
                index_client,
                args.index_name,
                args.embedding_dimensions,
                args.embedding_endpoint,
                args.embedding_deployment,
                embedding_model,
            )
        elif args.create_only == "skillset":
            create_skillset(
                indexer_client,
                args.skillset_name,
                args.index_name,
                args.doc_intelligence_endpoint,
                args.embedding_endpoint,
                args.embedding_deployment,
                embedding_model,
                args.embedding_dimensions,
                cognitive_services_key=cognitive_services_key,
                process_images=process_images,
                chunking_strategy=args.chunking_strategy,
                image_skill_mode=args.image_skill_mode,
                vision_endpoint=args.vision_endpoint,
                vision_deployment=args.vision_deployment,
            )
        elif args.create_only == "indexer":
            create_indexer(
                indexer_client,
                args.indexer_name,
                args.data_source_name,
                args.skillset_name,
                args.index_name,
            )
    else:
        # Create all components
        print("\n1. Creating data source...")
        create_data_source(
            indexer_client,
            args.data_source_name,
            args.storage_account,
            args.container,
            use_managed_identity=use_managed_identity,
            storage_connection_string=connection_string,
            subscription_id=subscription_id,
            resource_group=resource_group,
        )

        print("\n2. Creating index...")
        create_index(
            index_client,
            args.index_name,
            args.embedding_dimensions,
            args.embedding_endpoint,
            args.embedding_deployment,
            embedding_model,
        )

        print("\n3. Creating skillset...")
        create_skillset(
            indexer_client,
            args.skillset_name,
            args.index_name,
            args.doc_intelligence_endpoint,
            args.embedding_endpoint,
            args.embedding_deployment,
            embedding_model,
            args.embedding_dimensions,
            cognitive_services_key=cognitive_services_key,
            process_images=process_images,
            chunking_strategy=args.chunking_strategy,
            image_skill_mode=args.image_skill_mode,
            vision_endpoint=args.vision_endpoint,
            vision_deployment=args.vision_deployment,
        )

        print("\n4. Creating indexer...")
        create_indexer(
            indexer_client,
            args.indexer_name,
            args.data_source_name,
            args.skillset_name,
            args.index_name,
        )

    if args.run_indexer:
        print("\n5. Running indexer...")
        run_indexer(indexer_client, args.indexer_name)

    print("\n" + "=" * 60)
    print("Setup complete!")
    print("=" * 60)
    print(f"\nUpload PDFs to container: {args.container}")
    print(f"Storage account: {args.storage_account}")
    print(f"Index name: {args.index_name}")
    print("\nTo manually run the indexer:")
    print(
        f"  az search indexer run --name {args.indexer_name} --service-name <search-service>"
    )
    print("\nTo check indexer status:")
    print(
        f"  az search indexer show-status --name {args.indexer_name} --service-name <search-service>"
    )


if __name__ == "__main__":
    main()
