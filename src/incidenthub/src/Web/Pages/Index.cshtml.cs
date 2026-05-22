using IncidentHub.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace IncidentHub.Web.Pages;

public class IndexModel : PageModel
{
    private readonly IncidentRepository _repo;
    private readonly AttachmentStore? _attachments;
    private readonly IncidentEventPublisher? _publisher;
    private readonly IncidentSearch? _search;

    public IndexModel(
        IncidentRepository repo,
        AttachmentStore? attachments = null,
        IncidentEventPublisher? publisher = null,
        IncidentSearch? search = null)
    {
        _repo = repo;
        _attachments = attachments;
        _publisher = publisher;
        _search = search;
    }

    public IEnumerable<Incident> Incidents { get; private set; } = Array.Empty<Incident>();
    public string? Query { get; private set; }
    public string Who => User.Identity?.Name
        ?? Request.Headers["X-Auth-Request-Email"].ToString()
        ?? "anonymous";

    public async Task OnGetAsync(string? q)
    {
        Query = q;

        if (!string.IsNullOrWhiteSpace(q) && _search is not null)
        {
            var projections = await _search.SearchAsync(q);
            Incidents = projections.Select(p => new Incident(
                p.incidentId, p.title, p.severity, p.reporter, "(from search)", p.createdAt, null));
            return;
        }

        Incidents = await _repo.ListAsync();
    }

    public async Task<IActionResult> OnPostCreateAsync(string title, string severity, IFormFile? attachment)
    {
        string? blobName = null;
        if (attachment is { Length: > 0 } && _attachments is not null)
        {
            await using var stream = attachment.OpenReadStream();
            blobName = await _attachments.UploadAsync(attachment.FileName, stream);
        }

        var id = await _repo.CreateAsync(title, severity, Who, blobName);

        if (_publisher is not null)
            await _publisher.PublishAsync(id, title, severity);

        return RedirectToPage();
    }
}
