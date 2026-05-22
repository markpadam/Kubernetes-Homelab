using Azure.Storage.Blobs;

namespace IncidentHub.Web.Services;

public class AttachmentStore
{
    private const string ContainerName = "attachments";
    private readonly BlobContainerClient _container;

    public AttachmentStore(BlobServiceClient client)
    {
        _container = client.GetBlobContainerClient(ContainerName);
        _container.CreateIfNotExists();
    }

    public async Task<string> UploadAsync(string fileName, Stream content)
    {
        var blobName = $"{Guid.NewGuid():N}-{fileName}";
        await _container.UploadBlobAsync(blobName, content);
        return blobName;
    }

    public Task<Stream> OpenAsync(string blobName) =>
        _container.GetBlobClient(blobName).OpenReadAsync();
}
