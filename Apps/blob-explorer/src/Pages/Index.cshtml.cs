using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace BlobExplorer.Pages;

public class IndexModel : PageModel
{
    private readonly BlobServiceClient _blobServiceClient;
    private const string ContainerName = "uploads";

    public IndexModel(BlobServiceClient blobServiceClient)
    {
        _blobServiceClient = blobServiceClient;
    }

    public List<BlobItem> Blobs { get; set; } = new();

    public string StorageAccount { get; set; } = string.Empty;

    public async Task OnGetAsync()
    {
        StorageAccount = _blobServiceClient.AccountName;

        var container = _blobServiceClient.GetBlobContainerClient(ContainerName);
        await foreach (var blob in container.GetBlobsAsync())
        {
            Blobs.Add(blob);
        }
    }

    public async Task<IActionResult> OnPostUploadAsync(IFormFile file)
    {
        if (file == null || file.Length == 0)
            return RedirectToPage();

        var container = _blobServiceClient.GetBlobContainerClient(ContainerName);
        var blobClient = container.GetBlobClient(file.FileName);

        await using var stream = file.OpenReadStream();
        await blobClient.UploadAsync(stream, overwrite: true);

        return RedirectToPage();
    }

    public async Task<IActionResult> OnPostDeleteAsync(string blobName)
    {
        var container = _blobServiceClient.GetBlobContainerClient(ContainerName);
        await container.GetBlobClient(blobName).DeleteIfExistsAsync();
        return RedirectToPage();
    }

    public async Task<IActionResult> OnGetDownloadAsync(string blobName)
    {
        var container = _blobServiceClient.GetBlobContainerClient(ContainerName);
        var blobClient = container.GetBlobClient(blobName);

        var download = await blobClient.DownloadStreamingAsync();
        return File(download.Value.Content, "application/octet-stream", blobName);
    }
}
