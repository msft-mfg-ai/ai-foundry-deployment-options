using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;

namespace AgentChat.Services;

public sealed class BlobGeneratedFileContentStore(
    BlobContainerClient container) : IGeneratedFileContentStore
{
    public async Task SaveAsync(
        string token,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken)
    {
        var blob = container.GetBlobClient(token);
        await blob.UploadAsync(
            BinaryData.FromBytes(content),
            overwrite: false,
            cancellationToken);
    }

    public async Task<Stream> OpenReadAsync(
        string token,
        CancellationToken cancellationToken)
        => await container
            .GetBlobClient(token)
            .OpenReadAsync(
                new BlobOpenReadOptions(allowModifications: false),
                cancellationToken);

    public async Task DeleteAsync(
        string token,
        CancellationToken cancellationToken)
    {
        await container
            .GetBlobClient(token)
            .DeleteIfExistsAsync(
                DeleteSnapshotsOption.IncludeSnapshots,
                cancellationToken: cancellationToken);
    }
}
